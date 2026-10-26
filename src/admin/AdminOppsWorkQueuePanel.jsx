import React, { useEffect, useState } from 'react'
import { fetchOppsCafeWorkQueue } from '../lib/oppsCafeWorkQueueApi.js'
import { describeOppsCafeWorkItem } from '../lib/oppsCafeWorkQueue.js'

// Read-only preview: the endpoint is feature-gated until staging migration and RBAC tests pass.
export default function AdminOppsWorkQueuePanel() {
  const [state, setState] = useState({ status: 'loading', items: [] })
  const refresh = async () => {
    setState({ status: 'loading', items: [] })
    try {
      const data = await fetchOppsCafeWorkQueue()
      const items = data.items.map(describeOppsCafeWorkItem).filter(Boolean)
      setState({ status: items.length ? 'ready' : 'empty', items })
    } catch (error) {
      setState({ status: 'error', items: [], message: error.message || 'Unable to load.' })
    }
  }
  useEffect(() => { refresh() }, [])
  return <section aria-label="OPPS work queue" className="admin-section-block">
    <div className="admin-section-title"><div><span className="eyebrow">From OPPS</span><h3>Orders & invoices</h3></div>
      <button type="button" onClick={refresh} disabled={state.status === 'loading'}>Refresh</button></div>
    {state.status === 'loading' && <p role="status">Loading OPPS work…</p>}
    {state.status === 'error' && <p role="alert">{state.message}</p>}
    {state.status === 'empty' && <p>No OPPS work is waiting.</p>}
    {state.status === 'ready' && <div style={{ display: 'grid', gap: 12 }}>
      {state.items.map(item => <article key={item.key} className="message-card neutral">
        <div className="admin-section-title"><strong>{item.number}</strong><span className="schema-tag">{item.sourceType}</span></div>
        <p>{item.customer} · {item.status}</p>
        <p><strong>{item.total}</strong> · Balance {item.balance} · {item.paymentLabel}</p>
        <small>Fulfillment: {item.handoffStatus === 'not_sent' ? 'Not sent to counter' : item.handoffStatus}</small>
      </article>)}
    </div>}
  </section>
}
