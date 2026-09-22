import React from 'react'
import Icon from './Icon.jsx'

// QS-18 — compact WhatsApp help CTA. Same number/format already used
// everywhere else in this app (App.jsx, GuidedOrder.jsx,
// ProductConfigurator.jsx, TrackOrder.jsx, PaymentReturn.jsx,
// ComingSoonRail.jsx, buildShareLinks() in productContent.js) - not a
// new contact channel.
export default function HelpCta() {
  const whatsappText = encodeURIComponent('Hi Quick Solution, I need help figuring out what I need.')
  return (
    <section className="qs18-help-cta shell">
      <div className="qs18-help-cta-copy">
        <span className="eyebrow">Not sure what you need?</span>
        <strong>Message us on WhatsApp and we will help you figure it out.</strong>
      </div>
      <a className="button dark" href={`https://wa.me/27754534646?text=${whatsappText}`} target="_blank" rel="noreferrer">
        <Icon name="message" size={17}/> WhatsApp us
      </a>
    </section>
  )
}
