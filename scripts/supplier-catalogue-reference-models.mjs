// Staff-only rate provenance. Never import this module into src/.
export const supplierOperations = {
  contravision: {
    sourceName: 'Owner-confirmed local merchant (name pending)', checkedAt: '2026-10-06',
    supplierCost: 150, vatBasis: 'no_supplier_vat', vatRate: 0, costBasis: 150,
    marginRate: 0.5, modelRate: 300, model: 'supplier cost / (1 - gross margin)',
    supplierPriceConfirmed: true, supplierTermsConfirmed: false, rollout: 'staging-model',
    scope: 'R150/m² and no supplier VAT confirmed by owner. Rectangular print only; no fitting, shaped trimming or protective laminate assumed. 1m² minimum is Café policy. Merchant name, usable panel width, lead time, minimum and collection/freight arrangements remain to be recorded.'
  },
  'correx-boards': {
    sourceName: 'Same owner-referenced local merchant (name pending)', checkedAt: '2026-10-06',
    reportedA0Price: 200, reportedA0PriceConfirmed: false, a0CostAllowance: 350,
    vatBasis: 'owner_cost_allowance_no_vat_uplift', marginRate: 0.5,
    derivedCostAllowances: { a3: 43.75, a2: 87.5, a1: 175, a0: 350 },
    model: 'A0 cost allowance / 2^(paper-size index), then / (1 - gross margin)',
    rollout: 'owner-approved-staging-model', supplierPriceConfirmed: false,
    scope: 'Owner directed R350 A0 cost allowance despite tentative R200 supplier recollection. Other sizes are derived internal allowances, not merchant quotations. Single-sided print, unmounted. Confirm thickness, cut yield, minimums and fulfilment. Custom sizes/double sides/eyelets/installation require the Shop Signs quote flow.'
  }
}

export function supplierPricingDefinition(product, buildDefault) {
  if (product.id === 'contravision') return { ...buildDefault(product), areaSupplier: {
    supplierCost: 150, marginRate: 0.5, vatBasis: 'none', vatRate: 0,
    sourceName: supplierOperations.contravision.sourceName
  } }
  if (product.id !== 'correx-boards') return buildDefault(product)
  return {
    strategy: 'SUPPLIER_MARGIN', marginRate: 0.5, minQuantity: 1,
    sourceName: 'Owner-approved A0 cost allowance; local merchant name pending',
    defaultPricingMode: 'cost_margin', vatBasis: 'excl_vat', vatRate: 0,
    variants: Object.fromEntries(Object.entries(product.pricing.variants).map(([id, variant]) => [id, {
      label: variant.label, pricingMode: 'cost_margin',
      supplierCost: supplierOperations['correx-boards'].derivedCostAllowances[id],
      referencePrice: supplierOperations['correx-boards'].derivedCostAllowances[id]
    }])), accessories: {}, artwork: product.pricing.artwork
  }
}
