import { createClient } from 'https://esm.sh/@supabase/supabase-js@2.57.4'

const corsHeaders = {
  'Access-Control-Allow-Origin': '*',
  'Access-Control-Allow-Headers': 'authorization, x-client-info, apikey, content-type',
  'Access-Control-Allow-Methods': 'POST, OPTIONS'
}

const MAX_BYTES = 20 * 1024 * 1024
const allowedMime = new Set([
  'application/pdf',
  'application/vnd.openxmlformats-officedocument.wordprocessingml.document',
  'image/png',
  'image/jpeg',
  'image/webp'
])

const extMime: Record<string, string> = {
  pdf: 'application/pdf',
  docx: 'application/vnd.openxmlformats-officedocument.wordprocessingml.document',
  png: 'image/png',
  jpg: 'image/jpeg',
  jpeg: 'image/jpeg',
  webp: 'image/webp'
}

function json(body: unknown, status = 200) {
  return new Response(JSON.stringify(body), {
    status,
    headers: { ...corsHeaders, 'Content-Type': 'application/json' }
  })
}

function safeFilename(name: string) {
  const cleaned = name
    .normalize('NFKC')
    .replace(/[\\/\u0000-\u001f\u007f]/g, '-')
    .replace(/\s+/g, '-')
    .replace(/[^a-zA-Z0-9._-]/g, '-')
    .replace(/-+/g, '-')
    .replace(/^[-.]+|[-.]+$/g, '')
  return (cleaned || 'upload').slice(-120)
}

function resolvedMime(file: File) {
  const declared = String(file.type || '').toLowerCase().trim()
  if (allowedMime.has(declared)) return declared
  const ext = file.name.split('.').pop()?.toLowerCase() || ''
  return extMime[ext] || declared
}

Deno.serve(async (req: Request) => {
  if (req.method === 'OPTIONS') return new Response('ok', { headers: corsHeaders })
  if (req.method !== 'POST') return json({ error: 'Method not allowed.' }, 405)

  const contentLength = Number(req.headers.get('content-length') || 0)
  if (contentLength > MAX_BYTES + 1024 * 1024) {
    return json({ error: 'File is larger than the 20MB limit.' }, 413)
  }

  const supabaseUrl = Deno.env.get('SUPABASE_URL')
  const serviceRoleKey = Deno.env.get('SUPABASE_SERVICE_ROLE_KEY')
  if (!supabaseUrl || !serviceRoleKey) return json({ error: 'Upload service is not configured.' }, 500)

  try {
    const form = await req.formData()
    const orderId = String(form.get('order_id') || '').trim()
    const orderItemId = String(form.get('order_item_id') || '').trim() || null
    const uploadToken = String(form.get('upload_token') || '').trim()
    const fileValue = form.get('file')

    if (!orderId || !uploadToken || !(fileValue instanceof File)) {
      return json({ error: 'Order, upload token and file are required.' }, 400)
    }

    const file = fileValue
    if (file.size <= 0 || file.size > MAX_BYTES) {
      return json({ error: 'File must be between 1 byte and 20MB.' }, 400)
    }

    const mimeType = resolvedMime(file)
    if (!allowedMime.has(mimeType)) {
      return json({ error: 'Use PDF, DOCX, PNG, JPG or WEBP files.' }, 415)
    }

    const admin = createClient(supabaseUrl, serviceRoleKey, {
      auth: { persistSession: false, autoRefreshToken: false }
    })

    const { data: authData, error: authError } = await admin.rpc('qs_authorize_file_upload', {
      p_order_id: orderId,
      p_upload_token: uploadToken,
      p_order_item_id: orderItemId
    })

    if (authError || !authData?.ok) {
      return json({ error: authError?.message || 'Upload authorization failed.' }, 403)
    }

    const tenantId = String(authData.tenantId)
    const resolvedItemId = String(authData.orderItemId)
    const safe = safeFilename(file.name)
    const objectPath = `${tenantId}/quick-solution/orders/${orderId}/${resolvedItemId}/${crypto.randomUUID()}-${safe}`

    const bytes = new Uint8Array(await file.arrayBuffer())
    const { error: uploadError } = await admin.storage
      .from('uploads')
      .upload(objectPath, bytes, { contentType: mimeType, upsert: false })

    if (uploadError) return json({ error: `Private upload failed: ${uploadError.message}` }, 500)

    const { data: registered, error: registerError } = await admin.rpc('qs_register_file_upload', {
      p_order_id: orderId,
      p_order_item_id: resolvedItemId,
      p_upload_token: uploadToken,
      p_storage_path: objectPath,
      p_original_filename: file.name,
      p_mime_type: mimeType,
      p_byte_size: file.size
    })

    if (registerError || !registered?.ok) {
      await admin.storage.from('uploads').remove([objectPath])
      return json({ error: registerError?.message || 'File could not be linked to the order.' }, 500)
    }

    return json({
      ok: true,
      orderId,
      orderItemId: resolvedItemId,
      orderNumber: authData.orderNumber,
      file: registered.file
    })
  } catch (error) {
    console.error('quick-solution-upload error', error)
    return json({ error: error instanceof Error ? error.message : 'Unexpected upload error.' }, 500)
  }
})
