// Private admin model. Never include this object in customer definitions.
export function areaSupplierRate(model) {
  const number = (value, name) => {
    if (value == null || value === '' || !Number.isFinite(Number(value))) throw new Error(`Enter a valid ${name}.`)
    return Number(value)
  }
  const cost = number(model.supplierCost, 'supplier cost')
  const margin = number(model.marginRate, 'gross margin')
  const vat = number(model.vatRate, 'supplier VAT rate')
  if (cost <= 0 || margin < 0 || margin >= 1 || vat < 0 || vat > 1) throw new Error('Cost must be positive; gross margin must be below 100%; VAT must be between 0% and 100%.')
  if (!['none', 'incl_vat', 'excl_vat'].includes(model.vatBasis)) throw new Error('Choose a valid supplier VAT basis.')
  const basis = cost * (model.vatBasis === 'excl_vat' ? 1 + vat : 1)
  return Math.round((basis / (1 - margin) + Number.EPSILON) * 100) / 100
}

export function validateRequestFields(fields) {
  for (const field of fields) {
    if (field.type === 'number') {
      for (const key of ['min', 'max', 'step', 'default']) if (!Number.isFinite(Number(field[key])) || field[key] === '') throw new Error(`${field.label}: enter valid number settings.`)
      if (Number(field.min) > Number(field.max) || Number(field.step) <= 0 || Number(field.default) < Number(field.min) || Number(field.default) > Number(field.max)) throw new Error(`${field.label}: default must be within the range, with a positive step.`)
    }
    if (field.options?.length && (!field.options.some(option => option.id === field.default) || field.options.some(option => !option.label?.trim()))) throw new Error(`${field.label}: choose an existing default and label every option.`)
  }
}
