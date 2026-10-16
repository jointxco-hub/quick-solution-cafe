import React, { useEffect, useRef, useState } from 'react'
import { getStaffPaymentState, recordStaffPayment, reconcileInvoiceReceipts } from '../lib/supabaseApi.js'

const money = value => new Intl.NumberFormat('en-ZA', { style: 'currency', currency: 'ZAR' }).format(Number(value || 0))
export default function OrderPaymentState({ orderId, onChanged }) {
  const [state, setState] = useState(null)
  const [error, setError] = useState('')
  const [refresh, setRefresh] = useState(0)
  const [loading, setLoading] = useState(true)
  const [draft, setDraft] = useState(null)
  const [saving, setSaving] = useState(false)
  const [confirmed, setConfirmed] = useState(false)
  const latest = useRef({ onChanged, draft, saving })
  latest.current = { onChanged, draft, saving }
  const canSyncInvoice = state?.issues?.length === 1 && state.issues[0] === 'invoice_projection_missing'
  const syncInvoice = async () => {
    if (saving || loading || !canSyncInvoice) return
    setSaving(true); setError('')
    try {
      setState(await reconcileInvoiceReceipts(orderId))
      onChanged?.()
    } catch (failure) { setError(failure.message || 'Could not sync existing invoice receipts. Re-check and try again.') }
    finally { setSaving(false) }
  }
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
    let pending = false
    let previous = null
    setState(null); setDraft(null); setConfirmed(false)
    const check = async (initial = false) => {
      if (!active || pending || (!initial && (document.hidden || latest.current.saving || latest.current.draft))) return
      pending = true
      setLoading(true)
      let timeout
      try {
        // Bound the read so a suspended mobile request cannot lock out retries.
        // Promise.race also prevents a late timed-out result from replacing newer state.
        const value = await Promise.race([
          getStaffPaymentState(orderId),
          new Promise((_, reject) => { timeout = setTimeout(() => reject(new Error('Payment check timed out')), 10000) })
        ])
        if (!active) return
        const signature = JSON.stringify(value)
        setState(value); setError('')
        if ((previous !== null && previous !== signature) || (initial && refresh > 0)) latest.current.onChanged?.()
        previous = signature
      } catch {
        if (active) setError('Could not refresh payments. The displayed balance may be out of date. Please re-check.')
      } finally {
        clearTimeout(timeout)
        pending = false
        if (active) setLoading(false)
      }
    }
    const resume = () => { check() }
    check(true)
    const timer = window.setInterval(resume, 15000)
    window.addEventListener('focus', resume)
    window.addEventListener('online', resume)
    document.addEventListener('visibilitychange', resume)
    return () => {
      active = false
      window.clearInterval(timer)
      window.removeEventListener('focus', resume)
      window.removeEventListener('online', resume)
      document.removeEventListener('visibilitychange', resume)
    }
  }, [orderId, refresh])
  return <section className="order-payment-state" aria-label="Payment record" aria-busy={loading}>
    <h4>Payment record</h4>
    <p><small>Payments refresh automatically while this page is open.</small></p>
    {loading && <p role="status">{state ? 'Updating payments…' : 'Checking payments…'}</p>}
    {state && (loading || error) && <p><small>Last checked balance — waiting for an updated payment check.</small></p>}
    {error && <p role="alert">{error}</p>}
    {state && <>
      {state.reviewRequired ? <p className="payment-review" role="status">Payment review required. A reliable balance is unavailable until the linked records are reconciled.</p> : <p><strong>{money(state.balanceDue)}</strong> outstanding</p>}
      {canSyncInvoice && <div><p>An existing receipt needs to be linked to the invoice. This will not record another payment.</p><button type="button" disabled={saving || loading} onClick={syncInvoice}>{saving ? 'Syncing…' : 'Sync existing invoice receipts'}</button></div>}
      <dl><dt>Received in Café</dt><dd>{money(state.cafePaid)}</dd>
        {state.oppsPaid !== null && <><dt>Recorded in OPPS</dt><dd>{money(state.oppsPaid)}</dd></>}
      </dl>
      {state.receipts.length > 0 && <details><summary>Received payments</summary><ul>{state.receipts.map(receipt => <li key={receipt.id}>{receipt.method === 'payfast' ? 'PayFast' : receipt.method.toUpperCase()} · {money(receipt.amount)}{receipt.receivedAt ? ` · ${new Date(receipt.receivedAt).toLocaleDateString('en-ZA')}` : ''}</li>)}</ul></details>}
      {!error && !loading && !state.reviewRequired && !state.closed && state.balanceDue > 0 && !draft && <button type="button" onClick={() => { setConfirmed(false); setDraft({ method: 'cash', amount: state.balanceDue, reference: '', operationKey: crypto.randomUUID() }) }}>Record payment</button>}
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
