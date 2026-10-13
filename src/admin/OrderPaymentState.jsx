import React, { useEffect, useState } from 'react'
import { getStaffPaymentState, recordStaffPayment } from '../lib/supabaseApi.js'

const money = value => new Intl.NumberFormat('en-ZA', { style: 'currency', currency: 'ZAR' }).format(Number(value || 0))
export default function OrderPaymentState({ orderId, onChanged }) {
  const [state, setState] = useState(null)
  const [error, setError] = useState('')
  const [refresh, setRefresh] = useState(0)
  const [loading, setLoading] = useState(true)
  const [draft, setDraft] = useState(null)
  const [saving, setSaving] = useState(false)
  const [confirmed, setConfirmed] = useState(false)
  const submit = async event => {
    event.preventDefault()
    if (saving || !confirmed || !draft) return
    setSaving(true); setError('')
    try {
      const result = await recordStaffPayment({ orderId, ...draft })
      setState(result.payment); setDraft(null); setConfirmed(false)
      onChanged?.()
    } catch (failure) {
      setError(failure.message || 'Could not confirm the receipt. Retry with the same details.')
    } finally { setSaving(false) }
  }
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
      {!state.reviewRequired && !state.closed && state.balanceDue > 0 && !draft && <button type="button" onClick={() => { setConfirmed(false); setDraft({ method: 'cash', amount: state.balanceDue, reference: '', operationKey: crypto.randomUUID() }) }}>Record payment</button>}
      {draft && <form onSubmit={submit}>
        <label>Payment method<select disabled={saving} value={draft.method} onChange={event => { setConfirmed(false); setDraft({ ...draft, method: event.target.value }) }}><option value="cash">Cash</option><option value="eft">EFT</option></select></label>
        <p>Amount received: <strong>{money(draft.amount)}</strong></p>
        <label>{draft.method === 'eft' ? 'Bank reference' : 'Reference (optional)'}<input maxLength={120} required={draft.method === 'eft'} disabled={saving} value={draft.reference} onChange={event => setDraft({ ...draft, reference: event.target.value })}/></label>
        <label className="receipt-confirm"><input type="checkbox" required disabled={saving} checked={confirmed} onChange={event => setConfirmed(event.target.checked)}/>{draft.method === 'eft' ? 'I verified that the money arrived in our bank account.' : 'I received this cash from the customer.'}</label>
        <button type="submit" disabled={saving || !confirmed}>{saving ? 'Recording…' : 'Confirm payment received'}</button>
        <button type="button" disabled={saving} onClick={() => { setDraft(null); setConfirmed(false) }}>Cancel</button>
      </form>}
    </>}
    <button type="button" disabled={loading || saving} onClick={() => { setDraft(null); setRefresh(n => n + 1) }}>Re-check payments</button>
  </section>
}
