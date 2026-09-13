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

function optionMap(product, fieldId, valueKey) {
  const field = product.fields?.find((item) => item.id === fieldId)
  return Object.fromEntries((field?.options || []).map((option) => [option.id, { [valueKey]: Number(option[valueKey] || 0) }]))
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
  throw new Error(`Unsupported pricing strategy: ${strategy || 'unknown'}`)
}

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

export function buildOppsAppUrl(orderId = '') {
  return orderId ? `${OPPS_APP_URL}?orderId=${encodeURIComponent(orderId)}` : OPPS_APP_URL
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
      easyLocateBusinessRef: point?.easyLocateBusinessRef || null,
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
