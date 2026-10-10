import webpush from 'npm:web-push@3.6.7'

const url = Deno.env.get('SUPABASE_URL')!
const serviceKey = Deno.env.get('SUPABASE_SERVICE_ROLE_KEY')!
const anonKey = Deno.env.get('SUPABASE_ANON_KEY')!
const cors = { 'Access-Control-Allow-Origin': '*', 'Access-Control-Allow-Headers': 'authorization, apikey, content-type', 'Access-Control-Allow-Methods': 'POST, OPTIONS' }
const reply = (data: unknown, status = 200) => Response.json(data, { status, headers: cors })
async function rpc(name: string, body: unknown, token = serviceKey) {
 const response = await fetch(`${url}/rest/v1/rpc/${name}`, { method: 'POST', headers: { apikey: token === serviceKey ? serviceKey : anonKey, Authorization: `Bearer ${token}`, 'Content-Type': 'application/json' }, body: JSON.stringify(body) })
 const data = await response.json()
 if (!response.ok) throw Object.assign(new Error(data.message || 'Notification request failed.'), { status: response.status })
 return data
}
async function send(row: any, config: any) {
 try {
  await webpush.sendNotification(row.subscription, JSON.stringify(row.payload), { TTL: 3600, timeout: 10000, vapidDetails: { subject: config.subject, publicKey: config.publicKey, privateKey: config.privateKey } })
  if (row.id) await rpc('qs_push_finish', { p_id: row.id, p_expired: false })
  return true
 } catch (error: any) {
  if (row.id && [404,410].includes(error.statusCode)) await rpc('qs_push_finish', { p_id: row.id, p_expired: true })
  // No endpoints, keys or customer data in logs. Other failures remain queued for retry.
  console.error('Café push delivery failed', error.statusCode || 'transport')
  return false
 }
}
Deno.serve(async (request) => {
 if (request.method === 'OPTIONS') return new Response(null, { headers: cors })
 if (request.method !== 'POST') return reply({ error: 'Use POST.' }, 405)
 try {
  if (Number(request.headers.get('content-length') || 0) > 8192) return reply({ error: 'Request too large.' }, 413)
  const raw = await request.text()
  if (raw.length > 8192) return reply({ error: 'Request too large.' }, 413)
  const body = JSON.parse(raw)
  if (body.action === 'dispatch') {
   const secret = request.headers.get('x-qs-dispatch')
   if (!secret) return reply({ error: 'Unauthorized.' }, 401)
   const config = await rpc('qs_push_server_config', {})
   // Constant-time compare with a digest; only the Vault-backed scheduler may dispatch.
   const digest = async (value: string) => new Uint8Array(await crypto.subtle.digest('SHA-256', new TextEncoder().encode(value)))
   const a = await digest(secret), b = await digest(config.dispatchSecret || '')
   let different = 0; for (let i=0;i<a.length;i++) different |= a[i]^b[i]
   if (different || !config.dispatchSecret) return reply({ error: 'Unauthorized.' }, 401)
   const rows = await rpc('qs_push_claim', {})
   let sent = 0
   for (let i=0;i<rows.length;i+=5) {
    const results = await Promise.all(rows.slice(i,i+5).map((row: any) => send(row,config)))
    sent += results.filter(Boolean).length
   }
   return reply({ claimed: rows.length, sent })
  }
  const token = request.headers.get('authorization')?.replace(/^Bearer\s+/i,'')
  if (!token || token === serviceKey || token === anonKey) return reply({ error: 'Staff sign-in is required.' }, 401)
  const authResponse = await fetch(`${url}/auth/v1/user`, { headers: { apikey: anonKey, Authorization: `Bearer ${token}` } })
  if (!authResponse.ok) return reply({ error: 'Staff sign-in is required.' }, 401)
  const result = await rpc('qs_staff_push', { p_action: body.action, p_app: body.app, p_subscription: body.subscription || null, p_endpoint: body.endpoint || null }, token)
  return reply(result)
 } catch (error: any) { return reply({ error: error.message || 'Notification request failed.' }, error.status || 400) }
})
