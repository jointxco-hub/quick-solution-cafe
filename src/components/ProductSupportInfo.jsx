import React, { useState } from 'react'
import Icon from './Icon.jsx'
import PaymentTrust from './PaymentTrust.jsx'
import { DELIVERY_INFO, RETURNS_POLICY_TEXT, WHATSAPP_DISPLAY, buildWhatsappUrl } from '../lib/businessInfo.js'

// QS-21.5 section 14 — Product Detail's compact supporting-info block:
// Collection & delivery / Payment / Returns & order issues / Artwork.
// Mobile: accordion, only one panel open at a time (same
// resolveRelatedDisclosureState-style toggle pattern as the related-
// product disclosure, QS-21.1 - kept local since it is UI-only state,
// never page/history). Desktop: forced-open compact 2-column block (see
// qs21-5-mobile-shell.css) - "do not add four giant cards that lengthen
// the PDP again," per the brief.
//
// artworkHelp is passed in rather than recomputed here - ProductHub.jsx
// already resolves it once via resolveArtworkGuidance() (productContent.js),
// single source, not a second copy.
const SECTIONS = ['delivery', 'payment', 'returns', 'artwork']

export default function ProductSupportInfo({ artworkHelp }) {
  const [openId, setOpenId] = useState('delivery')

  const toggle = (id) => setOpenId((current) => (current === id ? null : id))

  const returnsWhatsapp = buildWhatsappUrl(encodeURIComponent('Hi Quick Solution, I have a question about returns or an order issue.'))

  return (
    <div className="qs21-support-info">
      <div className={`qs21-support-row${openId === 'delivery' ? ' open' : ''}`}>
        <button type="button" className="qs21-support-toggle" aria-expanded={openId === 'delivery'} onClick={() => toggle('delivery')}>
          <span><Icon name="truck" size={16}/> Collection &amp; delivery</span>
          <Icon name={openId === 'delivery' ? 'arrowUpRight' : 'arrowRight'} size={14}/>
        </button>
        <div className="qs21-support-panel">
          <ul className="qs21-support-delivery-list">
            {DELIVERY_INFO.map((item) => (
              <li key={item.id}>
                <Icon name={item.icon} size={15}/>
                <span><strong>{item.title}</strong><small>{item.helper}</small></span>
              </li>
            ))}
          </ul>
        </div>
      </div>

      <div className={`qs21-support-row${openId === 'payment' ? ' open' : ''}`}>
        <button type="button" className="qs21-support-toggle" aria-expanded={openId === 'payment'} onClick={() => toggle('payment')}>
          <span><Icon name="checkCircle" size={16}/> Payment</span>
          <Icon name={openId === 'payment' ? 'arrowUpRight' : 'arrowRight'} size={14}/>
        </button>
        <div className="qs21-support-panel">
          <PaymentTrust/>
        </div>
      </div>

      <div className={`qs21-support-row${openId === 'returns' ? ' open' : ''}`}>
        <button type="button" className="qs21-support-toggle" aria-expanded={openId === 'returns'} onClick={() => toggle('returns')}>
          <span><Icon name="alertCircle" size={16}/> Returns &amp; order issues</span>
          <Icon name={openId === 'returns' ? 'arrowUpRight' : 'arrowRight'} size={14}/>
        </button>
        <div className="qs21-support-panel">
          <p className="qs21-support-returns-copy">{RETURNS_POLICY_TEXT}</p>
          <a className="qs21-support-returns-link" href={returnsWhatsapp} target="_blank" rel="noreferrer">
            <Icon name="message" size={14}/> WhatsApp {WHATSAPP_DISPLAY}
          </a>
        </div>
      </div>

      {artworkHelp && (
        <div className={`qs21-support-row${openId === 'artwork' ? ' open' : ''}`}>
          <button type="button" className="qs21-support-toggle" aria-expanded={openId === 'artwork'} onClick={() => toggle('artwork')}>
            <span><Icon name="upload" size={16}/> Artwork / production notes</span>
            <Icon name={openId === 'artwork' ? 'arrowUpRight' : 'arrowRight'} size={14}/>
          </button>
          <div className="qs21-support-panel">
            <p className="qs21-support-returns-copy">{artworkHelp}</p>
          </div>
        </div>
      )}
    </div>
  )
}

export { SECTIONS as QS21_SUPPORT_SECTION_IDS }
