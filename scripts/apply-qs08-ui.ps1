$ErrorActionPreference = "Stop"

$root = Split-Path -Parent $PSScriptRoot
$guidedPath = Join-Path $root "src\components\GuidedOrder.jsx"
$apiPath = Join-Path $root "src\lib\supabaseApi.js"
$adminPath = Join-Path $root "src\admin\AdminOppsHandoffPanel.jsx"
$mainPath = Join-Path $root "src\main.jsx"

function Replace-Exact {
  param([string]$Path,[string]$Old,[string]$New,[string]$Label)
  $text = Get-Content -Raw -LiteralPath $Path
  if ($text.Contains($New)) {
    Write-Host "Already applied: $Label"
    return
  }
  if (-not $text.Contains($Old)) {
    throw "Could not find expected anchor for: $Label`nFile: $Path"
  }
  $text = $text.Replace($Old,$New)
  Set-Content -LiteralPath $Path -Value $text -Encoding UTF8
  Write-Host "Applied: $Label"
}

# 1) Payment API helpers.
$api = Get-Content -Raw -LiteralPath $apiPath
if (-not $api.Contains("beginQuickSolutionPayment")) {
$apiAppend = @'

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
'@
  Add-Content -LiteralPath $apiPath -Value $apiAppend -Encoding UTF8
  Write-Host "Applied: payment API helpers"
} else {
  Write-Host "Already applied: payment API helpers"
}

# 2) GuidedOrder import.
Replace-Exact $guidedPath `
"import { createQuickSolutionOrder, isSupabaseConfigured, uploadQuickSolutionFile } from '../lib/supabaseApi.js'" `
"import { beginQuickSolutionPayment, createQuickSolutionOrder, getQuickSolutionPaymentStatus, isSupabaseConfigured, uploadQuickSolutionFile } from '../lib/supabaseApi.js'" `
"GuidedOrder payment imports"

# 3) Payment state.
Replace-Exact $guidedPath `
"  const [uploadError, setUploadError] = useState('')" `
"  const [uploadError, setUploadError] = useState('')`n  const [paymentState, setPaymentState] = useState('idle')`n  const [paymentError, setPaymentError] = useState('')" `
"GuidedOrder payment state"

# 4) Reset state when product/journey changes.
Replace-Exact $guidedPath `
"    setUploadedFile(null)`n    setUploadError('')`n  }, [product, journey, preset])" `
"    setUploadedFile(null)`n    setUploadError('')`n    setPaymentState('idle')`n    setPaymentError('')`n  }, [product, journey, preset])" `
"GuidedOrder product reset"

# 5) Reset state when starting another order.
Replace-Exact $guidedPath `
"    setUploadedFile(null)`n    setUploadError('')`n    setIdempotencyKey(makeIdempotencyKey())" `
"    setUploadedFile(null)`n    setUploadError('')`n    setPaymentState('idle')`n    setPaymentError('')`n    setIdempotencyKey(makeIdempotencyKey())" `
"GuidedOrder new-order reset"

# 6) Add payment actions before complete rendering.
$paymentActions = @'
  const startPayment = async () => {
    if (!orderResponse?.orderId || !orderResponse?.paymentToken) {
      setPaymentError('This order does not have an active payment session yet.')
      return
    }

    setPaymentState('starting')
    setPaymentError('')
    try {
      const result = await beginQuickSolutionPayment(orderResponse.orderId, orderResponse.paymentToken)
      if (result?.alreadyPaid || result?.paymentStatus === 'paid') {
        setPaymentState('paid')
        return
      }
      if (!result?.payment_url) throw new Error('PayFast did not return a payment link.')
      window.open(result.payment_url, '_blank', 'noopener,noreferrer')
      setPaymentState('waiting')
    } catch (error) {
      setPaymentState('error')
      setPaymentError(error?.message || 'Could not open PayFast.')
    }
  }

  const checkPayment = async () => {
    if (!orderResponse?.orderId || !orderResponse?.paymentToken) return
    setPaymentState('checking')
    setPaymentError('')
    try {
      const result = await getQuickSolutionPaymentStatus(orderResponse.orderId, orderResponse.paymentToken)
      setPaymentState(result?.paid ? 'paid' : 'waiting')
      if (!result?.paid) setPaymentError('PayFast has not confirmed this payment yet.')
    } catch (error) {
      setPaymentState('error')
      setPaymentError(error?.message || 'Could not check the payment yet.')
    }
  }

'@
Replace-Exact $guidedPath `
"  if (complete) {" `
($paymentActions + "  if (complete) {") `
"GuidedOrder payment actions"

# 7) Add payment panel before file status.
$paymentPanel = @'
        {orderResponse?.paymentToken && fulfilment !== 'delivery' && (
          <div className={`qs-payment-card ${paymentState === 'paid' ? 'paid' : paymentState === 'waiting' ? 'pending' : ''}`}>
            <div className="qs-payment-card-head">
              <div>
                <span className="eyebrow">Payment</span>
                <strong>{paymentState === 'paid' ? 'Payment confirmed' : `Pay ${formatMoney(total)} securely`}</strong>
                <small>{paymentState === 'paid' ? 'PayFast confirmed this order as paid.' : 'Your order already exists. Payment updates the same order — it does not create a duplicate.'}</small>
              </div>
              <span className={`qs-payment-status ${paymentState === 'paid' ? 'paid' : paymentState === 'waiting' ? 'waiting' : ''}`}>
                {paymentState === 'paid' ? 'Paid' : paymentState === 'waiting' || paymentState === 'checking' ? 'Awaiting confirmation' : 'Unpaid'}
              </span>
            </div>
            {paymentState !== 'paid' && (
              <div className="qs-payment-actions">
                <button className="button primary-green" type="button" disabled={paymentState === 'starting'} onClick={startPayment}>
                  {paymentState === 'starting' ? 'Opening PayFast…' : 'Pay securely with PayFast'}
                </button>
                {(paymentState === 'waiting' || paymentState === 'checking' || paymentState === 'error') && (
                  <button className="button ghost" type="button" disabled={paymentState === 'checking'} onClick={checkPayment}>
                    {paymentState === 'checking' ? 'Checking…' : 'Check payment'}
                  </button>
                )}
              </div>
            )}
            {paymentError ? <p className="qs-payment-error">{paymentError}</p> : null}
          </div>
        )}

        {orderResponse?.paymentToken && fulfilment === 'delivery' && (
          <div className="qs-payment-card pending">
            <div className="qs-payment-card-head">
              <div>
                <span className="eyebrow">Payment</span>
                <strong>Delivery price first.</strong>
                <small>Quick Solution must confirm the delivery fee before PayFast opens, so you cannot be charged the wrong total.</small>
              </div>
              <span className="qs-payment-status waiting">Waiting for delivery price</span>
            </div>
          </div>
        )}

'@
Replace-Exact $guidedPath `
"        {file && uploadedFile && (" `
($paymentPanel + "        {file && uploadedFile && (") `
"GuidedOrder payment confirmation panel"

# 8) Relative timestamps in Orders.
$oldDate = @'
function dateTime(value) {
  if (!value) return '—'
  try {
    return new Intl.DateTimeFormat('en-ZA', { dateStyle: 'medium', timeStyle: 'short' }).format(new Date(value))
  } catch {
    return value
  }
}
'@
$newDate = @'
function fullDateTime(value) {
  if (!value) return '—'
  try {
    return new Intl.DateTimeFormat('en-ZA', { dateStyle: 'medium', timeStyle: 'short' }).format(new Date(value))
  } catch {
    return value
  }
}

function dateTime(value) {
  if (!value) return '—'
  try {
    const date = new Date(value)
    const now = new Date()
    const startToday = new Date(now.getFullYear(), now.getMonth(), now.getDate())
    const startDate = new Date(date.getFullYear(), date.getMonth(), date.getDate())
    const dayDiff = Math.round((startToday - startDate) / 86400000)
    const clock = new Intl.DateTimeFormat('en-ZA', { hour: '2-digit', minute: '2-digit', hour12: false }).format(date)
    if (dayDiff === 0) return `Today ${clock}`
    if (dayDiff === 1) return `Yesterday ${clock}`
    if (date.getFullYear() === now.getFullYear()) {
      return new Intl.DateTimeFormat('en-ZA', { day: 'numeric', month: 'short' }).format(date)
    }
    return new Intl.DateTimeFormat('en-ZA', { day: 'numeric', month: 'short', year: 'numeric' }).format(date)
  } catch {
    return value
  }
}
'@
Replace-Exact $adminPath $oldDate $newDate "relative order timestamps"

Replace-Exact $adminPath `
'<span>{dateTime(item.submittedAt)}</span>' `
'<span title={fullDateTime(item.submittedAt)}>{dateTime(item.submittedAt)}</span>' `
"queue timestamp hover metadata"

Replace-Exact $adminPath `
'                    <DetailRow label="Sent at" value={selected.sentAt ? dateTime(selected.sentAt) : ''—''} />' `
'                    <DetailRow label="Sent at" value={selected.sentAt ? fullDateTime(selected.sentAt) : ''—''} />' `
"full timestamp in technical details"

# 9) Load QS-08 CSS.
Replace-Exact $mainPath `
"import './styles/qs07.css'" `
"import './styles/qs07.css'`nimport './styles/qs08.css'" `
"QS-08 stylesheet import"

Write-Host ""
Write-Host "QS-08 UI patch applied."
Write-Host "Run: npm run dev"
