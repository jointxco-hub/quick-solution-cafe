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
  const pages = Math.max(Number(config.pages || 0), 0)
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
    summary: pages > 0
      ? `${pages} page${pages === 1 ? '' : 's'} × ${copies} cop${copies === 1 ? 'y' : 'ies'}`
      : 'Page selection needed',
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

// Client-side estimate only — the server (commerce.qs_calculate_price)
// always recalculates from pricing_definition and is what's actually
// charged; this exists purely for instant UI feedback. It reads
// product.pricing.variants[id].price / accessories[id].price, which
// are the CUSTOMER-SAFE, already-margin-applied selling prices the
// public catalog exposes — never a raw referencePrice or marginRate
// (those live only in the staff-only pricing_definition, which this
// client never receives).
// Per-variant minQuantity/quantityStep (falling back to the product
// default) — e.g. single-sided flags: minimum 2, step 2 ("must be
// bought in pairs of 2"). Exported so the guided configurator can size
// its quantity control correctly the moment a variant is chosen,
// without duplicating this fallback logic.
export function getVariantQuantityRule(product, variantId) {
  const variant = product?.pricing?.variants?.[variantId]
  const minQuantity = Math.max(Number(variant?.minQuantity ?? product?.pricing?.minQuantity ?? 1), 1)
  const quantityStep = Math.max(Number(variant?.quantityStep ?? 1), 1)
  return { minQuantity, quantityStep }
}

function isQuantityValid(quantity, minQuantity, quantityStep) {
  if (quantity < minQuantity) return false
  if (quantityStep > 1 && (quantity - minQuantity) % quantityStep !== 0) return false
  return true
}

// An accessory with no compatibleVariants (or an empty one) is
// universal — same convention as the server.
function accessoryCompatible(accessory, variantId) {
  if (!Array.isArray(accessory?.compatibleVariants) || accessory.compatibleVariants.length === 0) return true
  return accessory.compatibleVariants.includes(variantId)
}

function priceSupplierMargin(product, config) {
  const variant = product.pricing.variants?.[config.variant]
  const { minQuantity, quantityStep } = getVariantQuantityRule(product, config.variant)
  // Deliberately NOT clamped up to minQuantity here (unlike most other
  // strategies' quantity handling) — silently rounding an invalid
  // quantity up would hide a real validation failure instead of
  // reporting it, and would disagree with the server, which rejects an
  // out-of-range/wrong-step quantity outright rather than correcting it.
  const quantity = config.quantity == null || config.quantity === '' ? minQuantity : Number(config.quantity)
  const accessoryIds = Array.isArray(config.accessories) ? config.accessories : []
  const artwork = config.artwork ? product.pricing.artwork?.[config.artwork] : null

  const invalidQuantity = !isQuantityValid(quantity, minQuantity, quantityStep)
  const incompatibleAccessory = accessoryIds.some((id) => {
    const accessory = product.pricing.accessories?.[id]
    return !accessory || !accessoryCompatible(accessory, config.variant)
  })

  const quoteRequired =
    !variant || variant.price == null ||
    accessoryIds.some((id) => !product.pricing.accessories?.[id] || product.pricing.accessories[id].price == null) ||
    (config.artwork && (!artwork || artwork.fee == null))

  if (invalidQuantity || incompatibleAccessory) {
    return {
      total: 0,
      summary: invalidQuantity
        ? (quantityStep > 1 ? `Order in multiples of ${quantityStep} (minimum ${minQuantity})` : `Minimum quantity is ${minQuantity}`)
        : 'One or more accessories are not available for this option',
      lines: [],
      metrics: { quoteRequired: false, invalid: true, quantity, minQuantity, quantityStep }
    }
  }

  if (quoteRequired) {
    return {
      total: 0,
      summary: 'Quote required',
      lines: [{ label: 'Pricing', text: 'One or more selected options need a quote' }],
      metrics: { quoteRequired: true, quantity, minQuantity, quantityStep }
    }
  }

  const variantTotal = Number(variant.price) * quantity
  const accessoriesTotal = accessoryIds.reduce((sum, id) => sum + Number(product.pricing.accessories[id].price), 0)
  const artworkFee = artwork ? Number(artwork.fee || 0) : 0
  const total = variantTotal + accessoriesTotal + artworkFee

  const lines = [{ label: variant.label, value: variantTotal }]
  for (const id of accessoryIds) lines.push({ label: product.pricing.accessories[id].label, value: Number(product.pricing.accessories[id].price) })
  if (artworkFee > 0) lines.push({ label: artwork.label, value: artworkFee })

  return {
    total,
    summary: `${variant.label} × ${quantity}`,
    lines,
    metrics: { quantity, minQuantity, quantityStep, unitPrice: Number(variant.price), quoteRequired: false }
  }
}

function pricePhotographySession(product, config) {
  const sessionId = config.session || '30min-7edits'
  const session = product.pricing.sessions?.[sessionId]
  const extraEdits = Math.max(Number(config.extraEdits || 0), 0)
  const deliverableIds = Array.isArray(config.deliverables) ? config.deliverables : []

  const sessionUnpriced = !session || session.price == null
  const extraEditsUnpriced = extraEdits > 0 && product.pricing.extraEditRate == null
  const deliverablesUnpriced = deliverableIds.some((id) => {
    const deliverable = product.pricing.deliverables?.[id]
    return !deliverable || deliverable.price == null
  })
  const quoteRequired = sessionUnpriced || extraEditsUnpriced || deliverablesUnpriced

  if (quoteRequired) {
    return {
      total: 0,
      summary: 'Quote required',
      lines: [{ label: 'Pricing', text: 'One or more selected options need a quote' }],
      metrics: { quoteRequired: true, sessionId, extraEdits }
    }
  }

  const lines = [{ label: session.label, value: Number(session.price) }]
  let total = Number(session.price)
  if (extraEdits > 0) {
    const extraTotal = extraEdits * Number(product.pricing.extraEditRate)
    total += extraTotal
    lines.push({ label: `${extraEdits} extra edited photo${extraEdits === 1 ? '' : 's'}`, value: extraTotal })
  }
  for (const id of deliverableIds) {
    const deliverable = product.pricing.deliverables[id]
    total += Number(deliverable.price)
    lines.push({ label: deliverable.label, value: Number(deliverable.price) })
  }

  return {
    total,
    summary: session.label,
    lines,
    metrics: { quoteRequired: false, sessionId, durationMinutes: session.durationMinutes, includedEdits: session.includedEdits, extraEdits }
  }
}

function priceEnquiry(product, config) {
  return {
    total: 0,
    summary: 'Quote after review',
    lines: [
      { label: 'Service request', text: 'Photo / video brief captured' },
      { label: 'Pricing', text: 'Confirmed after crew, location and scope review' }
    ],
    metrics: {
      quoteRequired: true,
      serviceType: product.serviceType || 'service'
    }
  }
}

export function calculateProductPrice(product, config) {
  let calculation
  switch (product.pricing.strategy) {
    case 'PER_AREA': calculation = priceArea(product, config); break
    case 'PER_PAGE': calculation = pricePages(product, config); break
    case 'TIERED': calculation = priceTiered(product, config); break
    case 'CONFIGURABLE': calculation = priceConfigurable(product, config); break
    case 'ENQUIRY': calculation = priceEnquiry(product, config); break
    case 'SUPPLIER_MARGIN': calculation = priceSupplierMargin(product, config); break
    case 'PHOTOGRAPHY_SESSION': calculation = pricePhotographySession(product, config); break
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
