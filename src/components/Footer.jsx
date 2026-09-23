import React from 'react'
import Icon from './Icon.jsx'
import PaymentTrust from './PaymentTrust.jsx'
import {
  BUSINESS_NAME,
  BUSINESS_TAGLINE,
  BUSINESS_ADDRESS_LINES,
  LOCATION_DISPLAY_NAME,
  WHATSAPP_DISPLAY,
  buildWhatsappUrl,
  DELIVERY_INFO
} from '../lib/businessInfo.js'

// QS-21.5 — the real production footer, replacing the single-line
// status footer that used to expose "Location 001" / "Live staging
// catalogue" / "Local fallback" / a "Product Admin" link directly to
// customers. Every internal link reuses the SAME navigation functions
// App.jsx already passes to Header (goHome/goShop/goToQuickPoints/
// openDocumentPrinting) - no new routing, no React Router. Track order
// stays a plain `href="/track"` anchor, matching how Header.jsx and
// every other place in the app already link to it (a real page load,
// not client-side page state - confirmed via audit).
//
// "Collection & delivery" and "Returns & order issues" have no
// dedicated page/section to deep-link to outside Product Detail's own
// accordion (see ProductSupportInfo.jsx) - Collection & delivery reuses
// onGoQuickPoints (Home's real Nearby Collection/Quick Points band,
// which genuinely is the collection-points content), and Returns/
// Artwork help open WhatsApp with a pre-filled, honest message, since
// that is the actual real-world path a customer takes for either today
// (confirmed via audit: no /returns or /terms route exists anywhere).
export default function Footer({ onGoHome, onGoShop, onGoQuickPoints, onSendDocuments }) {
  const returnsWhatsapp = buildWhatsappUrl(encodeURIComponent('Hi Quick Solution, I have a question about returns or an order issue.'))
  const artworkWhatsapp = buildWhatsappUrl(encodeURIComponent('Hi Quick Solution, I need help with my artwork or design file.'))

  return (
    <footer className="qs21-footer">
      <div className="shell qs21-footer-grid">
        <div className="qs21-footer-col qs21-footer-brand">
          <div className="brand">
            <img className="brand-mark-image" src="/jointx-mark.png" alt=""/>
            <span><strong>{BUSINESS_NAME}</strong><small>{BUSINESS_TAGLINE}</small></span>
          </div>
          <p>Printing, branding and everyday solutions for Riverside View and nearby communities.</p>
        </div>

        {/* Contact/location stays plainly visible on every viewport -
            never collapsed behind an accordion, per the brief. */}
        <div className="qs21-footer-col">
          <h4>Contact</h4>
          <a className="qs21-footer-whatsapp" href={buildWhatsappUrl()} target="_blank" rel="noreferrer">
            <Icon name="message" size={15}/> {WHATSAPP_DISPLAY}
          </a>
          <address className="qs21-footer-address">
            <strong>{LOCATION_DISPLAY_NAME}</strong>
            {BUSINESS_ADDRESS_LINES.map((line) => <span key={line}>{line}</span>)}
          </address>
        </div>

        <div className="qs21-footer-col">
          <h4>Quick links</h4>
          <ul className="qs21-footer-links">
            <li><button type="button" onClick={onGoHome}>Home</button></li>
            <li><button type="button" onClick={onGoShop}>Shop</button></li>
            <li><button type="button" onClick={onGoQuickPoints}>Quick Points</button></li>
            <li><a href="/track">Track order</a></li>
            <li><button type="button" onClick={onSendDocuments}>Send documents</button></li>
          </ul>

          {/* Secondary groups - a native <details> accordion on mobile
              (zero extra JS state needed), forced fully open on desktop
              via CSS (qs21-5-shell.css) - "accordions are acceptable for
              secondary link groups" per the brief. */}
          <details className="qs21-footer-group" open>
            <summary>Help</summary>
            <ul className="qs21-footer-links">
              <li><a href={buildWhatsappUrl()} target="_blank" rel="noreferrer">WhatsApp us</a></li>
              <li><button type="button" onClick={onGoQuickPoints}>Collection &amp; delivery</button></li>
              <li><a href={artworkWhatsapp} target="_blank" rel="noreferrer">Artwork help</a></li>
              <li><a href={returnsWhatsapp} target="_blank" rel="noreferrer">Returns &amp; order issues</a></li>
            </ul>
          </details>
        </div>

        <div className="qs21-footer-col">
          <details className="qs21-footer-group" open>
            <summary>Fulfilment</summary>
            <ul className="qs21-footer-plain">
              {DELIVERY_INFO.map((item) => <li key={item.id}>{item.title}</li>)}
            </ul>
          </details>

          <details className="qs21-footer-group" open>
            <summary>Payment</summary>
            <PaymentTrust compact/>
          </details>
        </div>
      </div>

      <div className="shell qs21-footer-bottom">
        <span>© 2026 Joint X Quick Solution Café</span>
        <span>Built on XOS</span>
      </div>
    </footer>
  )
}
