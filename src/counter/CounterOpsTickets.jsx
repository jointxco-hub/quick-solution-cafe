import React, { useEffect, useState } from 'react'
import { getAdminSession } from '../lib/supabaseApi.js'

// Separate from counter sales and cash-up: fulfillment-only OPPS tickets.
// Server validates membership and every status transition.
const base = String(import.meta.env.VITE_SUPABASE_URL || '').replace(/\/$/, '')
const key = String(import.meta.env.VITE_SUPABASE_PUBLISHABLE_KEY || import.meta.env.VITE_SUPABASE_ANON_KEY || '')
const enabled = import.meta.env.VITE_OPPS_CAFE_QUEUE_ENABLED === 'true' &&
  base === 'https://tijiamrfnxrbitafiflj.supabase.co'
const NEXT = { received: 'in_production', in_production: 'ready', ready: 'collected' }
const LABEL = { received: 'Start production', in_production: 'Mark ready', ready: 'Mark collected' }

async function callTicketRpc(name, payload = {}) {
  if (!enabled) throw new Error('Only available on isolated staging.')
  const token = getAdminSession()?.access_token
  if (!token || !key) throw new Error('Staff sign-in required.')
  const response = await fetch(base + '/rest/v1/rpc/' + name, {
    method: 'POST',
    headers: { apikey: key, Authorization: 'Bearer ' + token, 'Content-Type': 'application/json' },
    body: JSON.stringify(payload)
  })
  const body = await response.json().catch(() => null)
  if (!response.ok) throw new Error(body?.message || 'Could not load or update OPPS tickets.')
  return body
}

export default function CounterOpsTickets() {
  const [state, setState] = useState({ loading: true, items: [], error: '' })
  const [busyId, setBusyId] = useState('')
  const [message, setMessage] = useState('')

  const refresh = async () => {
    setState(previous => ({ ...previous, loading: true, error: '' }))
    try {
      const result = await callTicketRpc('list_cafe_opps_handoffs')
      if (!Array.isArray(result?.items)) throw new Error('Unexpected ticket list.')
      setState({ loading: false, items: result.items, error: '' })
    } catch (error) {
      setState({ loading: false, items: [], error: error.message || 'Could not load tickets.' })
    }
  }
  useEffect(() => { refresh() }, [])

  const advance = async ticket => {
    const next = NEXT[ticket.status]
    if (!next || ticket.existingCafeSale) return
    if (!window.confirm('Move ' + ticket.number + ' to ' + next.replace('_', ' ') + '? This changes fulfillment only.')) return
    setBusyId(ticket.id)
    setMessage('')
    try {
      await callTicketRpc('update_cafe_opps_handoff', { p_id: ticket.id, p_status: next })
      setMessage(ticket.number + ' updated to ' + next.replace('_', ' ') + '.')
      await refresh()
    } catch (error) { setMessage(error.message || 'Update failed.') }
    finally { setBusyId('') }
  }

  return <section aria-label="From OPPS fulfillment tickets" style={{ background: '#fff', borderRadius: 16, padding: 16 }}>
    <div style={{ display: 'flex', alignItems: 'center', justifyContent: 'space-between', gap: 12 }}>
      <div><small>FROM OPPS · STAGING</small><h2>Fulfillment tickets</h2></div>
      <button type="button" onClick={refresh} disabled={state.loading} style={{ borderRadius: 10, padding: '9px 13px', border: '1px solid #ddd', background: '#fafafa', cursor: 'pointer' }}>Refresh</button>
    </div>
    <p>These are existing OPPS jobs. They are not new counter sales and do not enter cash-up.</p>
    {state.loading && <p role="status">Loading tickets…</p>}
    {state.error && <p role="alert">{state.error}</p>}
    {message && <p role="status">{message}</p>}
    {!state.loading && !state.error && !state.items.length && <p>No OPPS handoffs received yet.</p>}
    <div style={{ display: 'grid', gap: 10 }}>
      {state.items.map(ticket => <article key={ticket.id} style={{ border: '1px solid #e6e6e2', padding: 14, borderRadius: 12 }}>
        <strong style={{ overflowWrap: 'anywhere' }}>{ticket.number}</strong>
        <p style={{ margin: '6px 0' }}>{ticket.customer || 'Customer'} · {ticket.sourceType}</p>
        <p style={{ margin: '6px 0' }}>Fulfillment: <strong>{ticket.status.replace('_', ' ')}</strong></p>
        {ticket.existingCafeSale && ticket.status !== 'cancelled' && <p role="alert" style={{ padding: 10, background: '#fff4e7', borderRadius: 8 }}>Already linked to a Café sale. Use the original Café order for fulfillment; this ticket is blocked.</p>}
        {ticket.reconciliationReason && <p role="status" style={{ background: '#f2f1ed', padding: 10, borderRadius: 8 }}>Reconciled: {ticket.reconciliationReason}</p>}
        {NEXT[ticket.status] && !ticket.existingCafeSale && <button type="button" disabled={busyId===ticket.id} style={{ background: '#142d28', color: '#fff', border: 0, borderRadius: 10, padding: '10px 15px', fontWeight: 650, cursor: 'pointer' }}
          onClick={() => advance(ticket)}>{busyId===ticket.id ? 'Updating…' : LABEL[ticket.status]}</button>}
      </article>)}
    </div>
  </section>
}
