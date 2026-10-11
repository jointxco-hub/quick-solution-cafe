export async function prepareOrderDownload({ orderId, attachment, signFile, signal, fetchFile = fetch }) {
  const signed = await signFile(orderId, attachment.id, 'download')
  signal.throwIfAborted()
  const response = await fetchFile(signed.url, { signal, cache: 'no-store' })
  if (!response.ok) throw new Error('Could not download the file. Please try again.')
  const blob = await response.blob()
  signal.throwIfAborted()
  const name = (attachment.name || 'document').split(/[\\/]/).pop() || 'document'
  return new File([blob], name, { type: attachment.mime || blob.type || 'application/octet-stream' })
}

// Call directly from Save file's click: sharing must begin before any await.
export function saveOrderDownload(prepared, { nav = navigator, doc = document } = {}) {
  const files = [prepared.file]
  if (nav.maxTouchPoints > 0 && nav.share && nav.canShare?.({ files })) {
    return nav.share({ files }).then(() => 'shared')
  }
  const link = doc.createElement('a')
  link.href = prepared.url
  link.download = prepared.file.name
  doc.body.appendChild(link)
  link.click()
  link.remove()
  return Promise.resolve('download')
}
