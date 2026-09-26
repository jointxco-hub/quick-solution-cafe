// Builds the staff-only pricing_definition an admin save sends to
// admin_update_quick_solution_product, from the product being edited.
//
// Moved out of supabaseApi.js unchanged (that module reads import.meta.env at
// load, so nothing in it could be exercised directly); supabaseApi.js
// re-exports it, so every caller is unaffected. The only behavioural addition
// is the PER_UNIT branch (CAFE-GUEST-01G).
import { validatePerUnitDefinition } from './perUnitPricing.js'

function optionMap(product, fieldId, valueKey) {
  const field = product.fields?.find((item) => item.id === fieldId)
  return Object.fromEntries((field?.options || []).map((option) => [option.id, { [valueKey]: Number(option[valueKey] || 0) }]))
}

// The option modifiers the generic admin editor can edit. A PER_UNIT product
// prices as units x unitPrice ONLY, so none may be present on it: the server
// would never charge them, but the storefront would display them.
const PRICED_OPTION_KEYS = ['rate', 'fee', 'multiplier', 'total', 'unitFee']

function firstPricedOption(product) {
  for (const field of product.fields || []) {
    for (const option of field.options || []) {
      const key = PRICED_OPTION_KEYS.find((candidate) => option[candidate] !== undefined && option[candidate] !== null)
      if (key) return `${field.id}.${option.id}.${key}`
    }
  }
  return null
}

export function buildPricingDefinition(product) {
  const strategy = product?.pricing?.strategy
  if (strategy === 'PER_AREA') {
    return {
      strategy,
      baseRate: Number(product.pricing.baseRate || 0),
      minimumBillableArea: Number(product.pricing.minimumBillableArea || 0),
      materials: optionMap(product, 'material', 'multiplier'),
      finishing: optionMap(product, 'finishing', 'fee'),
      artwork: optionMap(product, 'artwork', 'fee'),
      turnaround: optionMap(product, 'turnaround', 'multiplier')
    }
  }
  if (strategy === 'PER_PAGE') {
    return {
      strategy,
      rates: optionMap(product, 'printMode', 'rate'),
      sides: optionMap(product, 'sides', 'multiplier'),
      finishes: optionMap(product, 'finish', 'fee')
    }
  }
  if (strategy === 'TIERED') {
    return {
      strategy,
      quantities: optionMap(product, 'quantity', 'total'),
      stock: optionMap(product, 'stock', 'multiplier'),
      finishes: optionMap(product, 'finish', 'fee'),
      artwork: optionMap(product, 'artwork', 'fee')
    }
  }
  if (strategy === 'CONFIGURABLE') {
    return {
      strategy,
      garments: optionMap(product, 'garment', 'unitFee'),
      frontPrint: optionMap(product, 'frontPrint', 'unitFee'),
      backPrint: optionMap(product, 'backPrint', 'unitFee'),
      artwork: optionMap(product, 'artwork', 'fee')
    }
  }
  if (strategy === 'PER_UNIT') {
    // Exactly the four contract fields, taken as given: nothing is coerced,
    // clamped or defaulted (a string, NaN, 0 or a fractional-cent price is
    // rejected here, and again by the server). The customer mirror
    // (product.pricing) and this definition hold the same numbers, as for
    // PER_AREA; the server re-normalizes both to these four keys on save.
    const definition = {
      strategy,
      unitPrice: product.pricing.unitPrice,
      minUnits: product.pricing.minUnits,
      maxUnits: product.pricing.maxUnits
    }
    const checked = validatePerUnitDefinition(definition)
    if (!checked.ok) throw new Error(`PER_UNIT pricing is invalid: ${checked.problem}`)
    const priced = firstPricedOption(product)
    if (priced) {
      throw new Error(`PER_UNIT products cannot have priced field options (${priced}); the price is the unit price times the number of units only.`)
    }
    return definition
  }
  if (strategy === 'ENQUIRY') {
    return {
      strategy,
      quoteRequired: true,
      serviceType: product?.serviceType || 'service'
    }
  }
  if (strategy === 'SUPPLIER_MARGIN' || strategy === 'PHOTOGRAPHY_SESSION') {
    // These two strategies split pricing into a customer-safe mirror
    // (product.pricing — selling prices only) and a staff-only
    // pricing_definition (product.pricingDefinition — reference
    // prices/margin rate/session rates), unlike every other strategy
    // above where both are effectively the same numbers. The generic
    // admin PricingEditor only reads/edits product.pricing and
    // product.fields[].options[], so it cannot safely edit reference
    // prices or margin without a dedicated section (not built yet —
    // see AdminProductManager.jsx). Passing pricingDefinition through
    // unchanged still lets admins rename/activate-deactivate these
    // products without corrupting their pricing.
    if (!product.pricingDefinition) {
      throw new Error('This product’s rates can only be edited via a database migration until a dedicated admin editor is built for this pricing strategy.')
    }
    return product.pricingDefinition
  }
  throw new Error(`Unsupported pricing strategy: ${strategy || 'unknown'}`)
}
