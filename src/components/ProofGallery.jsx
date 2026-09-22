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
    // QS-21.1: upgraded to a real branded photo (visually inspected
    // against its alternative - see the QS-21.1 media report) - this one
    // has the gazebo larger/more central, both flags fully visible and
    // only one chair, versus the busier 6-element alternative. Square
    // source (1200x1200) into this card's landscape frame - a plain
    // center crop would cut off the flag tops/gazebo peak (the exact
    // thing this image was chosen for), so imagePosition shifts the
    // object-fit:cover crop window upward. Copy/layout unchanged.
    image: '/qs21/events-package-b.webp',
    imagePosition: 'center 25%',
    kicker: 'Events & outdoor',
    title: 'Show up properly in the real world.',
    copy: 'Gazebos, displays, banners and event branding built for visibility beyond the screen.'
  }
]

// QS-18A: onExploreCollection is optional - when App.jsx passes it (the
// Home page, where #quick-points does not exist in the DOM), the button
// switches to Shop and scrolls to Quick Points once it mounts instead of
// a plain #quick-points anchor that would silently do nothing. Any other
// caller that doesn't pass it keeps the original anchor behavior
// unchanged - smallest possible addition, not a redesign.
export default function ProofGallery({ onExploreCollection }) {
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
              <img src={item.image} alt="" loading="lazy" style={item.imagePosition ? { objectPosition: item.imagePosition } : undefined}/>
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
        {onExploreCollection ? (
          <button type="button" className="button ghost" onClick={onExploreCollection}>
            Explore collection options <Icon name="arrowRight" size={16}/>
          </button>
        ) : (
          <a className="button ghost" href="#quick-points">
            Explore collection options <Icon name="arrowRight" size={16}/>
          </a>
        )}
      </div>
    </section>
  )
}


