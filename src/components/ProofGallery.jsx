import React from 'react'
import Icon from './Icon.jsx'

const proofItems = [
  {
    image: '/qs11/proof-product-branding.webp',
    kicker: 'Product branding',
    title: 'Turn everyday products into brands.',
    copy: 'Labels and product branding designed to make local businesses look considered and retail-ready.'
  },
  {
    image: '/qs11/proof-packaging-range.webp',
    kicker: 'Labels & packaging',
    title: 'Brand the things customers take home.',
    copy: 'Packaging, stickers and labels for food, household, beauty and growing product businesses.'
  },
  {
    image: '/qs11/proof-event-branding.webp',
    kicker: 'Events & outdoor',
    title: 'Show up properly in the real world.',
    copy: 'Gazebos, displays, banners and event branding built for visibility beyond the screen.'
  }
]

export default function ProofGallery() {
  return (
    <section className="qs10-proof-section shell section" aria-labelledby="qs10-proof-title">
      <div className="qs10-proof-heading">
        <div>
          <span className="eyebrow">Made for real life</span>
          <h2 id="qs10-proof-title">Real businesses.<br/>Real events.<br/>Real products.</h2>
        </div>
        <p>Quick Solution brings Joint X production closer to the community — from one-off jobs to complete business branding.</p>
      </div>

      <div className="qs10-proof-grid">
        {proofItems.map((item) => (
          <article className="qs10-proof-card" key={item.title}>
            <div className="qs10-proof-media">
              <img src={item.image} alt="" loading="lazy"/>
            </div>
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
        <a className="button ghost" href="#quick-points">
          Explore collection options <Icon name="arrowRight" size={16}/>
        </a>
      </div>
    </section>
  )
}


