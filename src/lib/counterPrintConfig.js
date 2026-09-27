// CAFE-GUEST-01F - A4 counter print configuration adapter.
//
// Turns the staff-friendly choices for a physical A4 print job
//   pages = 12, copies = 3, printMode = 'bw', sides = 'single', finish = 'none'
// into the EXISTING configuration shape the a4-print product already uses,
// so the server (commerce.qs_calculate_price) stays the only price authority.
// This module calculates nothing: it holds no rates, multipliers, fees, costs
// or margins, imports nothing, and does no I/O.
//
// The existing contract it targets (storefront cart config + server):
//   pages                 one source set's page count. The server ignores the
//                         client's value and recomputes it from
//                         documentInstructions; it is sent because the
//                         storefront config carries it and the client price
//                         mirror reads it.
//   copies                whole sets. printedPages = pages x copies is derived
//                         by the server (metrics.printedPages), never sent.
//   printMode/sides/finish  option ids of the a4-print product.
//   documentInstructions  1..25 entries. Each is { selection: 'all',
//                         sourcePages } (or 'specific' + pagesSpec, not
//                         supported here). This adapter emits exactly one
//                         { selection: 'all', sourcePages: pages }.
//   documentPlanValid     true: the client-side "plan is valid" flag the
//                         storefront sets; the server overwrites it.
//
// A physical / no-stored-file job is expressed truthfully: there is no
// fileName, no fileRefs, no file record and no invented instruction metadata
// (no key, name, mimeType or source marker).
//
// configuration.quantity is NEVER produced. service_order_items.quantity stays
// 1, and the OPPS handoff treats configuration.quantity as a product-quantity
// override (line quantity, and unit price = line_total / quantity), so a
// quantity key would misrepresent a print job. Input carrying a `quantity`
// (or any other unknown field) is rejected rather than ignored.
//
// Validation is structural only, and stricter rather than different from the
// server: the server silently raises copies below 1 to 1 and casts numeric
// strings, while this rejects them so nothing is mutated on the way through.
// Numbers must be real integers (parse UI text before calling).

// Pinned to the server contract:
//   qs_normalize_document_configuration: sourcePages 1..1000 per document,
//     total <= 1000 (one document here), 1..25 documents
//   qs_calculate_price_legacy PER_PAGE:  copies clamped >= 1, <= 500
export const A4_COUNTER_PRINT_LIMITS = Object.freeze({
  pagesMin: 1,
  pagesMax: 1000,
  copiesMin: 1,
  copiesMax: 500
})

// The current a4-print option ids. The server validates them against the live
// pricing definition; if an admin adds an option, this list must be extended.
export const A4_COUNTER_PRINT_OPTIONS = Object.freeze({
  printModes: Object.freeze(['bw', 'colour']),
  sides: Object.freeze(['single', 'double']),
  finishes: Object.freeze(['none', 'staple', 'clear-sleeve'])
})

// Established defaults only: the a4-print field defaults and the server's own
// fallbacks agree on these four. pages has NO default (the client default is
// 0, the seeded definition says 1, and the server requires at least one
// counted page), so it is required.
export const A4_COUNTER_PRINT_DEFAULTS = Object.freeze({
  copies: 1,
  printMode: 'bw',
  sides: 'single',
  finish: 'none'
})

const KNOWN_FIELDS = ['pages', 'copies', 'printMode', 'sides', 'finish']

export class CounterPrintInputError extends Error {
  constructor(errors) {
    super(`Invalid A4 counter print input: ${errors.map((error) => `${error.field} (${error.code})`).join(', ')}`)
    this.name = 'CounterPrintInputError'
    this.errors = errors
  }
}

function checkInteger(field, value, min, max, errors) {
  if (typeof value !== 'number' || !Number.isInteger(value)) {
    errors.push({ field, code: 'not_integer', message: `${field} must be a whole number.` })
  } else if (value < min || value > max) {
    errors.push({ field, code: 'out_of_range', message: `${field} must be between ${min} and ${max}.` })
  }
}

function checkOption(field, value, allowed, errors) {
  if (typeof value !== 'string' || !allowed.includes(value)) {
    errors.push({ field, code: 'invalid_option', message: `${field} must be one of: ${allowed.join(', ')}.` })
  }
}

// Returns { ok: true, errors: [] } or { ok: false, errors: [{ field, code, message }] }.
// Never throws, never mutates the input.
export function validateA4CounterPrintInput(input) {
  const errors = []
  if (input === null || typeof input !== 'object' || Array.isArray(input)) {
    return { ok: false, errors: [{ field: 'input', code: 'invalid_input', message: 'Counter print input must be an object.' }] }
  }

  const { pages, copies, printMode, sides, finish } = input

  if (pages === undefined) {
    errors.push({ field: 'pages', code: 'required', message: 'pages is required.' })
  } else {
    checkInteger('pages', pages, A4_COUNTER_PRINT_LIMITS.pagesMin, A4_COUNTER_PRINT_LIMITS.pagesMax, errors)
  }
  if (copies !== undefined) {
    checkInteger('copies', copies, A4_COUNTER_PRINT_LIMITS.copiesMin, A4_COUNTER_PRINT_LIMITS.copiesMax, errors)
  }
  if (printMode !== undefined) checkOption('printMode', printMode, A4_COUNTER_PRINT_OPTIONS.printModes, errors)
  if (sides !== undefined) checkOption('sides', sides, A4_COUNTER_PRINT_OPTIONS.sides, errors)
  if (finish !== undefined) checkOption('finish', finish, A4_COUNTER_PRINT_OPTIONS.finishes, errors)

  for (const key of Object.keys(input)) {
    if (!KNOWN_FIELDS.includes(key)) {
      errors.push({ field: key, code: 'unknown_field', message: `${key} is not an A4 counter print input.` })
    }
  }

  return { ok: errors.length === 0, errors }
}

// Returns a NEW a4-print configuration for one physical A4 page set, or throws
// CounterPrintInputError (with .errors) if the input is invalid.
export function buildA4CounterPrintConfig(input) {
  const { ok, errors } = validateA4CounterPrintInput(input)
  if (!ok) throw new CounterPrintInputError(errors)

  const pages = input.pages
  return {
    pages,
    copies: input.copies ?? A4_COUNTER_PRINT_DEFAULTS.copies,
    printMode: input.printMode ?? A4_COUNTER_PRINT_DEFAULTS.printMode,
    sides: input.sides ?? A4_COUNTER_PRINT_DEFAULTS.sides,
    finish: input.finish ?? A4_COUNTER_PRINT_DEFAULTS.finish,
    documentInstructions: [{ selection: 'all', sourcePages: pages }],
    documentPlanValid: true
  }
}
