import React, { useEffect, useState } from 'react'
import { getQuickJobState, updateQuickJob } from '../lib/supabaseApi.js'

export default function QuickJobActions({ orderId, onChanged }) {
  const [job, setJob] = useState(null)
  const [busy, setBusy] = useState(false)
  const [error, setError] = useState('')
  const [confirm, setConfirm] = useState(false)
  const [refresh, setRefresh] = useState(0)
  useEffect(() => {
    let current = true
    getQuickJobState(orderId).then(data => { if (current) { setJob(data); setError('') } })
      .catch(() => { if (current) setError('Could not check local job actions. Try again.') })
    return () => { current = false }
  }, [orderId, refresh])

  const act = async () => {
    if (busy || !job?.nextAction) return
    setBusy(true); setError('')
    try {
      setJob(await updateQuickJob(orderId, job.nextAction))
      setConfirm(false)
      onChanged()
    } catch (e) { setError(e.message || 'Could not update this job.'); setConfirm(false); setRefresh(n => n + 1) }
    finally { setBusy(false) }
  }

  if (!job) return error ? <div className="quick-job-actions"><p role="alert">{error}</p><button type="button" onClick={() => setRefresh(n => n + 1)}>Retry</button></div> : null
  if (!job.eligible) return null
  return <section className="quick-job-actions" aria-label="Handle at Café">
    <strong>{job.status === 'completed' ? 'Collected at Café' : 'Handle at Café'}</strong>
    {job.nextAction === 'ready' && <p>Finish printing, scanning or laminating, then mark this order ready.</p>}
    {job.nextAction === 'collected' && <p>{job.canCollect ? 'Payment settled. Confirm when the customer receives the finished job.' : `Ready for collection. Settle payment before handover${Number(job.outstanding) > 0 ? ` · R ${Number(job.outstanding).toFixed(2)} outstanding` : '.'}`}</p>}
    {error && <p role="alert">{error}</p>}
    {job.nextAction && (!confirm ? <button type="button" className="order-acknowledge" disabled={busy || (job.nextAction === 'collected' && !job.canCollect)} onClick={() => setConfirm(true)}>{job.nextAction === 'ready' ? 'Mark ready' : 'Mark collected'}</button> : <div>
      <p>{job.nextAction === 'ready' ? 'Is the finished job ready for the customer?' : 'Has the customer received the finished job?'}</p>
      <button type="button" className="order-acknowledge" disabled={busy} onClick={act}>{busy ? 'Saving…' : job.nextAction === 'ready' ? 'Yes, mark ready' : 'Yes, mark collected'}</button>
      <button type="button" disabled={busy} onClick={() => setConfirm(false)}>Not yet</button>
    </div>)}
    {job.nextAction === 'collected' && !job.canCollect && <button type="button" onClick={() => setRefresh(n => n + 1)}>Re-check payment</button>}
  </section>
}
