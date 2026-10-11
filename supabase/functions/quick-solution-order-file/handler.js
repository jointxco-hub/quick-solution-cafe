const cors = { 'Access-Control-Allow-Origin': '*', 'Access-Control-Allow-Headers': 'authorization, apikey, content-type', 'Access-Control-Allow-Methods': 'POST, OPTIONS', 'Cache-Control': 'no-store' }
const uuid = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i
const inlineTypes = new Set(['application/pdf', 'image/png', 'image/jpeg', 'image/webp'])
export function createFileHandler({ url, anonKey, serviceKey, fetcher = fetch }) {
  const reply = (body, status = 200) => Response.json(body, { status, headers: cors })
  return async (request) => {
    if (request.method === 'OPTIONS') return new Response(null, { headers: cors })
    if (request.method !== 'POST') return reply({ error: 'Use POST.' }, 405)
    try {
      const token = request.headers.get('authorization')?.replace(/^Bearer\s+/i, '')
      if (!token || token === anonKey || token === serviceKey) return reply({ error: 'Staff sign-in is required.' }, 401)
      const auth = await fetcher(`${url}/auth/v1/user`, { headers: { apikey: anonKey, Authorization: `Bearer ${token}` } })
      if (!auth.ok) return reply({ error: 'Staff sign-in is required.' }, 401)
      const raw = await request.text()
      if (raw.length > 2048) return reply({ error: 'Request too large.' }, 413)
      const body = JSON.parse(raw)
      if (!uuid.test(body.orderId) || !uuid.test(body.fileId) || !['open', 'download'].includes(body.mode)) return reply({ error: 'Invalid file request.' }, 400)
      // This RPC uses the caller JWT, not the privileged signer, to enforce tenant access.
      const lookup = await fetcher(`${url}/rest/v1/rpc/qs_staff_order_file`, { method: 'POST', headers: { apikey: anonKey, Authorization: `Bearer ${token}`, 'Content-Type': 'application/json' }, body: JSON.stringify({ p_order_id: body.orderId, p_file_id: body.fileId }) })
      if (!lookup.ok) return reply({ error: 'File unavailable or access denied.' }, 403)
      const file = await lookup.json()
      if (file.bucket !== 'uploads' || typeof file.path !== 'string' || file.path.split('/').some(p => !p || p === '.' || p === '..')) return reply({ error: 'File unavailable.' }, 404)
      const path = file.path.split('/').map(encodeURIComponent).join('/')
      const signed = await fetcher(`${url}/storage/v1/object/sign/uploads/${path}`, { method: 'POST', headers: { apikey: serviceKey, Authorization: `Bearer ${serviceKey}`, 'Content-Type': 'application/json' }, body: JSON.stringify({ expiresIn: 120 }) })
      if (!signed.ok) return reply({ error: 'Could not open the file. Please try again.' }, 502)
      const data = await signed.json()
      const link = new URL(`${url}/storage/v1${data.signedURL}`)
      if (!data.signedURL?.startsWith('/object/sign/')) return reply({ error: 'File unavailable.' }, 502)
      if (body.mode === 'download' || !inlineTypes.has(file.mime)) link.searchParams.set('download', file.name || 'document')
      return reply({ url: link.href, expiresIn: 120 })
    } catch { return reply({ error: 'Could not open the file. Please try again.' }, 400) }
  }
}
