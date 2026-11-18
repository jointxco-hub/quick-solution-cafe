import React from 'react'
import Icon from './Icon.jsx'

const services = [
  { id: 'print', icon: 'document', title: 'Print documents', detail: 'CVs, forms & A4 documents', action: 'documents' },
  { id: 'apparel', icon: 'shirt', title: 'Clothing & merch', detail: 'T-shirts, hoodies & caps', filter: 'Apparel' },
  { id: 'branding', icon: 'store', title: 'Business branding', detail: 'Stickers, signs & banners', filter: 'Signs & Advertising' },
  { id: 'events', icon: 'flag', title: 'Events & displays', detail: 'Banners, flags & displays', filter: 'Events' }
]

export default function HomeServiceCategories({ onDocuments, onCategory }) {
  return <section className="qs23-services shell section" aria-labelledby="qs23-services-title">
    <header className="qs23-services-heading">
      <div><span className="eyebrow">What can we help with?</span><h2 id="qs23-services-title">Find what you need.</h2></div>
      <p>Choose a service to get started. You can always ask for help.</p>
    </header>
    <div className="qs23-services-grid">
      {services.map(service => <button type="button" className="qs23-service-card" key={service.id}
        onClick={() => service.action === 'documents' ? onDocuments() : onCategory(service.filter)}>
        <span className="qs23-service-icon"><Icon name={service.icon} size={23}/></span>
        <strong>{service.title}</strong>
        <small>{service.detail}</small>
        <span className="qs23-service-arrow" aria-hidden="true"><Icon name="arrowRight" size={18}/></span>
      </button>)}
    </div>
  </section>
}
