import React, { useEffect, useMemo, useState } from 'react'
import './our-work.css'
import { loadPublishedPortfolio } from '../lib/portfolioApi.js'
import { portfolioProjectPath, resolvePortfolioPath, visiblePortfolioProjects } from '../lib/portfolio.js'

const categoryLabels = {
  'printing-documents': 'Printing & Documents',
  'apparel-branding': 'Apparel & Branding',
  'stickers-labels': 'Stickers & Labels',
  'signage-displays': 'Signage & Displays',
  'business-branding': 'Business Branding',
  'photography-media': 'Photography & Media',
  'websites-digital': 'Websites & Digital',
  'custom-projects': 'Custom Projects'
}
const categoryLabel = slug => categoryLabels[slug] || slug.replace(/-/g, ' ').replace(/\b\w/g, char => char.toUpperCase())

export default function OurWorkPage() {
  const route = resolvePortfolioPath(window.location.pathname)
  const [projects, setProjects] = useState([])
  const [status, setStatus] = useState('loading')
  const [category, setCategory] = useState('')
  const [retryCount, setRetryCount] = useState(0)
  useEffect(() => {
    let active = true
    loadPublishedPortfolio().then(items => {
      if (active) { setProjects(items); setStatus('ready') }
    }).catch(() => { if (active) setStatus('error') })
    return () => { active = false }
  }, [retryCount])
  const categories = useMemo(() => [...new Set(projects.flatMap(p => p.categorySlugs || []))].sort(), [projects])
  const visible = visiblePortfolioProjects(projects, { categorySlug: category || null })
  const project = route?.page === 'project' ? visiblePortfolioProjects(projects).find(p => p.slug === route.slug) : null
  return <div className="shell section qs-portfolio-page">
    <a href="/" className="text-button">← Quick Solution Café</a>
    <header style={{ margin: '2rem 0' }}>
      <span className="eyebrow">Our Work</span>
      <h1>{route?.page === 'project' && project ? project.title : 'Made for real life.'}</h1>
      <p>{route?.page === 'project' && project ? project.summary : 'A closer look at the printing, branding and creative work we produce.'}</p>
    </header>
    {status === 'loading' && <p role="status">Loading our work…</p>}
    {status === 'error' && <div role="alert"><p>Our work is temporarily unavailable. Please try again later.</p><button className="button ghost" type="button" onClick={() => { setStatus('loading'); setRetryCount(count => count + 1) }}>Try again</button></div>}
    {status === 'ready' && route?.page === 'project' && !project && <p>This project is not available.</p>}
    {status === 'ready' && project && <>
      <p>{project.description}</p>
      <div className="qs-portfolio-detail-grid">
        {(project.media || []).map((item, i) => <figure className="qs-portfolio-detail-photo" key={item.id || i}>
          {item.url && <img src={item.url} alt={item.altText || project.title} loading="lazy"/>}
        </figure>)}
      </div>
      <a className="button ghost" href="/our-work">View all our work</a>
    </>}
    {status === 'ready' && route?.page === 'listing' && <>
      {categories.length > 0 && <div aria-label="Filter by offering" className="qs-portfolio-filters">
        <button type="button" className={category ? "qs-portfolio-filter" : "qs-portfolio-filter active"} aria-pressed={!category} onClick={() => setCategory('')}>All</button>
        {categories.map(slug => <button key={slug} type="button" className={category === slug ? "qs-portfolio-filter active" : "qs-portfolio-filter"} aria-pressed={category === slug} onClick={() => setCategory(slug)}>{categoryLabel(slug)}</button>)}
      </div>}
      {!visible.length && <p>No published projects in this collection yet. Check back soon.</p>}
      <div className="qs10-proof-grid">
        {visible.map(item => <article className="qs10-proof-card" key={item.id || item.slug}>
          <a href={portfolioProjectPath(item.slug)}>
            {item.coverUrl && <div className="qs10-proof-media"><img src={item.coverUrl} alt={item.coverAlt || item.title} loading="lazy"/></div>}
            <div className="qs10-proof-copy"><span>{(item.categorySlugs || []).map(categoryLabel).join(' · ')}</span><strong>{item.title}</strong><p>{item.summary}</p></div>
          </a>
        </article>)}
      </div>
    </>}
  </div>
}
