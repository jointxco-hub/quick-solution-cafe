import React from 'react'
import { getProjectsForSite } from '../data/workProjects.js'

// Images are contained in a responsive project frame; the source may be
// square, vertical, horizontal or video without requiring a layout rewrite.
function ProjectMedia({ project }) {
  const media = project.media?.[0]
  if (!media?.src) {
    return <div className="qs-work-media" aria-label={`Placeholder for ${project.title} media`}>
      <div className="qs-work-placeholder"><strong>{project.title}</strong><span>Real project media coming soon</span></div>
    </div>
  }
  const position = media.focalPoint || 'center center'
  return <div className="qs-work-media">
    {media.kind === 'video'
      ? <video poster={media.poster || undefined} preload="none" controls playsInline style={{ objectPosition: position }} aria-label={media.alt || project.title}>
          <source src={media.src} type={media.mimeType || 'video/mp4'}/>
        </video>
      : <img src={media.src} loading="lazy" decoding="async" alt={media.alt || project.title} style={{ objectPosition: position }}/>}
  </div>
}

export default function FeaturedWork({ site = 'qs' }) {
  const projects = getProjectsForSite(site)
  if (!projects.length) return null
  return <section className="qs-work-section shell section" aria-labelledby="qs-work-title">
    <header className="qs-work-heading">
      <div><span className="eyebrow">Selected Joint X production work</span><h2 id="qs-work-title">Made here.<br/>Seen out there.</h2></div>
      <p>From neighbourhood businesses to the stage — a few of the projects we've helped bring to life.</p>
    </header>
    <div className="qs-work-grid">
      {projects.map(project => <article className="qs-work-card" key={project.id}>
        <ProjectMedia project={project}/>
        <div className="qs-work-copy">
          <span>{project.category}{project.year ? ` · ${project.year}` : ''}</span>
          <h3>{project.title}</h3>
          <p>{project.subtitle}</p>
        </div>
      </article>)}
    </div>
    <p className="qs-work-note">Project images and videos will be added as they are prepared. Event appearances are not claims of event sponsorship or endorsement.</p>
  </section>
}
