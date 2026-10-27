import React, { useEffect, useMemo, useState } from 'react'
import { fetchOppsCafeWorkQueue } from '../lib/oppsCafeWorkQueueApi.js'
import { describeOppsCafeWorkItem } from '../lib/oppsCafeWorkQueue.js'

const PAGE_SIZE = 10

// Staging-only, read-only view. Counter handoff and payment actions are not available yet.
export default function AdminOppsWorkQueuePanel() {
  const [state, setState] = useState({ status: 'loading', items: [] })
  const [search, setSearch] = useState('')
  const [type, setType] = useState('all')
  const [payment, setPayment] = useState('all')
  const [visibleCount, setVisibleCount] = useState(PAGE_SIZE)
  const [selectedKey, setSelectedKey] = useState(null)

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

  const filtered = useMemo(() => state.items.filter(item => {
    if (type !== 'all' && item.sourceType !== type) return false
    if (payment !== 'all' && item.paymentLabel !== payment) return false
    const q = search.trim().toLowerCase()
    return !q || [item.number, item.customer, item.status].some(value => String(value).toLowerCase().includes(q))
  }), [state.items, type, payment, search])

  const updateSearch = value => { setSearch(value); setVisibleCount(PAGE_SIZE) }
  const updateType = value => { setType(value); setVisibleCount(PAGE_SIZE) }
  const updatePayment = value => { setPayment(value); setVisibleCount(PAGE_SIZE) }
  const invoices = state.items.filter(item => item.sourceType === 'invoice').length
  const orders = state.items.filter(item => item.sourceType === 'order').length
  const selected = state.items.find(item => item.key === selectedKey)

  return <section aria-label="OPPS work queue" className="admin-section-block">
    <div className="admin-section-title">
      <div><span className="eyebrow">From OPPS · Staging</span><h3>Orders & invoices</h3></div>
      <button type="button" onClick={refresh} disabled={state.status === 'loading'}>Refresh</button>
    </div>
    <p style={{ marginBlock: '8px 16px' }}>Read-only OPPS records. Sending jobs to the counter and taking payments are not enabled yet.</p>
    {state.status === 'loading' && <p role="status">Loading OPPS work…</p>}
    {state.status === 'error' && <p role="alert">{state.message}</p>}
    {state.status === 'empty' && <p>No OPPS invoices or orders found for this Café.</p>}
    {state.status === 'ready' && <>
      <div style={{ display: 'flex', flexWrap: 'wrap', gap: 8, marginBottom: 14 }} aria-label="Queue summary">
        <span className="schema-tag">{state.items.length} total</span>
        <span className="schema-tag">{orders} orders</span>
        <span className="schema-tag">{invoices} invoices</span>
      </div>
      <div style={{ display: 'flex', gap: 8, flexWrap: 'wrap', marginBottom: 14 }}>
        <input aria-label="Search OPPS work" placeholder="Search number or customer" value={search}
          onChange={event => updateSearch(event.target.value)}
          style={{ flex: '1 1 190px', minWidth: 0, padding: '10px 12px', border: '1px solid #ddd', borderRadius: 10 }} />
        <select aria-label="Document type" value={type} onChange={event => updateType(event.target.value)}
          style={{ padding: '10px', borderRadius: 10 }}>
          <option value="all">All types</option>
          <option value="order">Orders</option>
          <option value="invoice">Invoices</option>
        </select>
        <select aria-label="Payment status" value={payment} onChange={event => updatePayment(event.target.value)}
          style={{ padding: '10px', borderRadius: 10 }}>
          <option value="all">All payments</option>
          <option value="Paid">Paid</option>
          <option value="Outstanding">Outstanding</option>
          <option value="Review payment">Review payment</option>
        </select>
      </div>
      <p role="status" style={{ marginBottom: 10 }}>{filtered.length} matching {filtered.length === 1 ? 'record' : 'records'}</p>
      <div style={{ display: 'grid', gap: 8 }}>
        {filtered.slice(0, visibleCount).map(item => <button key={item.key} type="button" className="message-card neutral"
          aria-label={'View ' + item.sourceType + ' ' + item.number}
          onClick={() => setSelectedKey(item.key)}
          style={{ padding: '12px 14px', width: '100%', textAlign: 'left', cursor: 'pointer', font: 'inherit', color: 'inherit', border: selectedKey === item.key ? '1px solid #222' : '1px solid #eceae5' }}>
          <div style={{ display: 'flex', justifyContent: 'space-between', alignItems: 'baseline', gap: 10, flexWrap: 'wrap' }}>
            <strong style={{ overflowWrap: 'anywhere' }}>{item.number}</strong>
            <span className="schema-tag">{item.sourceType}</span>
          </div>
          <p style={{ margin: '5px 0' }}>{item.customer} · {item.status}</p>
          <p style={{ margin: 0 }}><strong>{item.total}</strong> · {item.paymentLabel}
            {item.balance !== '—' ? ' · Balance ' + item.balance : ''}</p>
        </button>)}
      </div>
      {selected && <div role="region" aria-label="Selected OPPS record" style={{ position: 'sticky', bottom: 12, background: '#fff', boxShadow: '0 8px 36px #0002', border: '1px solid #ddd', borderRadius: 16, padding: 18, marginTop: 16, zIndex: 3 }}>
        <div style={{ display: 'flex', gap: 12, alignItems: 'start', justifyContent: 'space-between' }}>
          <div><span className="eyebrow">{selected.sourceType} · Review</span><h3 style={{ overflowWrap: 'anywhere', margin: '5px 0' }}>{selected.number}</h3></div>
          <button type="button" onClick={() => setSelectedKey(null)} aria-label="Close record details">Close ×</button>
        </div>
        <p><strong>{selected.customer}</strong> · {selected.status}</p>
        <p>Total {selected.total} · {selected.paymentLabel} · Balance {selected.balance}</p>
        <p style={{ fontSize: 13, opacity: .75 }}>This record is view-only. Confirm client artwork, quantity, production instructions and payment in OPPS before requesting fulfillment. No counter sale is created here.</p>
        <button type="button" disabled title="Available after staging handoff and duplicate checks pass">Send to Café Counter · Coming soon</button>
      </div>}
      {filtered.length === 0 && <p>No records match these filters.</p>}
      {visibleCount < filtered.length && <button type="button" onClick={() => setVisibleCount(count => count + PAGE_SIZE)}
        style={{ marginTop: 14 }}>Show 10 more</button>}
    </>}
  </section>
}
