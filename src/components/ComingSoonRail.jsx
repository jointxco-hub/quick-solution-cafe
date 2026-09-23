import React from 'react'
import Icon from './Icon.jsx'
import { buildWhatsappUrl } from '../lib/businessInfo.js'

const comingSoonItems = [
  {
    id: 'flags',
    icon: 'flag',
    name: 'Flags & Promotional Flags',
    copy: 'Feather, teardrop and pole flags for shopfronts and events.'
  },
  {
    id: 'gazebos',
    icon: 'tent',
    name: 'Gazebos & Event Displays',
    copy: 'Branded gazebos and display setups for markets and activations.'
  },
  {
    id: 'signage',
    icon: 'signpost',
    name: 'Signage',
    copy: 'Shop signs, correx boards and wall signage beyond PVC banners.'
  },
  {
    id: 'website',
    icon: 'globe',
    name: 'Website Services',
    copy: 'Websites and landing pages for local businesses.'
  }
]

export default function ComingSoonRail({ liveProductIds = [] }) {
  const whatsappText = encodeURIComponent('Hi Quick Solution, I would like to ask about an upcoming service.')
  // Derived from the live catalogue, not a second hardcoded list: once a
  // product id here is actually published and orderable, it must stop
  // being teased as "coming soon" right alongside its own real product
  // card — showing both at once is confusing and was happening during
  // this feature's rollout (flags/gazebos briefly existed only as local
  // fallback data, appearing here AND as an orderable card).
  const items = comingSoonItems.filter((item) => !liveProductIds.includes(item.id))

  if (items.length === 0) return null

  return (
    <section className="qs14-coming-soon shell section" aria-labelledby="qs14-coming-soon-title">
      <div className="section-heading">
        <div>
          <span className="eyebrow">More on the way</span>
          <h2 id="qs14-coming-soon-title">Coming soon to Quick Solution.</h2>
        </div>
        <p>These are not orderable yet. WhatsApp us if you need one sooner and we will quote it directly.</p>
      </div>
      <div className="qs14-coming-soon-grid">
        {items.map((item) => (
          <div className="qs14-coming-soon-card" key={item.id}>
            <span className="qs14-coming-soon-icon"><Icon name={item.icon} size={22}/></span>
            <div className="qs14-coming-soon-copy">
              <strong>{item.name}</strong>
              <p>{item.copy}</p>
            </div>
            <span className="qs14-coming-soon-badge">Coming soon</span>
          </div>
        ))}
      </div>
      <a className="qs14-coming-soon-link" href={buildWhatsappUrl(whatsappText)} target="_blank" rel="noreferrer">
        <Icon name="message" size={16}/> Ask about one of these on WhatsApp
      </a>
    </section>
  )
}
