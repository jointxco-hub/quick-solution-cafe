const SUPABASE_URL = String(import.meta.env.VITE_SUPABASE_URL || '').replace(/\/$/, '')
const SUPABASE_KEY = String(import.meta.env.VITE_SUPABASE_PUBLISHABLE_KEY || import.meta.env.VITE_SUPABASE_ANON_KEY || '')
const TENANT_SLUG = String(import.meta.env.VITE_QS_TENANT_SLUG || 'quick-solution')

export function isSupabaseConfigured() {
  return Boolean(SUPABASE_URL && SUPABASE_KEY)
}

async function rpc(functionName, body) {
  if (!isSupabaseConfigured()) {
    throw new Error('Supabase is not configured. Add VITE_SUPABASE_URL and VITE_SUPABASE_PUBLISHABLE_KEY to .env.local.')
  }

  const headers = {
    apikey: SUPABASE_KEY,
    'Content-Type': 'application/json'
  }

  // Legacy anon JWT keys can also be used as bearer tokens. Modern sb_publishable_ keys
  // should stay in the apikey header.
  if (SUPABASE_KEY.startsWith('eyJ')) {
    headers.Authorization = `Bearer ${SUPABASE_KEY}`
  }

  const response = await fetch(`${SUPABASE_URL}/rest/v1/rpc/${functionName}`, {
    method: 'POST',
    headers,
    body: JSON.stringify(body)
  })

  let payload = null
  try {
    payload = await response.json()
  } catch {
    payload = null
  }

  if (!response.ok) {
    const message = payload?.message || payload?.hint || `Quick Solution backend request failed (${response.status}).`
    throw new Error(message)
  }

  return payload
}

export async function loadQuickSolutionCatalog() {
  return rpc('get_quick_solution_catalog', {
    p_tenant_slug: TENANT_SLUG
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
