import React, { useEffect, useMemo, useState } from 'react'
import { loadPublishedPortfolio } from '../lib/portfolioApi.js'
import { portfolioProjectPath, resolvePortfolioPath, visiblePortfolioProjects } from '../lib/portfolio.js'

export default function OurWorkPage() {
  const route = resolvePortfolioPath(window.location.pathname)
  const [projects, setProjects] = useState([])
  const [status, setStatus] = useState('loading')
  const [category, setCategory] = useState('')
  useEffect(() => {
    let active = true
    loadPublishedPortfolio().then(items => {
      if (active) { setProjects(items); setStatus('ready') }
    }).catch(() => { if (active) setStatus('error') })
    return () => { active = false }
  }, [])
  const categories = useMemo(() => [...new Set(projects.flatMap(p => p.categorySlugs || []))].sort(), [projects])
  const visible = visiblePortfolioProjects(projects, { categorySlug: category || null })
  const project = route?.page === 'project' ? visiblePortfolioProjects(projects).find(p => p.slug === route.slug) : null
  return <div className="shell section" style={{ minHeight: '65vh' }}>
    <a href="/" className="text-button">← Quick Solution Café</a>
    <header style={{ margin: '2rem 0' }}>
      <span className="eyebrow">Our Work</span>
      <h1>{route?.page === 'project' && project ? project.title : 'Made for real life.'}</h1>
      <p>{route?.page === 'project' && project ? project.summary : 'A closer look at the printing, branding and creative work we produce.'}</p>
    </header>
    {status === 'loading' && <p role="status">Loading our work…</p>}
    {status === 'error' && <p role="alert">Our work is temporarily unavailable. Please try again later.</p>}
    {status === 'ready' && route?.page === 'project' && !project && <p>This project is not available.</p>}
    {status === 'ready' && project && <>
      <p>{project.description}</p>
      <div className="qs10-proof-grid">
        {(project.media || []).map((item, i) => <figure className="qs10-proof-card" key={item.id || i}>
          <img src={item.url} alt={item.altText || project.title} loading="lazy" style={{ width: '100%', height: 'auto' }}/>
        </figure>)}
      </div>
      <a className="button ghost" href="/our-work">View all our work</a>
    </>}
    {status === 'ready' && route?.page === 'listing' && <>
      {categories.length > 0 && <div aria-label="Filter by offering" style={{ display: 'flex', flexWrap: 'wrap', gap: '.75rem', marginBottom: '2rem' }}>
        <button type="button" className="button ghost" aria-pressed={!category} onClick={() => setCategory('')}>All</button>
        {categories.map(slug => <button key={slug} type="button" className="button ghost" aria-pressed={category === slug} onClick={() => setCategory(slug)}>{slug.replace(/-/g, ' ')}</button>)}
      </div>}
      {!visible.length && <p>No published projects in this collection yet. Check back soon.</p>}
      <div className="qs10-proof-grid">
        {visible.map(item => <article className="qs10-proof-card" key={item.id || item.slug}>
          <a href={portfolioProjectPath(item.slug)}>
            {item.coverUrl && <div className="qs10-proof-media"><img src={item.coverUrl} alt={item.coverAlt || item.title} loading="lazy"/></div>}
            <div className="qs10-proof-copy"><span>{(item.categorySlugs || []).join(' · ')}</span><strong>{item.title}</strong><p>{item.summary}</p></div>
          </a>
        </article>)}
      </div>
    </>}
  </div>
}
