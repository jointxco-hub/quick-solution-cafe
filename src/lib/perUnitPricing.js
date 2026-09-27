// CAFE-GUEST-01F - neutral PER_UNIT pricing primitive (client mirror).
//
//   total = units x unitPrice
//
// a fixed price per validated whole number of service units. Nothing here is
// specific to any product: any counted service consumes this strategy by
// supplying its own numbers. The first product to do so is Scan
// (CAFE-GUEST-01H), one unit = one page scanned; this code knows nothing of it.
//
// Contract (identical on the server: commerce._qs_price_per_unit, migration
// 20260926130000_cafe_guest_01f_per_unit_pricing.sql):
//
//   pricing definition   { strategy: 'PER_UNIT', unitPrice, minUnits, maxUnits }
//     unitPrice   JSON number, > 0, <= 100000, in whole cents (at most two
//                 decimal places), so the total is exact and needs no rounding
//     minUnits    JSON integer >= 1
//     maxUnits    JSON integer >= minUnits and <= 10000
//     Any other shape is rejected as "Pricing configuration is invalid."
//     No tiers, minimum charge, setup fee, discount or variants.
//
//   configuration        { units }
//     The unit count key is `units`, NOT `quantity`: the OPPS handoff reads
//     configuration.quantity as a product-quantity override (line quantity and
//     unit price = line_total / quantity), and TIERED / CONFIGURABLE /
//     SUPPLIER_MARGIN already give `quantity` their own meaning. `units`,
//     `unitPrice`, `minUnits` and `maxUnits` are used by no other strategy in the
//     catalogue. A PER_UNIT order line keeps service_order_items.quantity = 1.
//     units is required, and must be either
//       - a JSON number that is a whole number, or
//       - a string of digits with no sign, decimal point, exponent, spaces or
//         leading zeros (number inputs deliver strings).
//     More than nine digits, or a value outside [minUnits, maxUnits], is out
//     of range. Nothing is clamped, defaulted or rounded.
//
// Money: whole-cent unit prices make the total exact, computed in integer
// cents, so this and the server's numeric arithmetic cannot differ.
//
// The server remains the price authority; this only mirrors it for estimates.
// The pricing definition seen by the customer (product.pricing) carries only
// the selling price and the unit limits - the same convention as PER_AREA's
// baseRate - never anything private.

export const PER_UNIT_LIMITS = Object.freeze({
  minUnitsFloor: 1,
  maxUnitsCeiling: 10000,
  maxUnitPrice: 100000,
  maxUnitDigits: 9
})

// The server raises these exact messages (errcode 22023).
export const PER_UNIT_MESSAGES = Object.freeze({
  definitionInvalid: 'Pricing configuration is invalid.',
  unitsRequired: 'Units are required.',
  unitsNotWhole: 'Units must be a whole number.',
  unitsOutOfRange: 'Units are outside the supported range.'
})

const CODES = Object.freeze({
  definition_invalid: PER_UNIT_MESSAGES.definitionInvalid,
  required: PER_UNIT_MESSAGES.unitsRequired,
  not_whole: PER_UNIT_MESSAGES.unitsNotWhole,
  out_of_range: PER_UNIT_MESSAGES.unitsOutOfRange
})

// `problem` (definition failures only) names the rule that failed, for the
// admin editor. The server-facing `message` is unchanged.
const fail = (code, problem) => (problem ? { ok: false, code, message: CODES[code], problem } : { ok: false, code, message: CODES[code] })

const isWhole = (value) => typeof value === 'number' && Number.isInteger(value)

// unitPrice must be a plain decimal with at most two places. Checking the
// number's own shortest decimal text matches the server, which sees exactly
// that text in JSON (so 0.1 + 0.2, 19.995 and 1e-7 are all rejected).
const WHOLE_CENTS = /^[0-9]+(\.[0-9]{1,2})?$/

export function validatePerUnitDefinition(pricing) {
  if (pricing === null || typeof pricing !== 'object' || Array.isArray(pricing)) {
    return fail('definition_invalid', 'the pricing definition must be an object.')
  }
  const { unitPrice, minUnits, maxUnits } = pricing

  if (typeof unitPrice !== 'number' || !Number.isFinite(unitPrice)) {
    return fail('definition_invalid', 'unitPrice must be a number.')
  }
  if (unitPrice <= 0 || unitPrice > PER_UNIT_LIMITS.maxUnitPrice) {
    return fail('definition_invalid', `unitPrice must be greater than 0 and at most ${PER_UNIT_LIMITS.maxUnitPrice}.`)
  }
  if (!WHOLE_CENTS.test(String(unitPrice))) {
    return fail('definition_invalid', 'unitPrice must be in whole cents (at most two decimal places).')
  }

  if (!isWhole(minUnits) || !isWhole(maxUnits)) {
    return fail('definition_invalid', 'minUnits and maxUnits must be whole numbers.')
  }
  if (minUnits < PER_UNIT_LIMITS.minUnitsFloor) {
    return fail('definition_invalid', `minUnits must be at least ${PER_UNIT_LIMITS.minUnitsFloor}.`)
  }
  if (maxUnits < minUnits) return fail('definition_invalid', 'maxUnits must be at least minUnits.')
  if (maxUnits > PER_UNIT_LIMITS.maxUnitsCeiling) {
    return fail('definition_invalid', `maxUnits must be at most ${PER_UNIT_LIMITS.maxUnitsCeiling}.`)
  }

  return { ok: true, unitPrice, unitPriceCents: Math.round(unitPrice * 100), minUnits, maxUnits }
}

const PLAIN_DIGITS = /^(0|[1-9][0-9]*)$/

// A non-finite JS number stands for a value beyond any limit (the server sees
// an oversized JSON number as out of range); NaN is simply not a number.
export function parseUnits(value) {
  if (value === undefined || value === null) return fail('required')
  if (typeof value === 'number') {
    if (Number.isNaN(value)) return fail('not_whole')
    if (!Number.isFinite(value)) return fail('out_of_range')
    return Number.isInteger(value) ? { ok: true, units: value } : fail('not_whole')
  }
  if (typeof value === 'string') {
    if (!PLAIN_DIGITS.test(value)) return fail('not_whole')
    if (value.length > PER_UNIT_LIMITS.maxUnitDigits) return fail('out_of_range')
    return { ok: true, units: Number(value) }
  }
  return fail('not_whole')
}

// Validates the definition, then the unit count, in the same order as the
// server, and only then prices. Returns { ok: true, ... } or
// { ok: false, code, message }; a failed result carries no total.
export function calculatePerUnit(pricing, configuration) {
  const definition = validatePerUnitDefinition(pricing)
  if (!definition.ok) return definition

  const parsed = parseUnits(configuration?.units)
  if (!parsed.ok) return parsed
  if (parsed.units < definition.minUnits || parsed.units > definition.maxUnits) return fail('out_of_range')

  const total = (parsed.units * definition.unitPriceCents) / 100
  return {
    ok: true,
    units: parsed.units,
    unitPrice: definition.unitPrice,
    total,
    summary: `${parsed.units} × ${definition.unitPrice.toFixed(2)}`,
    lines: [{ label: 'Units', value: total }],
    metrics: { units: parsed.units, unitPrice: definition.unitPrice }
  }
}
