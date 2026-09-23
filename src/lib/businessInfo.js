// QS-21.5 — single source of truth for real Quick Solution / Joint X
// business details (location display name, address, WhatsApp number).
// Every customer-facing display of these facts imports from here rather
// than hardcoding its own copy - this fixes two real problems found in
// this pass's audit: the WhatsApp number was hardcoded separately in 8
// different files (drifted from the real number), and the internal
// "Location 001" tenant label was shown directly to customers in 2
// places (Home hero eyebrow, footer). Internal code/data (e.g. Supabase
// location IDs) is unaffected - this only governs customer-facing text.
export const BUSINESS_NAME = 'Quick Solution'
export const BUSINESS_TAGLINE = 'by Joint X'

// Customer-facing location label - never "Location 001"/"LOCATION 001"
// or any other internal tenant numbering.
export const LOCATION_DISPLAY_NAME = 'Kite Cres, Riverside View'

export const BUSINESS_ADDRESS_LINES = ['13 Kite Cres', 'Riverside View', 'Midrand', 'South Africa']

// wa.me requires digits only (no "+", no spaces); WHATSAPP_DISPLAY is the
// human-readable form for on-page text.
export const WHATSAPP_NUMBER = '27693505865'
export const WHATSAPP_DISPLAY = '+27 69 350 5865'
export const WHATSAPP_URL = `https://wa.me/${WHATSAPP_NUMBER}`

// Same helper shape every call site already used inline
// (`https://wa.me/<number>?text=<encoded>`) - centralised so the number
// can never drift between files again.
export function buildWhatsappUrl(text) {
  return text ? `${WHATSAPP_URL}?text=${text}` : WHATSAPP_URL
}

// QS-21.5 section 9 — DISPLAY-ONLY delivery/fulfilment information for
// Product Detail's "Collection & delivery" accordion and the footer's
// Fulfilment column. Deliberately a SEPARATE structure from
// `fulfilmentOptions` (src/data/products.js), which drives the real
// checkout fulfilment-selection step (GuidedOrder.jsx's `step.type ===
// 'fulfilment'`) - audited before writing this: zero PAXI/national-
// courier logic exists anywhere in the order RPC or backend today, so
// adding those as fulfilmentOptions entries would make them real,
// clickable, backend-unsupported checkout choices. PAXI/wider courier
// delivery is a real service Joint X offers, just not yet an automated
// checkout radio button, so it is presented here as "message us to
// arrange" rather than implied as instant self-service - PDP copy never
// promises more than checkout can currently do.
export const DELIVERY_INFO = [
  {
    id: 'local-collect',
    icon: 'store',
    title: 'Collect locally',
    helper: 'Quick Solution Café or a nearby Quick Point - choose this at checkout.'
  },
  {
    id: 'local-delivery',
    icon: 'truck',
    title: 'Local delivery',
    helper: 'Fee and address confirmed when you place your order.'
  },
  {
    id: 'courier',
    icon: 'signpost',
    title: 'PAXI / courier, nationwide',
    helper: 'Available on request - message us on WhatsApp to arrange and confirm cost.'
  }
]

// QS-21.5 section 13 — no returns/refund/terms policy exists anywhere in
// this repo (audited: no /terms or /returns route, no policy copy in any
// component or root .md file). Custom/printed-to-order goods genuinely
// need different handling than generic retail stock, so this uses the
// conservative operational wording the brief itself specified for
// exactly this "no source policy" situation, rather than inventing a
// blanket legal guarantee.
export const RETURNS_POLICY_TEXT = "Because many items are made or printed to order, return eligibility depends on the product and issue. If there is a production problem or your order is incorrect, contact us and we'll review it."

// QS-21.5 section 11 — audited GuidedOrder/OrderBasket/PaymentReturn/
// supabaseApi.js and the PayFast edge function call shape: payment is an
// opaque hosted PayFast redirect (init -> payment_url -> full-page
// redirect -> server-side ITN confirms). No env var, config object or
// comment anywhere states which specific methods (Visa/Mastercard/Apple
// Pay/Instant EFT/etc) are enabled on the live PayFast merchant account -
// that is entirely a PayFast-dashboard concern invisible to this
// codebase. Per the brief's own explicit fallback for exactly this case:
// conservative wording, PayFast brand only, no method-level claims.
export const PAYMENT_TRUST_TEXT = 'Secure checkout via PayFast'
// Public fulfilment-point payloads retain stable internal names/IDs.
// Café rows are customer-facing through this resolver so an internal
// tenant label such as "Location 001" can never leak into the storefront.
export function resolveFulfilmentPointDisplayName(point) {
  if (!point) return ''
  if (point.kind === 'cafe') return `Quick Solution Caf\u00e9 \u00b7 ${LOCATION_DISPLAY_NAME}`
  return point.name || 'Quick Point'
}
