import React, { useState } from 'react'

export default function ProductShareLinks({ links }) {
  const [section, setSection] = useState('')
  const [status, setStatus] = useState('')
  const url = links.productPageUrl + (section ? `#${section}` : '')
  const copy = async () => {
    try {
      await navigator.clipboard.writeText(url)
      setStatus('Link copied')
    } catch {
      setStatus('Select and copy the link below')
    }
  }
  return <div className="product-share-links">
    <label>Link to <select value={section} onChange={(event) => { setSection(event.target.value); setStatus('') }}>
      <option value="">Product overview</option>
      <option value="configure">Pricing & ordering</option>
      <option value="delivery">Collection & delivery</option>
      <option value="payment">Payment</option>
      <option value="returns">Returns & order issues</option>
      <option value="artwork">Artwork</option>
    </select></label>
    <button type="button" className="button ghost" onClick={copy}>Copy link</button>
    <span role="status">{status}</span>
    {status === 'Select and copy the link below' && <input aria-label="Shareable link" readOnly value={url} onFocus={(event) => event.target.select()}/>}
  </div>
}
