import React, { useEffect, useRef, useState } from 'react'
import { getStaffOrderFile } from '../lib/supabaseApi.js'
import { prepareOrderDownload, saveOrderDownload } from './orderDownload.js'

export default function OrderFileDownload({ orderId, attachment }) {
  const [prepared, setPrepared] = useState(null)
  const [busy, setBusy] = useState(false)
  const [message, setMessage] = useState('')
  const [failed, setFailed] = useState(false)
  const lifetime = useRef(null)

  useEffect(() => {
    const task = { controller: new AbortController(), url: null }
    lifetime.current = task
    return () => {
      task.controller.abort()
      if (task.url) URL.revokeObjectURL(task.url)
    }
  }, [])

  const prepare = async () => {
    const task = lifetime.current
    if (busy || !task) return
    setBusy(true); setMessage(''); setFailed(false)
    try {
      const file = await prepareOrderDownload({ orderId, attachment, signFile: getStaffOrderFile, signal: task.controller.signal })
      task.controller.signal.throwIfAborted()
      task.url = URL.createObjectURL(file)
      setPrepared({ file, url: task.url })
      setMessage('File ready. Tap Save file. On iPhone, choose Save to Files in the share sheet.')
    } catch (error) {
      if (!task.controller.signal.aborted) {
        setFailed(true)
        setMessage(error.message || 'Could not prepare the file. Please try again.')
      }
    } finally {
      if (!task.controller.signal.aborted) setBusy(false)
    }
  }

  const save = async () => {
    if (busy || !prepared) return
    setBusy(true); setFailed(false)
    try {
      const result = await saveOrderDownload(prepared)
      if (!lifetime.current.controller.signal.aborted) setMessage(result === 'shared' ? 'Share sheet closed. You can tap Save file again if needed.' : 'Download requested. Check your browser’s downloads.')
    } catch (error) {
      if (!lifetime.current.controller.signal.aborted) {
        setFailed(error.name !== 'AbortError')
        setMessage(error.name === 'AbortError' ? 'File still ready. Tap Save file to try again.' : 'Could not save the file. Tap Save file to try again.')
      }
    } finally {
      if (!lifetime.current.controller.signal.aborted) setBusy(false)
    }
  }

  return <div className="order-file-download">
    <button type="button" disabled={busy} onClick={prepared ? save : prepare}>{busy ? (prepared ? 'Saving…' : 'Preparing…') : prepared ? 'Save file' : 'Download'}</button>
    {message && <small role={failed ? 'alert' : 'status'}>{message}</small>}
  </div>
}
