import React from 'react'
import Icon from './Icon.jsx'
import { BUSINESS_NAME, BUSINESS_TAGLINE, buildWhatsappUrl } from '../lib/businessInfo.js'

export default function NotFound() {
  const helpUrl = buildWhatsappUrl(encodeURIComponent(
    'Hi Quick Solution, I need help finding a page on your website.'
  ))

  return (
    <main className="qs218-not-found">
      <a className="brand qs218-not-found-brand" href="/" aria-label="Quick Solution home">
        <img className="brand-mark-image" src="/jointx-mark.png" alt=""/>
        <span><strong>{BUSINESS_NAME}</strong><small>{BUSINESS_TAGLINE}</small></span>
      </a>

      <section className="qs218-not-found-card">
        <div className="qs218-not-found-mark" aria-hidden="true">
          <span>404</span>
          <i/>
        </div>
        <span className="eyebrow">Quick Solution</span>
        <h1>Page not found</h1>
        <p>We couldn't find that page. It may have moved, or the link may be out of date.</p>
        <div className="qs218-not-found-actions">
          <a className="button dark" href="/">
            Back to Quick Solution <Icon name="arrowRight" size={16}/>
          </a>
          <a className="button ghost" href="/shop">Browse products</a>
        </div>
        <a className="qs218-not-found-help" href={helpUrl} target="_blank" rel="noreferrer">
          <Icon name="message" size={15}/> Need help? WhatsApp us
        </a>
      </section>
    </main>
  )
}
