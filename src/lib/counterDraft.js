// CAFE-GUEST-01N - the pure draft logic behind the staff Counter screen.
//
// READ-ONLY: it builds and previews ONE product configuration and writes nothing. It holds no
// pricing rule, rate or authorization logic. Three things only:
//   - the counter catalogue STATE from the server response (loadCounterCatalogueState);
//   - one draft (a product plus the values staff have typed) and its configuration;
//   - a preview of what a future submission would carry, with an ESTIMATED total taken from the
//     existing customer-safe pricing mirror (src/lib/pricing.js). The server stays the only price
//     authority; the estimate is labelled as an estimate everywhere it is shown.
//
// The product list is never read from the static product array: it comes from the server's counter
// catalogue and is only classified by the existing counterCatalogue.js helpers.

import { COUNTER_ACTIONS, COUNTER_GROUPS, resolveCounterCatalogue } from './counterCatalogue.js'
import { A4_COUNTER_PRINT_DEFAULTS, buildA4CounterPrintConfig, validateA4CounterPrintInput } from './counterPrintConfig.js'
import { calculatePerUnit } from './perUnitPricing.js'
import { calculateProductPrice, getDefaultConfig } from './pricing.js'

// The one product whose counter job is a physical A4 print (no upload, no file record).
export const COUNTER_PRINT_PRODUCT_ID = 'a4-print'

// What the customer is shown until the submission slice adds optional customer details.
export const COUNTER_WALK_IN_LABEL = 'Walk-in'

const strategyOf = (product) => (typeof product?.pricing?.strategy === 'string' ? product.pricing.strategy.toUpperCase() : '')

export function isCounterPrintProduct(product) {
  return product?.id === COUNTER_PRINT_PRODUCT_ID && strategyOf(product) === 'PER_PAGE'
}

export function isCounterPerUnitProduct(product) {
  return strategyOf(product) === 'PER_UNIT'
}

// ── catalogue state ──────────────────────────────────────────────────────

// Maps a failed catalogue call to a screen state. The SERVER decided; this only reads its words.
// 'signed-out' shows the sign-in form; 'denied' and 'unavailable' show the server's message; anything
// else is a retryable error. No error ever falls back to a local product list.
export function classifyCounterError(error) {
  const message = typeof error?.message === 'string' && error.message ? error.message : ''
  const status = Number(error?.status)
  const code = String(error?.payload?.code || '')
  if (/sign-in is required/i.test(message) || status === 401) {
    return { status: 'signed-out', message: message || 'Staff sign-in is required.' }
  }
  if (status === 403 || code === '42501' || /do not have access/i.test(message)) {
    return { status: 'denied', message: message || 'You do not have access to the Quick Solution counter.' }
  }
  if (/not active|not found/i.test(message)) {
    return { status: 'unavailable', message }
  }
  return { status: 'error', message: message || 'The counter could not be loaded.' }
}

// Runs the injected loader (the API wrapper) and returns the screen state. Never throws.
export async function loadCounterCatalogueState(load) {
  let response
  try {
    response = await load()
  } catch (error) {
    return classifyCounterError(error)
  }
  if (!response || !Array.isArray(response.products)) {
    return { status: 'error', message: 'The counter returned an unexpected response.' }
  }
  const entries = resolveCounterCatalogue(response.products)
  const tenant = response.tenant && typeof response.tenant === 'object' ? response.tenant : null
  if (entries.length === 0) return { status: 'empty', tenant, entries: [] }
  return { status: 'ready', tenant, entries }
}

// Quick Services first, then Production & Branding; a group with no product is not shown. Order inside a
// group is the server's order. The group of each entry comes from counterCatalogue.js.
export function groupCounterEntries(entries) {
  return Object.values(COUNTER_GROUPS)
    .map((group) => ({ group, entries: (entries || []).filter((entry) => entry.group === group) }))
    .filter((section) => section.entries.length > 0)
}

// ── draft ────────────────────────────────────────────────────────────────

// Counter jobs are physical: there is nothing to upload, so file fields never reach the screen.
export function counterFields(product) {
  return (Array.isArray(product?.fields) ? product.fields : []).filter((field) => field?.type !== 'file')
}

// A fresh draft for a product: the established field defaults, except that a physical print starts
// with NO page count (the field default 0 is not a real answer).
export function createCounterDraft(product) {
  const values = getDefaultConfig({ fields: counterFields(product) })
  if (isCounterPrintProduct(product)) values.pages = ''
  return { productId: product.id, values }
}

// Choosing the product that is already selected keeps the draft; choosing another starts clean, so no
// value of one product can leak into another.
export function selectCounterProduct(draft, product) {
  return draft?.productId === product.id ? draft : createCounterDraft(product)
}

export function setCounterDraftValue(draft, product, fieldId, value) {
  if (!draft || draft.productId !== product?.id) return draft
  if (!counterFields(product).some((field) => field.id === fieldId)) return draft
  return { ...draft, values: { ...draft.values, [fieldId]: value } }
}

// ── configuration ────────────────────────────────────────────────────────

const isBlank = (value) => value === undefined || value === null || (typeof value === 'string' && value.trim() === '')
const fieldName = (field) => field.shortLabel || field.label || field.id

function wholeNumber(value) {
  if (typeof value === 'number') return Number.isInteger(value) ? value : NaN
  if (typeof value === 'string' && /^[0-9]{1,9}$/.test(value.trim())) return Number(value.trim())
  return NaN
}

function printConfiguration(product, values) {
  const errors = []
  const input = {}
  for (const id of ['pages', 'copies']) {
    if (isBlank(values[id])) {
      if (id === 'pages') errors.push({ field: 'pages', message: 'Enter how many pages to print.' })
      else input.copies = A4_COUNTER_PRINT_DEFAULTS.copies
      continue
    }
    const parsed = wholeNumber(values[id])
    if (Number.isNaN(parsed)) errors.push({ field: id, message: `${id === 'pages' ? 'Pages' : 'Copies'} must be a whole number.` })
    else input[id] = parsed
  }
  for (const id of ['printMode', 'sides', 'finish']) if (!isBlank(values[id])) input[id] = values[id]
  if (errors.length) return { ok: false, errors }
  const check = validateA4CounterPrintInput(input)
  if (!check.ok) {
    return { ok: false, errors: check.errors.map((error) => ({ field: error.field, message: error.message.charAt(0).toUpperCase() + error.message.slice(1) })) }
  }
  return { ok: true, errors: [], configuration: buildA4CounterPrintConfig(input) }
}

function perUnitConfiguration(product, values) {
  const result = calculatePerUnit(product.pricing, { units: isBlank(values.units) ? undefined : values.units })
  if (!result.ok) return { ok: false, errors: [{ field: 'units', message: result.message }] }
  return { ok: true, errors: [], configuration: { units: result.units } }
}

function genericConfiguration(product, values) {
  const errors = []
  const configuration = {}
  for (const field of counterFields(product)) {
    const value = values[field.id]
    if (isBlank(value)) {
      const mustAnswer = field.required === true || (field.required !== false && (field.type === 'select' || field.type === 'segmented'))
      if (mustAnswer) errors.push({ field: field.id, message: field.type === 'number' ? `Enter ${fieldName(field).toLowerCase()}.` : `Choose ${fieldName(field).toLowerCase()}.` })
      continue
    }
    if (field.type === 'number') {
      const number = Number(value)
      if (!Number.isFinite(number)) errors.push({ field: field.id, message: `${fieldName(field)} must be a number.` })
      else if (typeof field.min === 'number' && number < field.min) errors.push({ field: field.id, message: `${fieldName(field)} must be at least ${field.min}.` })
      else configuration[field.id] = number
    } else {
      configuration[field.id] = value
    }
  }
  if (errors.length) return { ok: false, errors }
  const mirror = calculateProductPrice(product, configuration)
  if (mirror.metrics?.invalid) return { ok: false, errors: [{ field: null, message: mirror.summary }] }
  return { ok: true, errors: [], configuration }
}

// The configuration a future submission would carry, or the reasons there is none yet. A request
// product has no counter configuration in this slice. The physical A4 print goes through the counter
// print adapter; PER_UNIT products send only { units }.
export function buildCounterConfiguration(product, values) {
  if (!product || typeof values !== 'object' || values === null) {
    return { ok: false, errors: [{ field: null, message: 'Choose a product first.' }] }
  }
  if (isCounterPrintProduct(product)) return printConfiguration(product, values)
  if (isCounterPerUnitProduct(product)) return perUnitConfiguration(product, values)
  return genericConfiguration(product, values)
}

// ── preview ──────────────────────────────────────────────────────────────

// An ESTIMATE from the existing customer-safe pricing mirror, only for a valid configuration and only
// when the mirror produces a real amount. A quote-required or unrecognised strategy yields null: no
// total is invented.
export function estimateCounterTotal(product, configuration) {
  if (!product || !configuration) return null
  const result = calculateProductPrice(product, configuration)
  const metrics = result.metrics || {}
  if (metrics.invalid || metrics.quoteRequired) return null
  if (!Number.isFinite(result.total) || result.total <= 0) return null
  return { total: result.total, lines: result.lines || [] }
}

function optionLabel(field, value) {
  const option = Array.isArray(field.options) ? field.options.find((item) => item.id === value) : null
  return option?.label || String(value)
}

function summaryRows(product, configuration) {
  if (!configuration) return []
  const rows = []
  for (const field of counterFields(product)) {
    const value = configuration[field.id]
    if (value === undefined || value === null || value === '') continue
    const text = field.options ? optionLabel(field, value) : field.suffix ? `${value} ${field.suffix}` : String(value)
    rows.push({ label: fieldName(field), value: text })
  }
  return rows
}

// The one-line count for a configuration ("12 pages × 3 copies", "7 pages"), or null. Also used to describe
// an order that was already created, from the configuration the server recorded.
export function describeCounterConfiguration(product, configuration) {
  return unitSummary(product, configuration)
}

function unitSummary(product, configuration) {
  if (!configuration) return null
  if (isCounterPrintProduct(product)) return `${configuration.pages} page${configuration.pages === 1 ? '' : 's'} × ${configuration.copies} cop${configuration.copies === 1 ? 'y' : 'ies'}`
  if (isCounterPerUnitProduct(product)) {
    const field = counterFields(product).find((item) => item.id === 'units')
    const suffix = field?.suffix || 'units'
    return `${configuration.units} ${configuration.units === 1 && suffix.endsWith('s') ? suffix.slice(0, -1) : suffix}`
  }
  return null
}

// Everything the preview panel shows. There is no order number, id or status here: nothing exists yet.
export function buildCounterPreview(entry, draft) {
  const product = entry?.product
  const action = entry?.action || COUNTER_ACTIONS.ORDER
  const base = {
    productId: product?.id || null,
    productName: product?.name || null,
    action,
    customer: COUNTER_WALK_IN_LABEL,
    configuration: null,
    valid: false,
    errors: [],
    rows: [],
    unitSummary: null,
    estimate: null
  }
  if (!product) return base
  if (action === COUNTER_ACTIONS.REQUEST) return base

  const built = buildCounterConfiguration(product, draft?.productId === product.id ? draft.values : createCounterDraft(product).values)
  if (!built.ok) return { ...base, errors: built.errors }
  return {
    ...base,
    valid: true,
    configuration: built.configuration,
    rows: summaryRows(product, built.configuration),
    unitSummary: unitSummary(product, built.configuration),
    estimate: estimateCounterTotal(product, built.configuration)
  }
}
