import React, { useEffect, useState } from 'react'
import { getStaffPaymentState } from '../lib/supabaseApi.js'

const money = value => new Intl.NumberFormat('en-ZA', { style: 'currency', currency: 'ZAR' }).format(Number(value || 0))
export default function OrderPaymentState({ orderId }) {
  const [state, setState] = useState(null)
  const [error, setError] = useState('')
  const [refresh, setRefresh] = useState(0)
  const [loading, setLoading] = useState(true)
  useEffect(() => {
    let active = true
    setLoading(true); setError(''); setState(null)
    getStaffPaymentState(orderId).then(value => { if (active) setState(value) })
      .catch(() => { if (active) setError('Could not check payments. Please try again.') })
      .finally(() => { if (active) setLoading(false) })
    return () => { active = false }
  }, [orderId, refresh])
  return <section className="order-payment-state" aria-label="Payment record" aria-busy={loading}>
    <h4>Payment record</h4>
    {loading && <p role="status">Checking payments…</p>}
    {error && <p role="alert">{error}</p>}
    {state && <>
      {state.reviewRequired ? <p className="payment-review" role="status">Payment review required. A reliable balance is unavailable until the linked records are reconciled.</p> : <p><strong>{money(state.balanceDue)}</strong> outstanding</p>}
      <dl><dt>Received in Café</dt><dd>{money(state.cafePaid)}</dd>
        {state.oppsPaid !== null && <><dt>Recorded in OPPS</dt><dd>{money(state.oppsPaid)}</dd></>}
      </dl>
      {state.receipts.length > 0 && <details><summary>Received payments</summary><ul>{state.receipts.map(receipt => <li key={receipt.id}>{receipt.method === 'payfast' ? 'PayFast' : receipt.method.toUpperCase()} · {money(receipt.amount)}{receipt.receivedAt ? ` · ${new Date(receipt.receivedAt).toLocaleDateString('en-ZA')}` : ''}</li>)}</ul></details>}
    </>}
    <button type="button" disabled={loading} onClick={() => setRefresh(n => n + 1)}>Re-check payments</button>
  </section>
}
