const money = new Intl.NumberFormat('en-ZA', {
  style: 'currency',
  currency: 'ZAR',
  maximumFractionDigits: 2
})

export function formatMoney(value) {
  return money.format(Number(value || 0))
}

export function getDefaultConfig(product, preset = {}) {
  const defaults = {}
  for (const field of product.fields || []) {
    if (field.type !== 'file') defaults[field.id] = field.default ?? ''
  }
  return { ...defaults, ...preset }
}

function field(product, id) {
  return product.fields.find((item) => item.id === id)
}

function option(product, fieldId, optionId) {
  const definition = field(product, fieldId)
  return definition?.options?.find((item) => item.id === optionId) || definition?.options?.[0] || {}
}

function cleanConfig(config) {
  return Object.fromEntries(Object.entries(config).filter(([, value]) => !(value instanceof File)))
}

function priceArea(product, config) {
  const width = Math.max(Number(config.width || 0), 0)
  const height = Math.max(Number(config.height || 0), 0)
  const rawArea = width * height
  const billableArea = Math.max(rawArea, product.pricing.minimumBillableArea || 0)
  const material = option(product, 'material', config.material)
  const finishing = option(product, 'finishing', config.finishing)
  const artwork = option(product, 'artwork', config.artwork)
  const turnaround = option(product, 'turnaround', config.turnaround)

  const printBase = billableArea * product.pricing.baseRate * (material.multiplier || 1)
  const serviceFees = Number(finishing.fee || 0) + Number(artwork.fee || 0)
  const subtotal = printBase + serviceFees
  const total = subtotal * (turnaround.multiplier || 1)

  return {
    total,
    summary: `${rawArea.toFixed(2)}m² actual · ${billableArea.toFixed(2)}m² billable`,
    lines: [
      { label: `Print + ${material.label}`, value: printBase },
      { label: 'Finishing + artwork', value: serviceFees },
      { label: 'Turnaround', text: turnaround.label }
    ],
    metrics: { rawArea, billableArea }
  }
}

function pricePages(product, config) {
  const pages = Math.max(Number(config.pages || 1), 1)
  const copies = Math.max(Number(config.copies || 1), 1)
  const printMode = option(product, 'printMode', config.printMode)
  const sides = option(product, 'sides', config.sides)
  const finish = option(product, 'finish', config.finish)
  const printedPages = pages * copies
  const printCost = printedPages * Number(printMode.rate || 0) * Number(sides.multiplier || 1)
  const finishing = Number(finish.fee || 0) * copies
  const total = printCost + finishing

  return {
    total,
    summary: `${pages} page${pages === 1 ? '' : 's'} × ${copies} cop${copies === 1 ? 'y' : 'ies'}`,
    lines: [
      { label: printMode.label, value: printCost },
      { label: sides.label, text: sides.id === 'double' ? 'paper-saving option' : 'standard' },
      { label: finish.label, value: finishing }
    ],
    metrics: { pages, copies, printedPages }
  }
}

function priceTiered(product, config) {
  const quantity = option(product, 'quantity', config.quantity)
  const stock = option(product, 'stock', config.stock)
  const finish = option(product, 'finish', config.finish)
  const artwork = option(product, 'artwork', config.artwork)

  const printCost = Number(quantity.total || 0) * Number(stock.multiplier || 1)
  const serviceFees = Number(finish.fee || 0) + Number(artwork.fee || 0)
  const total = printCost + serviceFees

  return {
    total,
    summary: `${quantity.label} cards · ${stock.label}`,
    lines: [
      { label: `Cards · ${stock.label}`, value: printCost },
      { label: finish.label, value: Number(finish.fee || 0) },
      { label: artwork.label, value: Number(artwork.fee || 0) }
    ],
    metrics: { quantity: Number(quantity.id || 0) }
  }
}

function quantityDiscount(quantity) {
  if (quantity >= 25) return 0.9
  if (quantity >= 10) return 0.95
  return 1
}

function priceConfigurable(product, config) {
  const quantity = Math.max(Number(config.quantity || 1), 1)
  const garment = option(product, 'garment', config.garment)
  const front = option(product, 'frontPrint', config.frontPrint)
  const back = option(product, 'backPrint', config.backPrint)
  const artwork = option(product, 'artwork', config.artwork)
  const unit = Number(garment.unitFee || 0) + Number(front.unitFee || 0) + Number(back.unitFee || 0)
  const discount = quantityDiscount(quantity)
  const production = unit * quantity * discount
  const artworkFee = Number(artwork.fee || 0)
  const total = production + artworkFee

  return {
    total,
    summary: `${quantity} shirt${quantity === 1 ? '' : 's'} · ${garment.label}`,
    lines: [
      { label: 'Garment + print', value: production },
      { label: 'Artwork support', value: artworkFee },
      { label: 'Quantity pricing', text: discount < 1 ? `${Math.round((1 - discount) * 100)}% quantity saving` : 'standard' }
    ],
    metrics: { quantity, unit, discount }
  }
}

export function calculateProductPrice(product, config) {
  let calculation
  switch (product.pricing.strategy) {
    case 'PER_AREA': calculation = priceArea(product, config); break
    case 'PER_PAGE': calculation = pricePages(product, config); break
    case 'TIERED': calculation = priceTiered(product, config); break
    case 'CONFIGURABLE': calculation = priceConfigurable(product, config); break
    default: calculation = { total: 0, summary: 'Quote required', lines: [], metrics: {} }
  }

  return {
    ...calculation,
    snapshot: {
      pricingVersion: product.pricingVersion,
      productId: product.id,
      productName: product.name,
      pricingStrategy: product.pricing.strategy,
      configuration: cleanConfig(config),
      calculation: {
        lines: calculation.lines,
        metrics: calculation.metrics,
        total: calculation.total
      },
      capturedAt: new Date().toISOString()
    }
  }
}
