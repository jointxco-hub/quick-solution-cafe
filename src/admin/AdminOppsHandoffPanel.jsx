import React, { useEffect, useMemo, useRef, useState } from 'react'
import { mergeOrderActivity } from './orderActivity.js'
import OrderServiceSummary from './OrderServiceSummary.jsx'
import Icon from '../components/Icon.jsx'
import { readStaffOrderId } from '../lib/staffNotificationNavigation.js'
import { orderDay, filterOrders } from './orderOverview.js'
import {
  loadStaffOrderWorkspace,
  recordStaffOrderActivity,
  getStaffOrderFile,
  adminIssueQuickSolutionTrackingToken,
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
  const [notificationOrderId] = useState(readStaffOrderId)
  const [queue, setQueue] = useState([])
  const [workspaces, setWorkspaces] = useState({})
  const [workspaceError, setWorkspaceError] = useState('')
  const [activityBusy, setActivityBusy] = useState('')
  const [fileBusy, setFileBusy] = useState('')
  const viewed = useRef(new Set())
  const workspaceGeneration = useRef(0)
  const refreshWorkspace = async () => {
    const generation = ++workspaceGeneration.current
    try {
      const data = await loadStaffOrderWorkspace()
      if (generation === workspaceGeneration.current) { setWorkspaces(data || {}); setWorkspaceError('') }
    } catch { setWorkspaceError('Order activity and files could not load. Refresh to try again.') }
  }
  const [orderFilter, setOrderFilter] = useState('all')
  const [detailOpen, setDetailOpen] = useState(() => Boolean(notificationOrderId))
  const [selectedId, setSelectedId] = useState(notificationOrderId)
  const [previewCache, setPreviewCache] = useState({})
  const [loadState, setLoadState] = useState('loading')
  const [previewingId, setPreviewingId] = useState('')
  const [sendingId, setSendingId] = useState('')
  const [issuingTrackingId, setIssuingTrackingId] = useState('')
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
    refreshWorkspace()
    try {
      const data = await loadQuickSolutionOppsHandoffs()
      const list = Array.isArray(data) ? data : []
      setQueue(list)
      hydratePreviewCache(list)
      setSelectedId((current) => list.some((item) => item.serviceOrderId === current) ? current : notificationOrderId || list[0]?.serviceOrderId || '')
      if (notificationOrderId && !list.some((item) => item.serviceOrderId === notificationOrderId)) {
        setNotice('The notified order is unavailable in this account. Choose another order or refresh.')
      }
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

  const todayKey = orderDay(new Date())
  const visibleQueue = filterOrders(queue, orderFilter)
  const summary = useMemo(() => ({
    today: queue.filter((item) => orderDay(item.submittedAt) === todayKey).length,
    total: queue.length,
    ready: queue.filter((item) => item.handoffStatus === 'ready').length,
    blocked: queue.filter((item) => item.handoffStatus === 'blocked').length,
    sent: queue.filter((item) => item.handoffStatus === 'sent').length
  }), [queue, todayKey])

  const selected = queue.find((item) => item.serviceOrderId === selectedId) || null
  const workspace = workspaces[selectedId]
  const acknowledgement = workspace?.activity?.find(entry => entry.event === 'acknowledged')
  const preview = selected ? previewCache[selected.serviceOrderId] : null
  const proposedOppsOrder = preview?.proposedOppsOrder || null
  const proposedLines = Array.isArray(proposedOppsOrder?.products) ? proposedOppsOrder.products : []
  const quickSolutionMeta = proposedOppsOrder?.source_metadata?.quick_solution || null
  const proposedFiles = Array.isArray(quickSolutionMeta?.files)
    ? quickSolutionMeta.files
    : []
  const handoffPoint = quickSolutionMeta?.fulfilment_point || null
  const handoffPointArea = [
    handoffPoint?.address?.area || handoffPoint?.address?.city,
    handoffPoint?.address?.line1
  ].filter(Boolean).join(' · ')
  const fulfilmentDisplay = handoffPoint?.name
    ? handoffPoint.name
    : fulfilmentLabel(proposedOppsOrder?.fulfillment_type)
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

  useEffect(() => {
    if (!detailOpen || !selectedId || !workspace || viewed.current.has(selectedId)) return
    viewed.current.add(selectedId)
    const id = selectedId
    recordStaffOrderActivity(id, 'viewed').then(activity => {
      workspaceGeneration.current++
      setWorkspaces(current => ({ ...current, [id]: { ...current[id], activity: mergeOrderActivity(current[id]?.activity, activity) } }))
    }).catch(() => { viewed.current.delete(id); setWorkspaceError('Could not save your view. Refresh to retry.') })
  }, [detailOpen, selectedId, workspace])

  const acknowledgeOrder = async () => {
    const id = selectedId
    setActivityBusy(id); setError('')
    try {
      const activity = await recordStaffOrderActivity(id, 'acknowledged')
      workspaceGeneration.current++
      setWorkspaces(current => ({ ...current, [id]: { ...current[id], activity: mergeOrderActivity(current[id]?.activity, activity) } }))
    } catch (error) { setError(error.message || 'Could not acknowledge the order.') }
    finally { setActivityBusy('') }
  }
  const openFile = async (file, mode) => {
    // Open during the click so mobile popup blockers do not discard the async result.
    const target = window.open('about:blank', '_blank')
    if (!target) { setError('Allow pop-ups for this app, then open the file again.'); return }
    target.opener = null
    setFileBusy(file.id); setError('')
    try {
      const result = await getStaffOrderFile(selectedId, file.id, mode)
      target.location.replace(result.url)
      setNotice(mode === 'open' ? 'File opened. Use the viewer’s Print or Share → Print action to print.' : 'Download opened in a new window.')
    } catch (error) { target.close(); setError(error.message || 'Could not open the file.') }
    finally { setFileBusy('') }
  }

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

  const copyCustomerTrackingLink = async () => {
    if (!selected?.serviceOrderId) return
    setIssuingTrackingId(selected.serviceOrderId)
    setError('')
    try {
      const result = await adminIssueQuickSolutionTrackingToken(selected.serviceOrderId)
      if (!result?.trackingToken || !result?.orderNumber) throw new Error('Tracking link could not be created.')
      const params = new URLSearchParams({
        order: result.orderNumber,
        token: result.trackingToken
      })
      const link = `${window.location.origin}/track?${params.toString()}`
      if (navigator?.clipboard) {
        await navigator.clipboard.writeText(link)
        setNotice('Customer tracking link copied.')
      } else {
        window.prompt('Copy customer tracking link', link)
      }
    } catch (nextError) {
      setError(nextError?.message || 'Could not create the customer tracking link.')
    } finally {
      setIssuingTrackingId('')
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

  const fileCount = workspace?.files?.length ?? proposedFiles.length
  const canSend = selected && selected.handoffStatus !== 'sent' && blockerItems.length === 0 && Boolean(preview)

  return (
    <section className={`handoff-section ${detailOpen ? 'order-detail-open' : 'order-list-open'}`}>
      <div className="handoff-heading">
        <div>
          <h2>Orders</h2>
        </div>
        <div className="handoff-heading-actions">
          <button type="button" onClick={() => loadQueue().catch(() => {})}><Icon name="refresh" size={16}/> Refresh orders</button>
        </div>
      </div>

      <div className="order-overview" aria-label="Order totals">
        <div><strong>{summary.today}</strong><span>Today</span></div>
        <div><strong>{summary.total}</strong><span>Overall</span></div>
      </div>
      <div className="order-filters" aria-label="Filter orders">
        {[['all', 'All'], ['today', 'Today'], ['attention', 'Needs attention']].map(([value, label]) => <button key={value} type="button" aria-pressed={orderFilter === value} onClick={() => setOrderFilter(value)}>{label}</button>)}
      </div>

      {workspaceError && <div className="admin-system-message error" role="alert">{workspaceError}</div>}
      {(notice || error) && <div className={`admin-system-message ${error ? 'error' : ''}`}>{error || notice}</div>}

      <div className="handoff-layout">
        <aside className="handoff-queue">
          <div className="handoff-queue-title"><strong>Customer orders</strong><small>{visibleQueue.length} shown</small></div>
          {loadState === 'loading' ? <div className="handoff-empty">Loading orders…</div> : null}
          {loadState !== 'loading' && visibleQueue.length === 0 ? <div className="handoff-empty">No orders in this view.</div> : null}
          <div className="handoff-list">
            {visibleQueue.map((item) => (
              <button
                key={item.serviceOrderId}
                type="button"
                className={`handoff-card ${selectedId === item.serviceOrderId ? 'active' : ''}`}
                onClick={() => { setSelectedId(item.serviceOrderId); setDetailOpen(true); if (window.matchMedia('(max-width: 760px)').matches) document.querySelector('.handoff-section')?.scrollIntoView({ block: 'start' }); }}
              >
                <div className="handoff-card-top">
                  <div>
                    <strong>{item.orderNumber}</strong>
                    <small>{item.customerName}</small>
                  </div>
                  <StatusPill label={SERVICE_STATUS_LABELS[item.serviceStatus] || item.serviceStatus || 'Submitted'} tone={['cancelled'].includes(item.serviceStatus) ? 'bad' : item.serviceStatus === 'completed' ? 'good' : 'neutral'} />
                </div>
                <OrderServiceSummary compact workspace={workspaces[item.serviceOrderId]}/>
                <div className="handoff-card-meta">
                  <span>{money(item.totalAmount)}</span>
                  <span title={fullDateTime(item.submittedAt)}>{dateTime(item.submittedAt)}</span>
                </div>
                <div className="handoff-card-tags">
                  {workspaces[item.serviceOrderId] && !workspaces[item.serviceOrderId].activity.some(entry => entry.event === 'viewed') && !['completed', 'cancelled'].includes(item.serviceStatus) && <StatusPill label="No recorded views" tone="new"/>}
                  {workspaces[item.serviceOrderId]?.activity.some(entry => entry.event === 'acknowledged') && <StatusPill label="Acknowledged" tone="good"/>}
                  {workspaces[item.serviceOrderId]?.channel && <StatusPill label={workspaces[item.serviceOrderId].channel === 'counter' ? 'Counter' : 'Online'} />}

                  <StatusPill label={paymentLabel(item.paymentStatus)} tone={toneForStatus(item.paymentStatus)} />
                  {['blocked', 'failed'].includes(item.handoffStatus) ? <StatusPill label="Needs attention" tone="bad" /> : null}
                </div>
                <div className="handoff-card-flags" hidden>
                  <span>{Array.isArray(item.blockers) ? item.blockers.length : 0} issue(s)</span>
                  <span>{Array.isArray(item.warnings) ? item.warnings.length : 0} note(s)</span>
                </div>
              </button>
            ))}
          </div>
        </aside>

        <section className="handoff-preview">
          <button type="button" className="order-back" onClick={() => setDetailOpen(false)}>← All orders</button>
          {selected ? (
            <>
              <div className="handoff-preview-top">
                <div>
                  <span className="eyebrow">Selected order</span>
                  <h3>{selected.orderNumber}</h3>
                  <p>{selected.customerName} · {money(selected.totalAmount)} · submitted {dateTime(selected.submittedAt)}</p>
                </div>
              </div>

              {workspace && <div className="order-workspace">
                <OrderServiceSummary workspace={workspace}/>
                <div className="order-operator-action">
                  {acknowledgement ? <p className="order-acknowledged">Acknowledged by {acknowledgement.name} · {fullDateTime(acknowledgement.at)}</p> : !['completed', 'cancelled'].includes(selected.serviceStatus) && <button className="order-acknowledge" type="button" onClick={acknowledgeOrder} disabled={activityBusy === selectedId}>{activityBusy === selectedId ? 'Saving…' : 'I’ll handle this'}</button>}
                  {!acknowledgement && !['completed', 'cancelled'].includes(selected.serviceStatus) && <small>Let the team know you’re taking this order.</small>}
                </div>
                {workspace.files.length > 0 && <div className="order-files"><h4>Documents</h4>
                  {workspace.files.map(file => <div className="order-file" key={file.id}>
                    <div><strong>{file.name}</strong><small>{Math.max(1, Math.ceil(file.size / 1024))} KB</small></div>
                    <div className="order-file-actions">
                      {['application/pdf', 'image/png', 'image/jpeg', 'image/webp'].includes(file.mime) && <button type="button" disabled={fileBusy === file.id} onClick={() => openFile(file, 'open')}>Open / print</button>}
                      <button type="button" disabled={fileBusy === file.id} onClick={() => openFile(file, 'download')}>{fileBusy === file.id ? 'Opening…' : 'Download'}</button>
                    </div>
                  </div>)}
                </div>}
                {workspace.activity.length > 0 && <details className="order-activity"><summary>Team activity</summary>
                  <button type="button" onClick={refreshWorkspace}>Refresh activity</button>
                  <ul>{workspace.activity.map(entry => <li key={`${entry.actorId}-${entry.event}`}>{entry.name} {entry.event} · {fullDateTime(entry.at)}</li>)}</ul>
                </details>}
              </div>}

                <div className="handoff-preview-actions">
                  <button type="button" className="qs-track-copy-button" onClick={copyCustomerTrackingLink} disabled={issuingTrackingId === selected.serviceOrderId}><Icon name="copy" size={16}/> {issuingTrackingId === selected.serviceOrderId ? 'Creating…' : 'Copy tracking link'}</button>
                  <button type="button" onClick={() => refreshPreview(selected.serviceOrderId)} disabled={previewingId === selected.serviceOrderId || selected.handoffStatus === 'sent'}><Icon name="refresh" size={16}/> {previewingId === selected.serviceOrderId ? 'Checking…' : selected.handoffStatus === 'sent' ? 'Checks saved' : 'Re-check order'}</button>
                  <button type="button" className="button dark" onClick={sendSelected} disabled={sendingId === selected.serviceOrderId || !canSend}>
                    <Icon name="send" size={16}/> {selected.handoffStatus === 'sent' ? 'Sent to OPPS' : sendingId === selected.serviceOrderId ? 'Sending…' : blockerItems.length ? 'Fix issues first' : 'Send to OPPS'}
                  </button>
                </div>

              <div className="handoff-status-row">
                <StatusPill label={HANDOFF_LABELS[selected.handoffStatus] || selected.handoffStatus} tone={toneForStatus(selected.handoffStatus)} />
                <StatusPill label={paymentLabel(selected.paymentStatus)} tone={toneForStatus(selected.paymentStatus)} />
                {preview ? <StatusPill label={fileCount ? `${fileCount} file${fileCount === 1 ? '' : 's'} received` : 'No file attached'} tone={fileCount ? 'good' : 'neutral'} /> : null}
              </div>

              {blockerItems.length > 0 && <MessageList title="Needs attention" icon="alertCircle" tone="bad" items={blockerItems} />}
              {warningItems.length > 0 && <details className="order-warning"><summary>{warningItems.length} staff note{warningItems.length === 1 ? '' : 's'} · review before handoff</summary><MessageList title="Staff notes" icon="alertCircle" tone="warn" items={warningItems} /></details>}
              <details className="order-more" key={selected.serviceOrderId}><summary>Order details</summary>
              <div className="handoff-detail-grid">
                <DetailRow label="Order state" value={SERVICE_STATUS_LABELS[selected.serviceStatus] || selected.serviceStatus} />
                <DetailRow label="Last checked" value={selected.lastPreviewedAt ? dateTime(selected.lastPreviewedAt) : previewingId === selected.serviceOrderId ? 'Checking now…' : 'Checking automatically…'} />
                <DetailRow label="OPPS link" value={selected.oppsOrderId ? 'Created and linked' : 'Not created yet'} />
              </div>

              <div className="handoff-preview-body">
                <div className="handoff-subsection">
                  <div className="handoff-subsection-title"><strong>Job & collection</strong></div>
                  {proposedOppsOrder ? (
                    <>
                      <div className="handoff-detail-grid compact">
                        <DetailRow label="Starting stage" value="Received" />
                        <DetailRow label="Fulfilment" value={fulfilmentDisplay} />
                        {handoffPointArea ? <DetailRow label="Collection area" value={handoffPointArea} /> : null}
                      </div>
                      <div className="handoff-lines">
                        <div className="handoff-lines-header"><strong>Items</strong><small>{proposedLines.length} line(s)</small></div>
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
                    </>
                  ) : (
                    <div className="handoff-empty small">{previewingId === selected.serviceOrderId ? 'Checking the order now…' : 'The order preview will load automatically.'}</div>
                  )}
                </div>

                {selected.oppsOrderId && <div className="handoff-subsection handoff-after-send">
                  <div className="handoff-subsection-title"><Icon name="external" size={16}/><strong>{selected.oppsOrderId ? 'Continue in OPPS' : 'After handoff'}</strong></div>
                  <div className="handoff-follow-up-actions">
                    <button type="button" onClick={() => window.open(buildOppsAppUrl(selected.oppsOrderId || ''), '_blank', 'noopener,noreferrer')}><Icon name="external" size={16}/> Open OPPS</button>
                    <button type="button" onClick={copyOppsId} disabled={!selected.oppsOrderId}><Icon name="copy" size={16}/> Copy order ID</button>
                  </div>
                </div>}

                <details className="handoff-technical-details">
                  <summary>Technical details</summary>
                  <div className="handoff-detail-grid compact">
                    <DetailRow label="Quick Solution ID" value={selected.serviceOrderId} />
                    <DetailRow label="OPPS order ID" value={selected.oppsOrderId || '—'} />
                    <DetailRow label="Mapping version" value={selected.mappingVersion || preview?.mappingVersion || '—'} />
                    <DetailRow label="Sent at" value={selected.sentAt ? fullDateTime(selected.sentAt) : '—'} />
                  </div>
                </details>
              </div>
              </details>
            </>
          ) : <div className="handoff-empty large">{loadState === 'loading' ? 'Loading the order…' : notificationOrderId ? 'The notified order could not be found in this account.' : 'Select a Quick Solution order to review the OPPS handoff.'}</div>}
        </section>
      </div>
    </section>
  )
}



