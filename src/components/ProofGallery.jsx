import React from 'react'
import Icon from './Icon.jsx'
import ProductScene from './ProductScene.jsx'

const proofItems = [
  { id: 'a4-print', kicker: 'Everyday print', title: 'Documents, CVs & school work', copy: 'Upload before you arrive and collect when it is ready.' },
  { id: 'business-cards', kicker: 'Business essentials', title: 'Branding that feels considered', copy: 'Cards, labels, signs and practical brand pieces for local businesses.' },
  { id: 'printed-tshirt', kicker: 'Apparel & events', title: 'Merch, uniforms & event pieces', copy: 'From one shirt to a growing team, configured without print jargon.' }
]

export default function ProofGallery() {
  return (
    <section className="qs10-proof-section shell section" aria-labelledby="qs10-proof-title">
      <div className="qs10-proof-heading">
        <div>
          <span className="eyebrow">Made for real life</span>
          <h2 id="qs10-proof-title">Real businesses.<br/>Real events.<br/>Everyday needs.</h2>
        </div>
        <p>Quick Solution brings Joint X production closer to the community — from a single document to complete business branding.</p>
      </div>

      <div className="qs10-proof-grid">
        {proofItems.map((item) => (
          <article className="qs10-proof-card" key={item.id}>
            <div className="qs10-proof-media" aria-hidden="true"><ProductScene productId={item.id}/></div>
            <div className="qs10-proof-copy">
              <span>{item.kicker}</span>
              <strong>{item.title}</strong>
              <p>{item.copy}</p>
            </div>
          </article>
        ))}
      </div>

      <div className="qs10-local-band">
        <div className="qs10-local-icon"><Icon name="pin" size={21}/></div>
        <div>
          <span className="eyebrow">Built for the neighbourhood</span>
          <strong>Order online. Collect locally.</strong>
          <p>Start from home, upload your files, then collect from Quick Solution or a nearby Quick Point.</p>
        </div>
        <a className="button ghost" href="#quick-points">Explore collection options <Icon name="arrowRight" size={16}/></a>
      </div>
    </section>
  )
}
