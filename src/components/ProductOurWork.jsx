import React, { useEffect, useState } from 'react'
import { loadPublishedPortfolio } from '../lib/portfolioApi.js'
import { portfolioProjectPath, visiblePortfolioProjects } from '../lib/portfolio.js'

export default function ProductOurWork({ productKey }) {
  const [projects, setProjects] = useState([])
  useEffect(() => {
    let active = true
    loadPublishedPortfolio().then(items => {
      if (active) setProjects(visiblePortfolioProjects(items, { productKey }).slice(0, 3))
    }).catch(() => { if (active) setProjects([]) })
    return () => { active = false }
  }, [productKey])
  if (!projects.length) return null
  return <section className="section" aria-labelledby="product-our-work-title">
    <div className="qs10-proof-heading"><div><span className="eyebrow">Our Work</span><h2 id="product-our-work-title">See what we've made.</h2></div><a href="/our-work">Explore all work →</a></div>
    <div className="qs10-proof-grid">{projects.map(project => <article className="qs10-proof-card" key={project.id || project.slug}>
      <a href={portfolioProjectPath(project.slug)}>
        {project.coverUrl && <div className="qs10-proof-media"><img src={project.coverUrl} alt={project.coverAlt || project.title} loading="lazy"/></div>}
        <div className="qs10-proof-copy"><strong>{project.title}</strong><p>{project.summary}</p></div>
      </a>
    </article>)}</div>
  </section>
}
