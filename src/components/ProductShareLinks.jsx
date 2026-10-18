import React, { useState } from 'react'
import Icon from './Icon.jsx'

export default function ProductShareLinks({ links, productName, hasArtwork = true }) {
  const [section, setSection] = useState('')
  const [status, setStatus] = useState('')
  const url = links.productPageUrl + (section ? `#${section}` : '')
  const whatsappShareUrl = `https://wa.me/?text=${encodeURIComponent(`${productName} — ${url}`)}`
  const copy = async () => {
    setStatus('Copying link…')
    try {
      await navigator.clipboard.writeText(url)
      setStatus('Link copied')
    } catch {
      setStatus('Select and copy the link below')
    }
  }
  return <div className="product-share-links">
    <label className="product-share-target"><span className="product-share-caption">Share</span><span className="product-share-select-wrap"><select aria-label="Choose the product section to share" value={section} onChange={(event) => { setSection(event.target.value); setStatus('') }}>
      <option value="">Product overview</option>
      <option value="configure">Pricing & ordering</option>
      <option value="delivery">Collection & delivery</option>
      <option value="payment">Payment</option>
      <option value="returns">Returns & order issues</option>
      {hasArtwork && <option value="artwork">Artwork</option>}
    </select><Icon name="chevronDown" size={15}/></span></label>
    <button type="button" className="button ghost product-share-copy" onClick={copy}>Copy link</button>
    <a href={whatsappShareUrl} target="_blank" rel="noreferrer" className="product-hub-share-primary">
      <Icon name="send" size={16}/> Share on WhatsApp
    </a>
    <span role="status" className="product-share-status">{status}</span>
    {status === 'Select and copy the link below' && <input aria-label="Shareable link" readOnly value={url} onFocus={(event) => event.target.select()}/>}
  </div>
}
