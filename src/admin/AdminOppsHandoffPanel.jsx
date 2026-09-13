import React, { useEffect, useMemo, useRef, useState } from 'react'
import Icon from '../components/Icon.jsx'
import {
  buildOppsAppUrl,
  loadQuickSolutionOppsHandoffs,
  previewQuickSolutionOppsHandoff,
  sendQuickSolutionOrderToOpps
} from '../lib/supabaseApi.js'

const HANDOFF_LABELS = {
  not_previewed: 'Checking',
  ready: 'Ready for OPPS',
  blocked: 'Needs attention',
  sending: 'Sending to OPPS',
  sent: 'Sent to OPPS',
  failed: 'Send failed'
}

const SERVICE_STATUS_LABELS = {
  submitted: 'Submitted',
  accepted: 'Accepted by operations',
  in_production: 'In production',
  ready: 'Ready for collection',
  completed: 'Completed',
  cancelled: 'Cancelled'
}

function money(value) {
  return new Intl.NumberFormat('en-ZA', { style: 'currency', currency: 'ZAR', maximumFractionDigits: 2 }).format(Number(value || 0))
}

function dateTime(value) {
  if (!value) return '—'
  try {
    return new Intl.DateTimeFormat('en-ZA', { dateStyle: 'medium', timeStyle: 'short' }).format(new Date(value))
  } catch {
    return value
  }
}

function toneForStatus(status) {
  if (status === 'ready' || status === 'sent' || status === 'paid' || status === 'completed' || status === 'accepted') return 'good'
  if (status === 'blocked' || status === 'failed' || status === 'cancelled') return 'bad'
  if (status === 'sending' || status === 'pending' || status === 'unpaid') return 'warn'
  return 'neutral'
}

function paymentLabel(status) {
  if (status === 'paid') return 'Payment received'
  if (status === 'failed') return 'Payment failed'
  if (status === 'cancelled') return 'Payment cancelled'
  if (status === 'refunded') return 'Payment refunded'
  return 'Payment pending'
}

function fulfilmentLabel(type) {
  if (type === 'collection') return 'Collection'
  if (type === 'courier') return 'Delivery / courier'
  if (type === 'service_only') return 'Service only'
  return type || 'Fulfilment not set'
}

function StatusPill({ label, tone = 'neutral' }) {
  return <span className={`status-pill ${tone}`}>{label}</span>
}

function DetailRow({ label, value }) {
  return (
    <div className="detail-row">
      <span>{label}</span>
      <strong>{value}</strong>
    </div>
  )
}

function MessageList({ title, icon, items = [], tone = 'neutral', emptyLabel }) {
  return (
    <div className={`message-card ${tone}`}>
      <div className="message-card-title"><Icon name={icon} size={17} /><strong>{title}</strong></div>
      {items.length ? (
        <ul>
          {items.map((item, index) => <li key={`${title}-${index}`}>{item?.message || item?.code || String(item)}</li>)}
        </ul>
      ) : <p>{emptyLabel}</p>}
    </div>
  )
}

export default function AdminOppsHandoffPanel() {
  const [queue, setQueue] = useState([])
  const [selectedId, setSelectedId] = useState('')
  const [previewCache, setPreviewCache] = useState({})
  const [loadState, setLoadState] = useState('loading')
  const [previewingId, setPreviewingId] = useState('')
  const [sendingId, setSendingId] = useState('')
  const [notice, setNotice] = useState('')
  const [error, setError] = useState('')
  const autoPreviewed = useRef(new Set())

  const hydratePreviewCache = (items) => {
    const hydrated = {}
    items.forEach((item) => {
      if (item?.previewPayload && typeof item.previewPayload === 'object' && Object.keys(item.previewPayload).length > 0) {
        hydrated[item.serviceOrderId] = item.previewPayload
      }
    })
    setPreviewCache((current) => ({ ...hydrated, ...current }))
  }

  const loadQueue = async ({ silent = false } = {}) => {
    if (!silent) setLoadState('loading')
    setError('')
    try {
      const data = await loadQuickSolutionOppsHandoffs()
      const list = Array.isArray(data) ? data : []
      setQueue(list)
      hydratePreviewCache(list)
      setSelectedId((current) => list.some((item) => item.serviceOrderId === current) ? current : list[0]?.serviceOrderId || '')
      setLoadState('ready')
      return list
    } catch (nextError) {
      setLoadState('error')
      setError(nextError.message || 'Could not load Quick Solution handoff queue.')
      throw nextError
    }
  }

  useEffect(() => {
    loadQueue().catch(() => {})
  }, [])

  const summary = useMemo(() => ({
    total: queue.length,
    ready: queue.filter((item) => item.handoffStatus === 'ready').length,
    blocked: queue.filter((item) => item.handoffStatus === 'blocked').length,
    sent: queue.filter((item) => item.handoffStatus === 'sent').length
  }), [queue])

  const selected = queue.find((item) => item.serviceOrderId === selectedId) || null
  const preview = selected ? previewCache[selected.serviceOrderId] : null
  const proposedOppsOrder = preview?.proposedOppsOrder || null
  const proposedLines = Array.isArray(proposedOppsOrder?.products) ? proposedOppsOrder.products : []
  const proposedFiles = Array.isArray(proposedOppsOrder?.source_metadata?.quick_solution?.files)
    ? proposedOppsOrder.source_metadata.quick_solution.files
    : []
  const blockerItems = preview?.blockers || selected?.blockers || []
  const warningItems = preview?.warnings || selected?.warnings || []

  const refreshPreview = async (serviceOrderId = selected?.serviceOrderId, { quiet = false } = {}) => {
    if (!serviceOrderId) return
    setPreviewingId(serviceOrderId)
    setError('')
    if (!quiet) setNotice('')
    try {
      const data = await previewQuickSolutionOppsHandoff(serviceOrderId)
      setPreviewCache((current) => ({ ...current, [serviceOrderId]: data }))
      setQueue((current) => current.map((item) => item.serviceOrderId === serviceOrderId
        ? {
            ...item,
            handoffStatus: item.handoffStatus === 'sent' || item.oppsOrderId ? 'sent' : data?.ready ? 'ready' : 'blocked',
            blockers: Array.isArray(data?.blockers) ? data.blockers : [],
            warnings: Array.isArray(data?.warnings) ? data.warnings : [],
            mappingVersion: data?.mappingVersion || item.mappingVersion,
            lastPreviewedAt: new Date().toISOString()
          }
        : item
      ))
      if (!quiet) setNotice('Order checks refreshed.')
    } catch (nextError) {
      setError(nextError.message || 'Could not build the OPPS preview.')
    } finally {
      setPreviewingId('')
    }
  }

  useEffect(() => {
    if (!selected?.serviceOrderId) return
    if (previewCache[selected.serviceOrderId]) return
    if (selected.handoffStatus === 'sent' || selected.oppsOrderId) return
    if (previewingId === selected.serviceOrderId) return
    if (autoPreviewed.current.has(selected.serviceOrderId)) return

    autoPreviewed.current.add(selected.serviceOrderId)
    refreshPreview(selected.serviceOrderId, { quiet: true })
  }, [selectedId, selected?.serviceOrderId, selected?.handoffStatus, selected?.oppsOrderId])

  const sendSelected = async () => {
    if (!selected?.serviceOrderId || sendingId) return
    setSendingId(selected.serviceOrderId)
    setError('')
    setNotice('')
    try {
      const result = await sendQuickSolutionOrderToOpps(selected.serviceOrderId)
      if (result?.ok) {
        setNotice(result.replayed ? 'Already in OPPS — the existing order was reused.' : 'Sent to OPPS successfully.')
      } else {
        setNotice('This order still needs attention before it can be sent to OPPS.')
      }
      const refreshed = await loadQueue({ silent: true })
      const latest = refreshed.find((item) => item.serviceOrderId === selected.serviceOrderId)
      if (latest?.previewPayload) {
        setPreviewCache((current) => ({ ...current, [selected.serviceOrderId]: latest.previewPayload }))
      }
    } catch (nextError) {
      setError(nextError.message || 'Could not send this order to OPPS.')
    } finally {
      setSendingId('')
    }
  }

  const copyOppsId = async () => {
    if (!selected?.oppsOrderId || !navigator?.clipboard) return
    try {
      await navigator.clipboard.writeText(selected.oppsOrderId)
      setNotice('OPPS order ID copied.')
    } catch {
      setNotice('Could not copy the OPPS order ID in this browser.')
    }
  }

  const fileCount = proposedFiles.length
  const canSend = selected && selected.handoffStatus !== 'sent' && blockerItems.length === 0 && Boolean(preview)

  return (
    <section className="handoff-section">
      <div className="handoff-heading">
        <div>
          <span className="eyebrow">Orders · OPPS handoff</span>
          <h2>Review the job. Then send it to operations.</h2>
          <p>Quick Solution catches missing files and incomplete details before a job becomes an OPPS production order.</p>
        </div>
        <div className="handoff-heading-actions">
          <button type="button" onClick={() => loadQueue().catch(() => {})}><Icon name="refresh" size={16}/> Refresh orders</button>
        </div>
      </div>

      <div className="handoff-summary-grid">
        <article className="handoff-metric"><span>Orders in view</span><strong>{summary.total}</strong><small>Customer jobs visible to this Quick Solution tenant.</small></article>
        <article className="handoff-metric good"><span>Ready for OPPS</span><strong>{summary.ready}</strong><small>No blocking handoff issues.</small></article>
        <article className="handoff-metric bad"><span>Needs attention</span><strong>{summary.blocked}</strong><small>Missing or incomplete job information.</small></article>
        <article className="handoff-metric neutral"><span>Sent to OPPS</span><strong>{summary.sent}</strong><small>Linked to operations already.</small></article>
      </div>

      {(notice || error) && <div className={`admin-system-message ${error ? 'error' : ''}`}>{error || notice}</div>}

      <div className="handoff-layout">
        <aside className="handoff-queue">
          <div className="handoff-queue-title"><strong>Customer orders</strong><small>{queue.length} visible</small></div>
          {loadState === 'loading' ? <div className="handoff-empty">Loading orders…</div> : null}
          {loadState !== 'loading' && queue.length === 0 ? <div className="handoff-empty">No Quick Solution orders are available yet.</div> : null}
          <div className="handoff-list">
            {queue.map((item) => (
              <button
                key={item.serviceOrderId}
                type="button"
                className={`handoff-card ${selectedId === item.serviceOrderId ? 'active' : ''}`}
                onClick={() => setSelectedId(item.serviceOrderId)}
              >
                <div className="handoff-card-top">
                  <div>
                    <strong>{item.orderNumber}</strong>
                    <small>{item.customerName}</small>
                  </div>
                  <StatusPill label={HANDOFF_LABELS[item.handoffStatus] || item.handoffStatus} tone={toneForStatus(item.handoffStatus)} />
                </div>
                <div className="handoff-card-meta">
                  <span>{money(item.totalAmount)}</span>
                  <span>{dateTime(item.submittedAt)}</span>
                </div>
                <div className="handoff-card-tags">
                  <StatusPill label={paymentLabel(item.paymentStatus)} tone={toneForStatus(item.paymentStatus)} />
                  {item.oppsOrderId ? <StatusPill label="OPPS linked" tone="good" /> : null}
                </div>
                <div className="handoff-card-flags">
                  <span>{Array.isArray(item.blockers) ? item.blockers.length : 0} issue(s)</span>
                  <span>{Array.isArray(item.warnings) ? item.warnings.length : 0} note(s)</span>
                </div>
              </button>
            ))}
          </div>
        </aside>

        <section className="handoff-preview">
          {selected ? (
            <>
              <div className="handoff-preview-top">
                <div>
                  <span className="eyebrow">Selected order</span>
                  <h3>{selected.orderNumber}</h3>
                  <p>{selected.customerName} · {money(selected.totalAmount)} · submitted {dateTime(selected.submittedAt)}</p>
                </div>
                <div className="handoff-preview-actions">
                  <button type="button" onClick={() => refreshPreview(selected.serviceOrderId)} disabled={previewingId === selected.serviceOrderId || selected.handoffStatus === 'sent'}><Icon name="refresh" size={16}/> {previewingId === selected.serviceOrderId ? 'Checking…' : selected.handoffStatus === 'sent' ? 'Checks saved' : 'Re-check order'}</button>
                  <button type="button" className="button dark" onClick={sendSelected} disabled={sendingId === selected.serviceOrderId || !canSend}>
                    <Icon name="send" size={16}/> {selected.handoffStatus === 'sent' ? 'Sent to OPPS' : sendingId === selected.serviceOrderId ? 'Sending…' : blockerItems.length ? 'Fix issues first' : 'Send to OPPS'}
                  </button>
                </div>
              </div>

              <div className="handoff-status-row">
                <StatusPill label={HANDOFF_LABELS[selected.handoffStatus] || selected.handoffStatus} tone={toneForStatus(selected.handoffStatus)} />
                <StatusPill label={paymentLabel(selected.paymentStatus)} tone={toneForStatus(selected.paymentStatus)} />
                {preview ? <StatusPill label={fileCount ? `${fileCount} file${fileCount === 1 ? '' : 's'} received` : 'No file attached'} tone={fileCount ? 'good' : 'neutral'} /> : null}
                {proposedOppsOrder ? <StatusPill label={fulfilmentLabel(proposedOppsOrder.fulfillment_type)} tone="neutral" /> : null}
              </div>

              <div className="handoff-detail-grid">
                <DetailRow label="Order state" value={SERVICE_STATUS_LABELS[selected.serviceStatus] || selected.serviceStatus} />
                <DetailRow label="Last checked" value={selected.lastPreviewedAt ? dateTime(selected.lastPreviewedAt) : previewingId === selected.serviceOrderId ? 'Checking now…' : 'Checking automatically…'} />
                <DetailRow label="OPPS link" value={selected.oppsOrderId ? 'Created and linked' : 'Not created yet'} />
                <DetailRow label="Operational handoff" value={HANDOFF_LABELS[selected.handoffStatus] || selected.handoffStatus} />
              </div>

              <div className="handoff-message-grid">
                <MessageList title={blockerItems.length ? "Needs attention" : "Job checks"} icon={blockerItems.length ? "xCircle" : "checkCircle"} tone={blockerItems.length ? 'bad' : 'good'} items={blockerItems} emptyLabel="No blocking issues found." />
                <MessageList title="Staff notes" icon="alertCircle" tone={warningItems.length ? 'warn' : 'neutral'} items={warningItems} emptyLabel="No extra warnings right now." />
              </div>

              <div className="handoff-preview-body">
                <div className="handoff-subsection">
                  <div className="handoff-subsection-title"><Icon name="layers" size={16}/><strong>What OPPS will receive</strong></div>
                  {proposedOppsOrder ? (
                    <>
                      <div className="handoff-detail-grid compact">
                        <DetailRow label="Starting stage" value="Received" />
                        <DetailRow label="Fulfilment" value={fulfilmentLabel(proposedOppsOrder.fulfillment_type)} />
                        <DetailRow label="Payment" value={paymentLabel(proposedOppsOrder.payment_status)} />
                        <DetailRow label="Total" value={money(proposedOppsOrder.total_amount)} />
                      </div>
                      <div className="handoff-lines">
                        <div className="handoff-lines-header"><strong>Production lines</strong><small>{proposedLines.length} line(s)</small></div>
                        {proposedLines.length ? proposedLines.map((line, index) => (
                          <div className="handoff-line" key={`${line.line_id || index}-${index}`}>
                            <div>
                              <strong>{line.name}</strong>
                              <small>{line.category || 'Quick Solution'} · quantity {line.quantity}</small>
                            </div>
                            <span>{money(line.line_total)}</span>
                          </div>
                        )) : <div className="handoff-empty small">No production lines found.</div>}
                      </div>
                      <div className="handoff-lines">
                        <div className="handoff-lines-header"><strong>Private customer files</strong><small>{proposedFiles.length} file(s)</small></div>
                        {proposedFiles.length ? proposedFiles.map((file, index) => (
                          <div className="handoff-line file" key={`${file.id || file.name || index}-${index}`}>
                            <div>
                              <strong>{file.original_filename || file.name || `File ${index + 1}`}</strong>
                              <small>{file.mime_type || file.mimeType || 'Private upload'}{file.byte_size ? ` · ${file.byte_size} bytes` : ''}</small>
                            </div>
                            <span>Private</span>
                          </div>
                        )) : <div className="handoff-empty small">No private file upload is linked to this job.</div>}
                      </div>
                    </>
                  ) : (
                    <div className="handoff-empty small">{previewingId === selected.serviceOrderId ? 'Checking the order now…' : 'The order preview will load automatically.'}</div>
                  )}
                </div>

                <div className="handoff-subsection handoff-after-send">
                  <div className="handoff-subsection-title"><Icon name="external" size={16}/><strong>{selected.oppsOrderId ? 'Continue in OPPS' : 'After handoff'}</strong></div>
                  <p>{selected.oppsOrderId
                    ? 'The customer order is linked. OPPS is now the production home for this job.'
                    : 'Sending creates one canonical OPPS order and keeps the Quick Solution backlink for tracking.'}</p>
                  <div className="handoff-follow-up-actions">
                    <button type="button" onClick={() => window.open(buildOppsAppUrl(selected.oppsOrderId || ''), '_blank', 'noopener,noreferrer')}><Icon name="external" size={16}/> Open OPPS</button>
                    <button type="button" onClick={copyOppsId} disabled={!selected.oppsOrderId}><Icon name="copy" size={16}/> Copy order ID</button>
                  </div>
                </div>

                <details className="handoff-technical-details">
                  <summary>Technical details</summary>
                  <div className="handoff-detail-grid compact">
                    <DetailRow label="Quick Solution ID" value={selected.serviceOrderId} />
                    <DetailRow label="OPPS order ID" value={selected.oppsOrderId || '—'} />
                    <DetailRow label="Mapping version" value={selected.mappingVersion || preview?.mappingVersion || '—'} />
                    <DetailRow label="Sent at" value={selected.sentAt ? dateTime(selected.sentAt) : '—'} />
                  </div>
                </details>
              </div>
            </>
          ) : <div className="handoff-empty large">Select a Quick Solution order to review the OPPS handoff.</div>}
        </section>
      </div>
    </section>
  )
}
