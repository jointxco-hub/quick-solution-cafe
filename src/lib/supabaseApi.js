import { buildPricingDefinition } from './pricingDefinition.js'

const SUPABASE_URL = String(import.meta.env.VITE_SUPABASE_URL || '').replace(/\/$/, '')
const SUPABASE_KEY = String(import.meta.env.VITE_SUPABASE_PUBLISHABLE_KEY || import.meta.env.VITE_SUPABASE_ANON_KEY || '')
const TENANT_SLUG = String(import.meta.env.VITE_QS_TENANT_SLUG || 'quick-solution')
const ADMIN_SESSION_KEY = 'qsc_admin_session_v1'
const OPPS_APP_URL = String(import.meta.env.VITE_OPPS_APP_URL || 'https://ops.jointx.co.za').replace(/\/$/, '')

export function isSupabaseConfigured() {
  return Boolean(SUPABASE_URL && SUPABASE_KEY)
}

function apiHeaders(accessToken = null, contentType = 'application/json') {
  const headers = { apikey: SUPABASE_KEY }
  if (contentType) headers['Content-Type'] = contentType
  if (accessToken) headers.Authorization = `Bearer ${accessToken}`
  else if (SUPABASE_KEY.startsWith('eyJ')) headers.Authorization = `Bearer ${SUPABASE_KEY}`
  return headers
}

async function parseResponse(response, fallback) {
  let payload = null
  try { payload = await response.json() } catch { payload = null }
  if (!response.ok) {
    const message = payload?.msg || payload?.message || payload?.error_description || payload?.error || payload?.hint || `${fallback} (${response.status}).`
    const error = new Error(message)
    error.status = response.status
    error.payload = payload
    throw error
  }
  return payload
}

async function rpc(functionName, body, { accessToken = null } = {}) {
  if (!isSupabaseConfigured()) {
    throw new Error('Supabase is not configured. Add VITE_SUPABASE_URL and VITE_SUPABASE_PUBLISHABLE_KEY to .env.local.')
  }

  const response = await fetch(`${SUPABASE_URL}/rest/v1/rpc/${functionName}`, {
    method: 'POST',
    headers: apiHeaders(accessToken),
    body: JSON.stringify(body)
  })

  return parseResponse(response, 'Quick Solution backend request failed')
}

function readStoredSession() {
  if (typeof window === 'undefined') return null
  try {
    const raw = window.localStorage.getItem(ADMIN_SESSION_KEY)
    if (!raw) return null
    const parsed = JSON.parse(raw)
    if (!parsed?.access_token || !parsed?.refresh_token) return null
    return parsed
  } catch {
    return null
  }
}

function storeSession(payload) {
  if (typeof window === 'undefined') return payload
  const expiresAt = payload.expires_at
    ? Number(payload.expires_at) * 1000
    : Date.now() + Number(payload.expires_in || 3600) * 1000
  const session = { ...payload, expiresAt }
  window.localStorage.setItem(ADMIN_SESSION_KEY, JSON.stringify(session))
  return session
}

export function getAdminSession() {
  return readStoredSession()
}

async function refreshAdminSession(session) {
  if (!session?.refresh_token) return null
  const response = await fetch(`${SUPABASE_URL}/auth/v1/token?grant_type=refresh_token`, {
    method: 'POST',
    headers: apiHeaders(null),
    body: JSON.stringify({ refresh_token: session.refresh_token })
  })
  const payload = await parseResponse(response, 'Could not refresh the staff session')
  return storeSession(payload)
}

async function getAdminAccessToken() {
  let session = readStoredSession()
  if (!session) throw new Error('Staff sign-in is required.')
  if (!session.expiresAt || session.expiresAt <= Date.now() + 60_000) {
    session = await refreshAdminSession(session)
  }
  if (!session?.access_token) throw new Error('Staff sign-in is required.')
  return session.access_token
}

export async function signInAdmin(email, password) {
  if (!isSupabaseConfigured()) throw new Error('Supabase is not configured.')
  const response = await fetch(`${SUPABASE_URL}/auth/v1/token?grant_type=password`, {
    method: 'POST',
    headers: apiHeaders(null),
    body: JSON.stringify({ email: String(email || '').trim(), password: String(password || '') })
  })
  const payload = await parseResponse(response, 'Staff sign-in failed')
  return storeSession(payload)
}

export async function signOutAdmin() {
  const session = readStoredSession()
  if (session?.access_token) {
    try {
      await fetch(`${SUPABASE_URL}/auth/v1/logout`, {
        method: 'POST',
        headers: apiHeaders(session.access_token)
      })
    } catch {
      // Local sign-out still proceeds if the network request fails.
    }
  }
  if (typeof window !== 'undefined') window.localStorage.removeItem(ADMIN_SESSION_KEY)
}

export async function loadQuickSolutionCatalog() {
  return rpc('get_quick_solution_catalog', { p_tenant_slug: TENANT_SLUG })
}

export async function createQuickSolutionCartOrder({
  items,
  customerName,
  customerEmail,
  customerPhone,
  fulfilmentType,
  fulfilmentPointId,
  deliveryAddress,
  customerNotes,
  idempotencyKey
}) {
  return rpc('create_quick_solution_cart_order', {
    p_tenant_slug: TENANT_SLUG,
    p_items: (items || []).map((item) => ({
      clientItemKey: item.clientItemKey,
      productKey: item.productKey,
      configuration: item.configuration || {}
    })),
    p_customer_name: customerName,
    p_customer_email: customerEmail || null,
    p_customer_phone: customerPhone || null,
    p_fulfilment_type: fulfilmentType,
    p_fulfilment_point_id: fulfilmentPointId || null,
    p_delivery_address: deliveryAddress || null,
    p_customer_notes: customerNotes || null,
    p_idempotency_key: idempotencyKey
  })
}

export async function createQuickSolutionOrder({
  productKey,
  configuration,
  customerName,
  customerEmail,
  customerPhone,
  fulfilmentType,
  fulfilmentPointId,
  deliveryAddress,
  customerNotes,
  idempotencyKey
}) {
  return rpc('create_quick_solution_order', {
    p_tenant_slug: TENANT_SLUG,
    p_product_key: productKey,
    p_configuration: configuration,
    p_customer_name: customerName,
    p_customer_email: customerEmail || null,
    p_customer_phone: customerPhone || null,
    p_fulfilment_type: fulfilmentType,
    p_fulfilment_point_id: fulfilmentPointId || null,
    p_delivery_address: deliveryAddress || null,
    p_customer_notes: customerNotes || null,
    p_idempotency_key: idempotencyKey
  })
}

export async function createQuickSolutionServiceRequest({
  productKey,
  configuration,
  customerName,
  customerEmail,
  customerPhone,
  serviceLocation,
  customerNotes,
  idempotencyKey
}) {
  return rpc('create_quick_solution_service_request', {
    p_tenant_slug: TENANT_SLUG,
    p_product_key: productKey,
    p_configuration: configuration,
    p_customer_name: customerName,
    p_customer_email: customerEmail || null,
    p_customer_phone: customerPhone || null,
    p_service_location: serviceLocation || null,
    p_customer_notes: customerNotes || null,
    p_idempotency_key: idempotencyKey
  })
}

export async function uploadQuickSolutionFile({ orderId, orderItemId, uploadToken, file }) {
  if (!file) return null
  if (!orderId || !uploadToken) throw new Error('The order upload session is missing. Please create the order again.')

  const form = new FormData()
  form.append('order_id', orderId)
  if (orderItemId) form.append('order_item_id', orderItemId)
  form.append('upload_token', uploadToken)
  form.append('file', file, file.name)

  const response = await fetch(`${SUPABASE_URL}/functions/v1/quick-solution-upload`, {
    method: 'POST',
    headers: apiHeaders(null, null),
    body: form
  })

  return parseResponse(response, 'File upload failed')
}

// buildPricingDefinition lives in pricingDefinition.js (pure, so it can be
// tested; this module reads import.meta.env at load). Re-exported unchanged.
export { buildPricingDefinition }

function customerDefinitionFromProduct(product) {
  const copy = JSON.parse(JSON.stringify(product))
  delete copy.commerceProductId
  delete copy.pricingDefinition
  delete copy.pricingVersion
  return copy
}

export async function loadQuickSolutionAdminCatalog() {
  const accessToken = await getAdminAccessToken()
  return rpc('admin_get_quick_solution_catalog', { p_tenant_slug: TENANT_SLUG }, { accessToken })
}

// CAFE-GUEST-01L - the call contract for the server-side counter catalogue. Deliberately UNUSED
// until the Counter UI exists. It sends NO tenant: the server resolves the Cafe tenant itself
// and enforces the counter capability and the Cafe module, so nothing here (or in any
// front-end state) can widen access. The result is { tenant: { slug, name }, products: [...] }
// in the customer-safe product shape that src/lib/counterCatalogue.js reads.
export async function loadQuickSolutionCounterCatalog() {
  const accessToken = await getAdminAccessToken()
  return rpc('get_quick_solution_counter_catalog', {}, { accessToken })
}

// CAFE-GUEST-01P - today's counter orders, read-only. It sends NO argument: the server resolves the Cafe
// tenant, the counter channel and the business day itself and enforces the counter access, so nothing here
// can name a tenant, a channel, a creator or a date. The result is { businessDate, timezone, orders: [...] }.
export async function loadQuickSolutionCounterOrdersToday() {
  const accessToken = await getAdminAccessToken()
  return rpc('list_quick_solution_counter_orders_today', {}, { accessToken })
}

// CAFE-GUEST-01Q - one counter order, read fresh from the server: items, totals, amount paid, outstanding, and whether
// a payment may be recorded. The caller supplies only the order id; the tenant and the counter channel are the server's.
export async function loadQuickSolutionCounterOrder(orderId) {
  const accessToken = await getAdminAccessToken()
  return rpc('get_quick_solution_counter_order', { p_order_id: orderId }, { accessToken })
}

// CAFE-GUEST-01Q - record ONE full Cash or Card payment of a counter order. There is deliberately NO amount, status,
// tenant, actor or time argument: the server settles exactly what is outstanding, records who did it and when, and
// marks the order paid in the same transaction. The key is stable per payment attempt, so a retry returns the same payment.
export async function recordQuickSolutionCounterPayment({ orderId, method, idempotencyKey }) {
  const accessToken = await getAdminAccessToken()
  return rpc('record_quick_solution_counter_payment', { p_order_id: orderId, p_method: method, p_idempotency_key: idempotencyKey }, { accessToken })
}

// CAFE-GUEST-01U - the cash-up for a chosen Cafe business DATE, read-only. The only argument is the calendar date; the server works out
// the exact day (Africa/Johannesburg), refuses a future or invalid date, and returns the same shape as today's cash-up.
export async function loadQuickSolutionCounterCashup(businessDate) {
  const accessToken = await getAdminAccessToken()
  return rpc('get_quick_solution_counter_cashup', { p_business_date: businessDate }, { accessToken })
}

// CAFE-GUEST-01T - every counter order that still owes money, whichever day it was created, oldest first, read-only. It sends NO
// argument: the server resolves the tenant and the counter channel, decides what is still owed (from the completed ledger) and works
// out each order's age in Cafe business days.
export async function loadQuickSolutionUnpaidCounterOrders() {
  const accessToken = await getAdminAccessToken()
  return rpc('list_quick_solution_unpaid_counter_orders', {}, { accessToken })
}

// CAFE-GUEST-01S - today's cash-up, read-only: Cash and Card taken today, the payments that make it up, and the counter orders
// still unpaid. It sends NO argument: the server resolves the tenant, the counter channel and the business day itself, and the
// totals are made from the rows it returns.
export async function loadQuickSolutionCounterCashupToday() {
  const accessToken = await getAdminAccessToken()
  return rpc('get_quick_solution_counter_cashup_today', {}, { accessToken })
}

// CAFE-GUEST-01M - the call contract for creating ONE counter order. Called only by the Counter page
// (CAFE-GUEST-01O), once per confirmed sale attempt. The caller supplies only the idempotency key (stable per sale attempt, so a
// retry returns the original order), the product key, its configuration and optional customer
// details. There is no tenant, channel, actor, price or payment argument: the server decides the
// tenant, sets the channel and the creating staff member, prices the item itself, and creates the
// order unpaid. Authorization is enforced server-side; nothing here can widen it.
export async function createQuickSolutionCounterOrder({ idempotencyKey, productKey, configuration, customerName, customerEmail, customerPhone }) {
  const accessToken = await getAdminAccessToken()
  const body = {
    p_idempotency_key: idempotencyKey,
    p_product_key: productKey,
    p_configuration: configuration
  }
  if (customerName) body.p_customer_name = customerName
  if (customerEmail) body.p_customer_email = customerEmail
  if (customerPhone) body.p_customer_phone = customerPhone
  return rpc('create_quick_solution_counter_order', body, { accessToken })
}

export async function saveQuickSolutionProduct(product) {
  const accessToken = await getAdminAccessToken()
  return rpc('admin_update_quick_solution_product', {
    p_tenant_slug: TENANT_SLUG,
    p_product_key: product.id,
    p_customer_definition: customerDefinitionFromProduct(product),
    p_pricing_definition: buildPricingDefinition(product),
    p_expected_pricing_version: product.pricingVersion
  }, { accessToken })
}

export async function loadQuickSolutionOppsHandoffs() {
  const accessToken = await getAdminAccessToken()
  return rpc('admin_list_quick_solution_opps_handoffs', { p_tenant_slug: TENANT_SLUG }, { accessToken })
}

export async function previewQuickSolutionOppsHandoff(serviceOrderId) {
  const accessToken = await getAdminAccessToken()
  return rpc('admin_preview_quick_solution_opps_handoff', { p_service_order_id: serviceOrderId }, { accessToken })
}

export async function sendQuickSolutionOrderToOpps(serviceOrderId) {
  const accessToken = await getAdminAccessToken()
  return rpc('admin_send_quick_solution_order_to_opps', { p_service_order_id: serviceOrderId }, { accessToken })
}

export function buildOppsAppUrl(orderId = '', tenantSlug = TENANT_SLUG) {
  const params = new URLSearchParams()
  if (tenantSlug) params.set('tenant', tenantSlug)
  if (orderId) params.set('open', orderId)
  const query = params.toString()
  return `${OPPS_APP_URL}/Orders${query ? `?${query}` : ''}`
}


export async function loadQuickSolutionAdminFulfilmentPoints() {
  const accessToken = await getAdminAccessToken()
  return rpc('admin_get_quick_solution_fulfilment_points', { p_tenant_slug: TENANT_SLUG }, { accessToken })
}

export async function saveQuickSolutionFulfilmentPoint(point) {
  const accessToken = await getAdminAccessToken()
  return rpc('admin_upsert_quick_solution_fulfilment_point', {
    p_tenant_slug: TENANT_SLUG,
    p_point_id: point?.id || null,
    p_payload: {
      name: point?.name || '',
      kind: point?.kind || 'quick_point',
      status: point?.status || 'active',
      address: point?.address || {},
      contactPhone: point?.contactPhone || null,
      contactEmail: point?.contactEmail || null,
      latitude: point?.latitude === '' || point?.latitude == null ? null : Number(point.latitude),
      longitude: point?.longitude === '' || point?.longitude == null ? null : Number(point.longitude),
      collectionEnabled: point?.collectionEnabled !== false,
      dropoffEnabled: Boolean(point?.dropoffEnabled),
      services: Array.isArray(point?.services) ? point.services : [],
      feeAmount: Math.max(0, Number(point?.feeAmount || 0)),
      openingHours: point?.openingHours || {},
      sortOrder: Number(point?.sortOrder || 100)
    }
  }, { accessToken })
}


async function easyLocateConnectorRequest(body) {
  const accessToken = await getAdminAccessToken()
  if (!isSupabaseConfigured()) throw new Error('Supabase is not configured.')

  const response = await fetch(`${SUPABASE_URL}/functions/v1/quick-solution-easy-locate`, {
    method: 'POST',
    headers: {
      ...apiHeaders(accessToken),
      'Content-Type': 'application/json'
    },
    body: JSON.stringify(body || {})
  })

  return parseResponse(response, 'Easy Locate connector request failed')
}

export async function getEasyLocateConnectorStatus() {
  return easyLocateConnectorRequest({ action: 'status' })
}

export async function searchEasyLocateBusinesses(query) {
  return easyLocateConnectorRequest({ action: 'search', query: String(query || '').trim() })
}

export async function linkEasyLocateBusiness(fulfilmentPointId, businessSlug) {
  return easyLocateConnectorRequest({
    action: 'link',
    fulfilmentPointId,
    businessSlug
  })
}

export async function unlinkEasyLocateBusiness(fulfilmentPointId) {
  return easyLocateConnectorRequest({
    action: 'unlink',
    fulfilmentPointId
  })
}

async function quickSolutionPaymentRequest(body) {
  if (!isSupabaseConfigured()) throw new Error('Supabase is not configured.')

  const response = await fetch(`${SUPABASE_URL}/functions/v1/quick-solution-payfast`, {
    method: 'POST',
    headers: apiHeaders(null),
    body: JSON.stringify(body || {})
  })

  return parseResponse(response, 'Quick Solution payment request failed')
}

export async function beginQuickSolutionPayment(orderId, paymentToken) {
  return quickSolutionPaymentRequest({
    action: 'init',
    order_id: orderId,
    payment_token: paymentToken
  })
}

export async function getQuickSolutionPaymentStatus(orderId, paymentToken) {
  return quickSolutionPaymentRequest({
    action: 'status',
    order_id: orderId,
    payment_token: paymentToken
  })
}


export async function getQuickSolutionTracking({ orderNumber, trackingToken = null, contact = null }) {
  return rpc('get_quick_solution_tracking', {
    p_order_number: String(orderNumber || '').trim(),
    p_tracking_token: trackingToken || null,
    p_contact: contact || null
  })
}

export async function adminIssueQuickSolutionTrackingToken(serviceOrderId) {
  const accessToken = await getAdminAccessToken()
  return rpc('admin_issue_quick_solution_tracking_token', {
    p_service_order_id: serviceOrderId
  }, { accessToken })
}
