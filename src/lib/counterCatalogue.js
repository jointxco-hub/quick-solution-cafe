// CAFE-GUEST-01F - pure counter catalogue contract.
//
// The domain rules a future staff Counter UI will follow, with no UI, no
// route, no Supabase and no I/O. Everything here reads only the
// CUSTOMER-SAFE product shape that the public catalogue returns
// (channels, pricing.strategy, serviceType, category). It never reads
// pricing_definition, supplier cost, reference price, margin or any source
// URL, and it never mutates its input.
//
// INPUT CONTRACT: every function here assumes it is handed an ALREADY
// server-safe catalogue - only legitimately published, available products of
// the right tenant, delivered by a future server-side counter catalogue. This
// module does not check published or active state, availability, tenant
// capability, authorization, orderability or production eligibility, and it
// must not be extended to: those are decided on the server before a product
// reaches it. (A client default may even disagree with the database about
// `active`; that is not compensated for here.)
//
// Three independent questions, deliberately kept separate:
//   isCounterProduct      - VISIBILITY: may staff be shown this product?
//   resolveCounterAction  - the INITIAL action: order it, or send a request?
//   resolveCounterGroup   - PRESENTATION grouping only.
// None of them is authorization, pricing, production eligibility, handoff
// eligibility or order validation, and none feeds another.

export const COUNTER_ACTIONS = Object.freeze({
  ORDER: 'order',
  REQUEST: 'request'
})

export const COUNTER_GROUPS = Object.freeze({
  QUICK_SERVICES: 'Quick Services',
  PRODUCTION_AND_BRANDING: 'Production & Branding'
})

// Visibility. This answers ONLY "is channels.pos exactly true?" - it does not
// establish published state, active/available state, tenant capability,
// authorization, orderability or production eligibility (see INPUT CONTRACT).
// channels.pos must be the boolean true - the same fail-closed
// rule as commerce._qs_product_channel_enabled(..., 'counter') (CAFE-GUEST-01C):
// missing, null, false, and every non-boolean value ("true", 1, {}, [])
// are not counter products. Deliberately does not look at storefront,
// category, pricing or anything else; a counter-only product
// (storefront=false, pos=true) is visible here.
export function isCounterProduct(product) {
  return product?.channels?.pos === true
}

// The initial action only. The server can still price a specific
// configuration as quoteRequired (for example an unpriced supplier variant);
// the Counter UI turns 'order' into a request at that point. That is a
// runtime pricing outcome and is not predicted here.
//
// 'request' is the existing storefront rule (GuidedOrder.jsx isServiceRequest:
// strategy ENQUIRY, or serviceType 'media') plus PHOTOGRAPHY_SESSION, the other
// strategy public.create_quick_solution_service_request accepts and
// paid checkout rejects. Strategy is compared case-insensitively, as the
// server does (upper(...)). Anything else - PER_PAGE, PER_AREA, TIERED,
// CONFIGURABLE, SUPPLIER_MARGIN, an unknown or missing strategy - starts as
// 'order'; an unknown strategy is left for the server's pricing to reject.
export function resolveCounterAction(product) {
  const strategy = typeof product?.pricing?.strategy === 'string'
    ? product.pricing.strategy.toUpperCase()
    : ''
  if (strategy === 'ENQUIRY' || strategy === 'PHOTOGRAPHY_SESSION' || product?.serviceType === 'media') {
    return COUNTER_ACTIONS.REQUEST
  }
  return COUNTER_ACTIONS.ORDER
}

// Presentation grouping from the existing customer-safe category. Every
// category currently in the catalogue is listed explicitly so that adding a
// category is a visible decision (a test fails until it is mapped here); an
// unknown, missing, or non-string category falls back to
// 'Production & Branding' - the group that implies more careful handling -
// rather than presenting an unrecognised product as a quick service.
// Matching is exact (no trimming or case folding), like the Shop's own
// CATEGORY_TO_SHOP_BUCKET. 'Photo & Video' is not a quick service and there
// is no third group, so it sits under 'Production & Branding'.
// Never use this for authorization, pricing, handoff or production eligibility.
export const COUNTER_CATEGORY_GROUPS = Object.freeze({
  'Quick Print': COUNTER_GROUPS.QUICK_SERVICES,
  'Signs & Large Format': COUNTER_GROUPS.PRODUCTION_AND_BRANDING,
  'Labels & Packaging': COUNTER_GROUPS.PRODUCTION_AND_BRANDING,
  'Business Essentials': COUNTER_GROUPS.PRODUCTION_AND_BRANDING,
  'Clothing & Merch': COUNTER_GROUPS.PRODUCTION_AND_BRANDING,
  'Flags & Events': COUNTER_GROUPS.PRODUCTION_AND_BRANDING,
  'Photo & Video': COUNTER_GROUPS.PRODUCTION_AND_BRANDING
})

export function resolveCounterGroup(product) {
  const category = product?.category
  if (typeof category === 'string' && Object.prototype.hasOwnProperty.call(COUNTER_CATEGORY_GROUPS, category)) {
    return COUNTER_CATEGORY_GROUPS[category]
  }
  return COUNTER_GROUPS.PRODUCTION_AND_BRANDING
}

// One normalized record for the UI. `product` is the same object reference
// (not a copy).
export function resolveCounterProduct(product) {
  return {
    product,
    visible: isCounterProduct(product),
    action: resolveCounterAction(product),
    group: resolveCounterGroup(product)
  }
}

// The visible counter products, in input order. Does not mutate the input.
export function resolveCounterCatalogue(products) {
  return (Array.isArray(products) ? products : [])
    .map(resolveCounterProduct)
    .filter((entry) => entry.visible)
}
