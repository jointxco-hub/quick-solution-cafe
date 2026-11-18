import React, { useEffect, useState } from 'react'
import { loadQsPublishedWork } from '../lib/qsPublishedWork.js'

// A single published project record can serve X LAB, X1 and QS. QS reads
// the strictly projected public view and never uses admin credentials.
function ProjectMedia({ project }) {
  const media = project.media
  if (!media) return <div className="qs-work-media"><div className="qs-work-placeholder"><strong>{project.title}</strong><span>Project media coming soon</span></div></div>

  if (media.kind === 'video') {
    return <div className="qs-work-media">
      <video poster={media.poster || undefined} preload="none" controls playsInline aria-label={media.alt || project.title}>
        <source src={media.src} type={/\.webm(?:[?#]|$)/i.test(media.src) ? 'video/webm' : 'video/mp4'} />
      </video>
    </div>
  }
  return <div className="qs-work-media">
    <img src={media.src} loading="lazy" decoding="async" alt={media.alt || project.title} />
    {media.externalVideo && <a href={media.externalVideo} target="_blank" rel="noopener noreferrer" className="qs-work-watch" aria-label={`Watch video of ${project.title}`}>Watch video ↗</a>}
  </div>
}

export default function FeaturedWork({ site = 'qs' }) {
  const [projects, setProjects] = useState([])
  useEffect(() => {
    if (site !== 'qs') return
    const controller = new AbortController()
    loadQsPublishedWork({ signal: controller.signal })
      .then(data => setProjects(data))
      .catch(error => {
        if (!controller.signal.aborted) {
          console.warn('QS public projects unavailable', error)
          setProjects([])
        }
      })
    return () => controller.abort()
  }, [site])
  // No speculative company names or misleading placeholder work on the live site.
  if (site !== 'qs' || projects.length === 0) return null
  return <section className="qs-work-section shell section" aria-labelledby="qs-work-title">
    <header className="qs-work-heading">
      <div><span className="eyebrow">Selected Joint X production work</span><h2 id="qs-work-title">Made here.<br/>Seen out there.</h2></div>
      <p>Printing, apparel and branding projects completed for our clients.</p>
    </header>
    <div className="qs-work-grid">
      {projects.map(project => <article className="qs-work-card" key={project.id}>
        <ProjectMedia project={project} />
        <div className="qs-work-copy">
          <span>{project.category}</span>
          <h3>{project.title}</h3>
          <p>{project.subtitle}</p>
        </div>
      </article>)}
    </div>
  </section>
}
