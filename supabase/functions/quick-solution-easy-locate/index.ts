import { createClient } from 'https://esm.sh/@supabase/supabase-js@2.57.4'

const corsHeaders = {
  'Access-Control-Allow-Origin': '*',
  'Access-Control-Allow-Headers': 'authorization, x-client-info, apikey, content-type',
  'Access-Control-Allow-Methods': 'POST, OPTIONS'
}

function json(body: unknown, status = 200) {
  return new Response(JSON.stringify(body), { status, headers: { ...corsHeaders, 'Content-Type': 'application/json' } })
}

function clean(value: unknown, max = 500) {
  const text = String(value ?? '').trim()
  return text ? text.slice(0, max) : null
}

function stringArray(value: unknown, max = 20) {
  if (!Array.isArray(value)) return []
  return value.map((item) => clean(item, 120)).filter(Boolean).slice(0, max)
}

function firstValue(row: Record<string, unknown>, keys: string[]) {
  for (const key of keys) {
    const value = row?.[key]
    if (value !== undefined && value !== null && String(value).trim() !== '') return value
  }
  return null
}

function normalizeBusiness(raw: unknown, siteUrl: string) {
  if (!raw || typeof raw !== 'object') return null
  const row = raw as Record<string, unknown>
  const id = clean(firstValue(row, ['id', 'business_id', 'businessId']), 240)
  const slug = clean(firstValue(row, ['slug', 'business_slug', 'businessSlug']), 240)
  const name = clean(firstValue(row, ['name', 'business_name', 'businessName']), 240)
  if (!slug || !name) return null

  const categories = stringArray(firstValue(row, ['categories', 'category_list']))
  const category = clean(firstValue(row, ['category', 'primary_category']), 120)
  if (category && !categories.includes(category)) categories.unshift(category)

  return {
    id: id || slug,
    slug,
    name,
    description: clean(firstValue(row, ['description', 'summary']), 700),
    categories,
    services: stringArray(firstValue(row, ['services', 'service_list'])),
    locationArea: clean(firstValue(row, ['location_area', 'area', 'locationArea']), 180),
    locationExtension: clean(firstValue(row, ['location_extension', 'extension', 'locationExtension']), 180),
    verificationLevel: clean(firstValue(row, ['verification_level', 'verificationLevel']), 80),
    phone: clean(firstValue(row, ['phone']), 80),
    whatsapp: clean(firstValue(row, ['whatsapp', 'whatsapp_number', 'whatsappNumber']), 80),
    website: clean(firstValue(row, ['website']), 500),
    openingHours: firstValue(row, ['opening_hours', 'openingHours']) ?? null,
    claimed: firstValue(row, ['claimed']) === true || String(firstValue(row, ['claimed'])).toLowerCase() === 'true',
    updatedAt: clean(firstValue(row, ['updated_at', 'updatedAt', 'published_at', 'publishedAt']), 80),
    canonicalUrl: `${siteUrl}/businesses/${encodeURIComponent(slug)}`
  }
}

function unwrapRows(payload: unknown) {
  if (Array.isArray(payload)) return payload
  if (!payload || typeof payload !== 'object') return []
  const row = payload as Record<string, unknown>
  for (const key of ['businesses', 'results', 'items', 'data']) {
    if (Array.isArray(row[key])) return row[key] as unknown[]
  }
  return [payload]
}

async function easyRpc(baseUrl: string, key: string, functionName: string, payloadCandidates: Record<string, unknown>[]) {
  let lastError = 'Easy Locate request failed.'
  for (const payload of payloadCandidates) {
    const response = await fetch(`${baseUrl}/rest/v1/rpc/${functionName}`, {
      method: 'POST',
      headers: { apikey: key, Authorization: `Bearer ${key}`, 'Content-Type': 'application/json' },
      body: JSON.stringify(payload)
    })
    const text = await response.text()
    let parsed: unknown = null
    try { parsed = text ? JSON.parse(text) : null } catch { parsed = text }
    if (response.ok) return parsed

    const errorObject = parsed && typeof parsed === 'object' ? parsed as Record<string, unknown> : {}
    const code = String(errorObject.code || '')
    const message = String(errorObject.message || text || `HTTP ${response.status}`)
    lastError = message
    if (['PGRST202', 'PGRST203'].includes(code) || /function .* does not exist|could not find the function|schema cache/i.test(message)) continue
    throw new Error(message)
  }
  throw new Error(lastError)
}

async function listBusinesses(baseUrl: string, key: string, query: string, siteUrl: string) {
  const payload = await easyRpc(baseUrl, key, 'list_public_businesses', [
    { p_query: query, p_limit: 25 }, { p_search: query, p_limit: 25 }, { p_query: query }, {}
  ])
  const normalized = unwrapRows(payload).map((row) => normalizeBusiness(row, siteUrl)).filter(Boolean) as ReturnType<typeof normalizeBusiness>[]
  const q = query.toLowerCase().trim()
  if (!q) return normalized.slice(0, 25)
  return normalized.filter((business) => [business?.name, business?.slug, business?.description, business?.locationArea, business?.locationExtension, ...(business?.categories || []), ...(business?.services || [])].filter(Boolean).join(' ').toLowerCase().includes(q)).slice(0, 25)
}

async function getBusinessBySlug(baseUrl: string, key: string, slug: string, siteUrl: string) {
  try {
    const payload = await easyRpc(baseUrl, key, 'get_public_business_by_slug', [{ p_slug: slug }, { slug }])
    const business = unwrapRows(payload).map((row) => normalizeBusiness(row, siteUrl)).find((item) => item?.slug === slug)
    if (business) return business
  } catch (error) {
    console.warn('Easy Locate exact business RPC fallback', error)
  }
  const candidates = await listBusinesses(baseUrl, key, slug, siteUrl)
  return candidates.find((item) => item?.slug === slug) || null
}

Deno.serve(async (req: Request) => {
  if (req.method === 'OPTIONS') return new Response('ok', { headers: corsHeaders })
  if (req.method !== 'POST') return json({ error: 'Method not allowed.' }, 405)

  const supabaseUrl = Deno.env.get('SUPABASE_URL')
  const anonKey = Deno.env.get('SUPABASE_ANON_KEY')
  const serviceRoleKey = Deno.env.get('SUPABASE_SERVICE_ROLE_KEY')
  if (!supabaseUrl || !anonKey || !serviceRoleKey) return json({ error: 'Quick Solution backend is not configured.' }, 500)

  const accessToken = (req.headers.get('authorization') || '').replace(/^Bearer\s+/i, '').trim()
  if (!accessToken) return json({ error: 'Staff sign-in is required.' }, 401)

  try {
    const userClient = createClient(supabaseUrl, anonKey, {
      auth: { persistSession: false, autoRefreshToken: false },
      global: { headers: { Authorization: `Bearer ${accessToken}` } }
    })
    const { data: pointData, error: pointError } = await userClient.rpc('admin_get_quick_solution_fulfilment_points', { p_tenant_slug: 'quick-solution' })
    if (pointError || !pointData?.tenantId) return json({ error: pointError?.message || 'You do not have Quick Solution admin access.' }, 403)

    const body = await req.json().catch(() => ({}))
    const action = clean(body?.action, 40) || 'status'
    const easyBaseUrl = String(Deno.env.get('EASY_LOCATE_SUPABASE_URL') || 'https://ngvlalawiiziisznjdwm.supabase.co').replace(/\/$/, '')
    const easyKey = String(Deno.env.get('EASY_LOCATE_PUBLISHABLE_KEY') || Deno.env.get('EASY_LOCATE_ANON_KEY') || '').trim()
    const easySiteUrl = String(Deno.env.get('EASY_LOCATE_SITE_URL') || 'https://easy-locate.vercel.app').replace(/\/$/, '')

    if (action === 'status') return json({ ok: true, configured: Boolean(easyKey), provider: 'easy_locate', siteUrl: easySiteUrl, message: easyKey ? 'Easy Locate connector is ready.' : 'Easy Locate connector needs its publishable key.' })
    if (!easyKey) return json({ ok: false, code: 'EASY_LOCATE_CONFIGURATION_REQUIRED', configured: false, error: 'Easy Locate connector needs its publishable key before live business search can run.' }, 503)

    if (action === 'search') {
      const query = clean(body?.query, 120) || ''
      if (query.length < 2) return json({ ok: true, configured: true, businesses: [] })
      return json({ ok: true, configured: true, businesses: await listBusinesses(easyBaseUrl, easyKey, query, easySiteUrl) })
    }

    const pointId = clean(body?.fulfilmentPointId, 80)
    const point = Array.isArray(pointData?.points) ? pointData.points.find((item: Record<string, unknown>) => String(item.id) === pointId) : null
    if (!pointId || !point) return json({ error: 'Quick Point was not found.' }, 404)

    const admin = createClient(supabaseUrl, serviceRoleKey, { auth: { persistSession: false, autoRefreshToken: false } })
    const { data: userResult } = await admin.auth.getUser(accessToken)
    const verifiedBy = userResult?.user?.id || null

    if (action === 'link') {
      const slug = clean(body?.businessSlug, 240)
      if (!slug) return json({ error: 'Choose an Easy Locate business.' }, 400)
      const business = await getBusinessBySlug(easyBaseUrl, easyKey, slug, easySiteUrl)
      if (!business) return json({ error: 'That Easy Locate business is no longer publicly available.' }, 404)

      const publicSnapshot = { id: business.id, slug: business.slug, name: business.name, description: business.description, categories: business.categories, services: business.services, locationArea: business.locationArea, locationExtension: business.locationExtension, verificationLevel: business.verificationLevel, claimed: business.claimed }
      const { data: linked, error: linkError } = await admin.rpc('qs_internal_apply_verified_external_link', {
        p_tenant_id: pointData.tenantId,
        p_fulfilment_point_id: pointId,
        p_provider: 'easy_locate',
        p_external_id: business.id,
        p_external_slug: business.slug,
        p_canonical_url: business.canonicalUrl,
        p_public_snapshot: publicSnapshot,
        p_source_updated_at: business.updatedAt || null,
        p_verified_by: verifiedBy
      })
      if (linkError) {
        const duplicate = String(linkError.message || '').toLowerCase().includes('unique')
        return json({ error: duplicate ? 'This Easy Locate business is already linked to another Quick Point.' : linkError.message }, duplicate ? 409 : 500)
      }
      return json({ ok: true, configured: true, business, link: linked?.link })
    }

    if (action === 'unlink') {
      const { data: unlinked, error: unlinkError } = await admin.rpc('qs_internal_unlink_external_link', { p_tenant_id: pointData.tenantId, p_fulfilment_point_id: pointId, p_provider: 'easy_locate' })
      if (unlinkError) return json({ error: unlinkError.message }, 500)
      return json({ ok: true, configured: true, ...unlinked })
    }

    return json({ error: 'Unsupported connector action.' }, 400)
  } catch (error) {
    console.error('quick-solution-easy-locate error', error)
    return json({ error: error instanceof Error ? error.message : 'Unexpected Easy Locate connector error.' }, 500)
  }
})
