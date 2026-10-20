import React, { useEffect, useMemo, useRef, useState } from 'react'
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
const Arrow = ({ direction = 'right' }) => <span aria-hidden="true">{direction === 'left' ? '←' : '→'}</span>

function PortfolioLightbox({ images, initialIndex, title, onClose }) {
  const [index, setIndex] = useState(initialIndex)
  const closeRef = useRef(null)
  const swipeStart = useRef(null)
  const move = amount => setIndex(current => (current + amount + images.length) % images.length)
  useEffect(() => {
    closeRef.current?.focus()
    const previous = document.body.style.overflow
    document.body.style.overflow = 'hidden'
    const onKeyDown = event => {
      if (event.key === 'Escape') { event.preventDefault(); onClose() }
      if (event.key === 'ArrowRight' && images.length > 1) { event.preventDefault(); move(1) }
      if (event.key === 'ArrowLeft' && images.length > 1) { event.preventDefault(); move(-1) }
      if (event.key === 'Tab') {
        const controls = [...document.querySelectorAll('.qs-lightbox button:not([disabled])')]
        if (!controls.length) return
        const first = controls[0]
        const last = controls[controls.length - 1]
        if (event.shiftKey && document.activeElement === first) { event.preventDefault(); last.focus() }
        else if (!event.shiftKey && document.activeElement === last) { event.preventDefault(); first.focus() }
      }
    }
    document.addEventListener('keydown', onKeyDown)
    return () => {
      document.removeEventListener('keydown', onKeyDown)
      document.body.style.overflow = previous
    }
  }, [images.length, onClose])
  const current = images[index]
  if (!current) return null
  return <div className="qs-lightbox" role="dialog" aria-modal="true" aria-label={`${title} image viewer`} onMouseDown={event => {
    if (event.target === event.currentTarget) onClose()
  }}>
    <div className="qs-lightbox-top">
      <div className="qs-lightbox-meta"><span>OUR WORK / IMAGE VIEWER</span><strong>{title}</strong></div>
      <div className="qs-lightbox-controls"><span className="qs-lightbox-count">{index + 1} / {images.length}</span>
        <button type="button" className="qs-lightbox-close" ref={closeRef} onClick={onClose} aria-label="Close image viewer">✕</button>
      </div>
    </div>
    <div className="qs-lightbox-stage" onTouchStart={event => { swipeStart.current = event.touches[0]?.clientX ?? null }} onTouchEnd={event => {
      if (swipeStart.current === null) return
      const delta = (event.changedTouches[0]?.clientX ?? swipeStart.current) - swipeStart.current
      if (Math.abs(delta) > 55 && images.length > 1) move(delta < 0 ? 1 : -1)
      swipeStart.current = null
    }}>
      {images.length > 1 && <button type="button" className="qs-lightbox-arrow" aria-label="Previous photo" onClick={() => move(-1)}>‹</button>}
      <img src={current.url} alt={current.altText || `${title} — image ${index + 1}`}/>
      {images.length > 1 && <button type="button" className="qs-lightbox-arrow" aria-label="Next photo" onClick={() => move(1)}>›</button>}
    </div>
    {images.length > 1 && <div className="qs-lightbox-thumbs" aria-label="Choose a photo">
      {images.map((image, i) => <button type="button" key={image.id || i} aria-label={`View photo ${i + 1}`} aria-pressed={index === i}
        className={index === i ? 'active' : ''} onClick={() => setIndex(i)}>
        <img src={image.url} alt=""/>
      </button>)}
    </div>}
    <p className="qs-lightbox-tip">Tap outside or press Esc to close{images.length > 1 ? ' · Swipe to browse' : ''}</p>
  </div>
}

export default function OurWorkPage() {
  const route = resolvePortfolioPath(window.location.pathname)
  const [projects, setProjects] = useState([])
  const [status, setStatus] = useState('loading')
  const [category, setCategory] = useState('')
  const [retryCount, setRetryCount] = useState(0)
  const [lightboxIndex, setLightboxIndex] = useState(null)
  const triggerRef = useRef(null)
  const closeLightbox = () => { setLightboxIndex(null); requestAnimationFrame(() => triggerRef.current?.focus()) }
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
  const images = project?.media?.filter(item => item.url) || []
  const openPhoto = (index, event) => { triggerRef.current = event.currentTarget; setLightboxIndex(index) }
  return <main className="shell section qs-portfolio-page">
    <a href="/our-work" className="qs-portfolio-back"><Arrow direction="left"/> Our Work</a>
    <header className={project ? 'qs-portfolio-hero qs-portfolio-hero-detail' : 'qs-portfolio-hero'}>
      <span className="qs-portfolio-kicker">QUICK SOLUTION CAFÉ / OUR WORK</span>
      <h1>{route?.page === 'project' && project ? project.title : 'Work worth showing.'}</h1>
      <p className="qs-portfolio-lead">{route?.page === 'project' && project ? project.summary : 'Printing, branding and thoughtful creative work. Made for businesses, people and everyday moments.'}</p>
    </header>
    {status === 'loading' && <p role="status" className="qs-portfolio-message">Loading our work…</p>}
    {status === 'error' && <div role="alert" className="qs-portfolio-message"><p>Our work is temporarily unavailable. Please try again.</p><button type="button" className="qs-portfolio-filter" onClick={() => { setStatus('loading'); setRetryCount(count => count + 1) }}>Try again</button></div>}
    {status === 'ready' && route?.page === 'project' && !project && <div className="qs-portfolio-message"><p>This project is not available.</p><a href="/our-work">Browse Our Work <Arrow/></a></div>}
    {status === 'ready' && project && <>
      {!!project.categorySlugs?.length && <div className="qs-portfolio-tags">{project.categorySlugs.map(slug => <span key={slug}>{categoryLabel(slug)}</span>)}</div>}
      {project.description && <p className="qs-portfolio-story">{project.description}</p>}
      <section className="qs-portfolio-project-media" aria-label={`${project.title} photographs`}>
        <div className="qs-portfolio-detail-grid">
          {images.map((item, i) => <button type="button" className="qs-portfolio-detail-photo" key={item.id || i}
            onClick={event => openPhoto(i, event)} aria-label={`Open photo ${i + 1} in fullscreen viewer`}>
            <img src={item.url} alt={item.altText || project.title} loading={i ? 'lazy' : 'eager'}/>
            <span className="qs-portfolio-zoom">↗ View image</span>
          </button>)}
        </div>
        {images.length > 1 && <p className="qs-portfolio-photo-note">{images.length} images · Select any image to expand</p>}
      </section>
      <footer className="qs-portfolio-project-footer"><a href="/our-work"><Arrow direction="left"/> Explore more projects</a></footer>
    </>}
    {status === 'ready' && route?.page === 'listing' && <>
      {categories.length > 0 && <nav aria-label="Filter by offering" className="qs-portfolio-filters">
        <button type="button" className={category ? 'qs-portfolio-filter' : 'qs-portfolio-filter active'} aria-pressed={!category} onClick={() => setCategory('')}>All projects</button>
        {categories.map(slug => <button key={slug} type="button" className={category === slug ? 'qs-portfolio-filter active' : 'qs-portfolio-filter'} aria-pressed={category === slug} onClick={() => setCategory(slug)}>{categoryLabel(slug)}</button>)}
      </nav>}
      <div className="qs-portfolio-list-heading"><span>SELECTED WORK</span><span>{visible.length} {visible.length === 1 ? 'project' : 'projects'}</span></div>
      {!visible.length && <p className="qs-portfolio-message">No projects in this collection yet. Explore another category or check back soon.</p>}
      <div className="qs-portfolio-gallery">
        {visible.map(item => <article className="qs-portfolio-card" key={item.id || item.slug}>
          <a href={portfolioProjectPath(item.slug)} aria-label={`View project: ${item.title}`}>
            <div className="qs-portfolio-card-media">{item.coverUrl ? <img src={item.coverUrl} alt={item.coverAlt || item.title} loading="lazy"/> : <span>QUICK SOLUTION CAFÉ</span>}</div>
            <div className="qs-portfolio-card-copy">
              <span className="qs-portfolio-card-category">{(item.categorySlugs || []).map(categoryLabel).join(' / ') || 'Selected work'}</span>
              <div className="qs-portfolio-card-title"><h2>{item.title}</h2><Arrow/></div>
              {item.summary && <p>{item.summary}</p>}
            </div>
          </a>
        </article>)}
      </div>
    </>}
    {lightboxIndex !== null && images.length > 0 && <PortfolioLightbox key={project.id} images={images} initialIndex={lightboxIndex} title={project.title} onClose={closeLightbox}/>}
  </main>
}
