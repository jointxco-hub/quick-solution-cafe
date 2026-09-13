import { createClient } from 'https://esm.sh/@supabase/supabase-js@2.57.4'
import md5 from 'https://esm.sh/js-md5@0.8.3'

const cors = {
  'Access-Control-Allow-Origin': '*',
  'Access-Control-Allow-Headers': 'authorization, x-client-info, apikey, content-type',
  'Access-Control-Allow-Methods': 'POST, OPTIONS'
}

function json(body: unknown, status = 200) {
  return new Response(JSON.stringify(body), {
    status,
    headers: { ...cors, 'Content-Type': 'application/json' }
  })
}

function signAndBuildUrl(fields: Record<string, string>, passphrase: string, isSandbox: boolean) {
  const encode = (value: string) => encodeURIComponent(value.trim()).replace(/%20/g, '+')
  const cleanFields = Object.fromEntries(
    Object.entries(fields).filter(([, value]) => value !== '' && value !== null && value !== undefined)
  )
  const paramString = Object.keys(cleanFields)
    .map((key) => `${key}=${encode(cleanFields[key])}`)
    .join('&')
  const signatureSource = passphrase
    ? `${paramString}&passphrase=${encode(passphrase)}`
    : paramString
  const signature = md5(signatureSource) as string
  const host = isSandbox
    ? 'https://sandbox.payfast.co.za/eng/process'
    : 'https://www.payfast.co.za/eng/process'
  return `${host}?${paramString}&signature=${encode(signature)}`
}

function safeOrigin(req: Request) {
  const origin = String(req.headers.get('origin') || Deno.env.get('QUICK_SOLUTION_RETURN_ORIGIN') || '').replace(/\/$/, '')
  if (!origin) return null
  try {
    const url = new URL(origin)
    if (url.protocol === 'https:') return origin
    if (url.protocol === 'http:' && ['localhost', '127.0.0.1'].includes(url.hostname)) return origin
  } catch {
    return null
  }
  return null
}

Deno.serve(async (req: Request) => {
  if (req.method === 'OPTIONS') return new Response('ok', { headers: cors })
  if (req.method !== 'POST') return json({ error: 'Method not allowed.' }, 405)

  const supabaseUrl = Deno.env.get('SUPABASE_URL') || ''
  const serviceRoleKey = Deno.env.get('SUPABASE_SERVICE_ROLE_KEY') || ''
  const merchantId = Deno.env.get('PAYFAST_MERCHANT_ID') || ''
  const merchantKey = Deno.env.get('PAYFAST_MERCHANT_KEY') || ''
  const passphrase = Deno.env.get('PAYFAST_PASSPHRASE') || ''
  const notifyUrl = Deno.env.get('PAYFAST_NOTIFY_URL') || ''
  const isSandbox = (Deno.env.get('PAYFAST_SANDBOX') || 'true') === 'true'

  if (!supabaseUrl || !serviceRoleKey) return json({ error: 'Quick Solution payment backend is not configured.' }, 500)

  try {
    const body = await req.json().catch(() => ({}))
    const action = String(body?.action || 'init').trim()
    const orderId = String(body?.order_id || '').trim()
    const paymentToken = String(body?.payment_token || '').trim()

    if (!orderId || !paymentToken) return json({ error: 'Payment session is missing.' }, 400)

    const supabase = createClient(supabaseUrl, serviceRoleKey, {
      auth: { persistSession: false, autoRefreshToken: false }
    })

    if (action === 'status') {
      const { data, error } = await supabase.rpc('qs_get_quick_solution_payment_status', {
        p_order_id: orderId,
        p_payment_token: paymentToken
      })
      if (error || !data?.ok) return json({ error: 'Payment status is not available.' }, 404)
      return json(data)
    }

    if (!merchantId || !merchantKey || !notifyUrl) {
      return json({ error: 'PayFast is not configured for Quick Solution yet.' }, 503)
    }

    const { data: intent, error: intentError } = await supabase.rpc('qs_begin_quick_solution_payment', {
      p_order_id: orderId,
      p_payment_token: paymentToken
    })

    if (intentError || !intent?.ok) {
      if (intent?.reason === 'delivery_fee_pending') return json({ error: 'Delivery pricing must be confirmed before payment.' }, 409)
      return json({ error: 'This order is not available for payment right now.' }, 404)
    }
    if (intent.alreadyPaid) return json({ ok: true, alreadyPaid: true, paymentStatus: 'paid' })

    const amount = Number(intent.amount)
    if (!amount || amount <= 0) return json({ error: 'Order amount is not payable.' }, 400)

    const origin = safeOrigin(req)
    if (!origin) return json({ error: 'Quick Solution return URL is not configured for this storefront.' }, 503)

    const nameParts = String(intent.customerName || '').split(' ')
    const returnUrl = `${origin}/?qs_payment=return&order=${encodeURIComponent(intent.orderId)}`
    const cancelUrl = `${origin}/?qs_payment=cancel&order=${encodeURIComponent(intent.orderId)}`

    const fields: Record<string, string> = {
      merchant_id: merchantId,
      merchant_key: merchantKey,
      return_url: returnUrl,
      cancel_url: cancelUrl,
      notify_url: notifyUrl,
      name_first: nameParts[0] || 'Customer',
      name_last: nameParts.slice(1).join(' ') || '',
      email_address: intent.customerEmail || '',
      m_payment_id: intent.orderNumber || intent.orderId,
      amount: amount.toFixed(2),
      item_name: `Quick Solution ${intent.orderNumber || intent.orderId}`,
      custom_str1: intent.orderId,
      custom_str2: 'quick_solution'
    }

    const paymentUrl = signAndBuildUrl(fields, passphrase, isSandbox)
    return json({
      ok: true,
      payment_url: paymentUrl,
      redirect: true,
      sandbox: isSandbox,
      orderNumber: intent.orderNumber,
      amount
    })
  } catch (error) {
    console.error('[quick-solution-payfast]', error)
    return json({ error: error instanceof Error ? error.message : 'Unexpected payment error.' }, 500)
  }
})
