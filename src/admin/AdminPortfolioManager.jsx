import React, { useEffect, useState } from 'react'
import { getAdminPortfolio, saveAdminPortfolioProject, uploadAdminPortfolioImage } from '../lib/portfolioAdminApi.js'
import './portfolio-admin.css'

const categories = [
  ['printing-documents', 'Printing & Documents'], ['apparel-branding', 'Apparel & Branding'],
  ['stickers-labels', 'Stickers & Labels'], ['signage-displays', 'Signage & Displays'],
  ['business-branding', 'Business Branding'], ['photography-media', 'Photography & Media'],
  ['websites-digital', 'Websites & Digital'], ['custom-projects', 'Custom Projects']
]
const steps = [['details', 'Details'], ['links', 'Categories & products'], ['photos', 'Photos'], ['publish', 'Publish']]
const blank = () => ({ title: '', slug: '', summary: '', description: '', categorySlugs: [], productKeys: [], status: 'draft', featured: false, media: [] })
const slugify = value => String(value || '').toLowerCase().normalize('NFKD').replace(/[^a-z0-9]+/g, '-').replace(/^-|-$/g, '')
const displayError = (message, slug) => /23505|duplicate key|unique constraint/i.test(message)
  ? `The URL “${slug}” is already in use. Select the existing project above or enter another URL.`
  : message

export default function AdminPortfolioManager({ products = [] }) {
  const [projects, setProjects] = useState([])
  const [draft, setDraft] = useState(blank)
  const [section, setSection] = useState('details')
  const [busy, setBusy] = useState(false)
  const [dirty, setDirty] = useState(false)
  const [error, setError] = useState('')
  const [notice, setNotice] = useState('')
  const [ready, setReady] = useState(false)
  const [uploadProgress, setUploadProgress] = useState('')
  const [search, setSearch] = useState('')
  const [productSearch, setProductSearch] = useState('')
  const [showProjects, setShowProjects] = useState(false)

  const reload = async () => {
    const rows = await getAdminPortfolio()
    setProjects(rows)
    setReady(true)
    return rows
  }
  useEffect(() => { reload().catch(err => { setError(err.message || 'Could not load projects'); setReady(true) }) }, [])

  const edit = (next) => {
    if (dirty && !window.confirm('Discard unsaved changes?')) return
    setDraft(next)
    setDirty(false)
    setNotice('')
    setError('')
    setUploadProgress('')
    setShowProjects(false)
    setSection('details')
  }
  const change = (key, value) => {
    setDraft(current => ({ ...current, [key]: value }))
    setDirty(true)
    setNotice('')
  }
  const toggle = (key, value) => {
    setDraft(current => ({ ...current, [key]: current[key].includes(value)
      ? current[key].filter(item => item !== value)
      : [...current[key], value] }))
    setDirty(true)
    setNotice('')
  }
  const validDraft = current => {
    if (!current.title.trim()) {
      setSection('details')
      setError('Add a project title before continuing.')
      return false
    }
    if (!/^[a-z0-9]+(?:-[a-z0-9]+)*$/.test(current.slug)) {
      setSection('details')
      setError('Enter a valid shareable URL using lowercase letters, numbers and hyphens.')
      return false
    }
    return true
  }
  const persist = async (nextDraft, successMessage = '') => {
    if (!validDraft(nextDraft)) return null
    setBusy(true)
    setError('')
    try {
      const saved = await saveAdminPortfolioProject(nextDraft)
      const rows = await reload()
      const fresh = rows.find(item => item.id === saved.id) || saved
      setDraft(fresh)
      setDirty(false)
      if (successMessage) setNotice(successMessage)
      return fresh
    } catch (err) {
      setError(displayError(err.message || 'Could not save project', nextDraft.slug))
      return null
    } finally { setBusy(false) }
  }
  const goTo = async next => {
    if (busy || next === section) return
    setError('')
    if (next === 'photos' && (!draft.id || dirty) && draft.status === 'draft') {
      const saved = await persist(draft, 'Private draft saved automatically. You can now add photos.')
      if (!saved) return
    }
    setSection(next)
  }
  const nextStep = () => {
    const index = steps.findIndex(([key]) => key === section)
    if (section === 'details' && !validDraft(draft)) return
    goTo(steps[Math.min(index + 1, steps.length - 1)][0])
  }
  const previousStep = () => {
    const index = steps.findIndex(([key]) => key === section)
    goTo(steps[Math.max(0, index - 1)][0])
  }
  const makePrivateForPhotos = async () => {
    if (!draft.id || busy) return
    if (!window.confirm('Unpublish this project so you can add photos? It will disappear from public pages until you publish it again.')) return
    const saved = await persist({ ...draft, status: 'draft' }, 'Project is now private. Photo uploads are enabled.')
    if (saved) setSection('photos')
  }
  const save = async event => {
    event.preventDefault()
    if (section !== 'publish') { nextStep(); return }
    setNotice('')
    await persist(draft, draft.status === 'published'
      ? 'Project published successfully and visible in Our Work.'
      : 'Project saved privately. It is no longer public.')
  }
  const upload = async event => {
    const files = Array.from(event.target.files || [])
    event.target.value = ''
    if (!draft.id || draft.status !== 'draft') {
      setError('Save this project as a draft before adding photos.')
      return
    }
    if (!files.length) return
    setBusy(true)
    setNotice('')
    setError('')
    try {
      for (let i = 0; i < files.length; i += 1) {
        const file = files[i]
        if (!['image/jpeg', 'image/png', 'image/webp'].includes(file.type) || file.size > 10485760 || !file.size) {
          throw new Error('Choose JPEG, PNG or WebP photos under 10 MB each.')
        }
        setUploadProgress(`Uploading ${i + 1} of ${files.length}: ${file.name}`)
        await uploadAdminPortfolioImage(draft.id, file)
      }
      const rows = await reload()
      setDraft(rows.find(item => item.id === draft.id) || draft)
      setNotice(`${files.length} photo${files.length === 1 ? '' : 's'} uploaded successfully.`)
    } catch (err) {
      setError(err.message || 'Upload failed. Try again.')
      try {
        const rows = await reload()
        setDraft(rows.find(item => item.id === draft.id) || draft)
      } catch {}
    } finally { setUploadProgress(''); setBusy(false) }
  }
  const status = draft.status === 'published' ? 'Published' : 'Private draft'
  const filteredProjects = projects.filter(p => p.title.toLowerCase().includes(search.toLowerCase()))
  const filteredProducts = products.filter(p => p.name.toLowerCase().includes(productSearch.toLowerCase()))
  return <section className="portfolio-admin" aria-labelledby="our-work-admin-heading">
    <div className="portfolio-admin-top">
      <div><span className="eyebrow">Portfolio manager</span><h2 id="our-work-admin-heading">Our Work</h2>
        <p>Create projects, add approved photographs and publish when ready.</p></div>
      <button type="button" className="portfolio-action" onClick={() => edit(blank())}>+ New project</button>
    </div>

    <div className="portfolio-project-picker">
      <button type="button" className="portfolio-picker-toggle" aria-expanded={showProjects} onClick={() => setShowProjects(value => !value)}>
        <span><strong>{draft.id ? draft.title : 'New project'}</strong><small>{draft.id ? status : 'Not saved yet'} · {projects.length} existing projects</small></span>
        <span aria-hidden="true">{showProjects ? '▲' : '▾'}</span>
      </button>
      {showProjects && <div className="portfolio-picker-list">
        <input aria-label="Search portfolio projects" placeholder="Find a project…" value={search} onChange={e => setSearch(e.target.value)}/>
        {filteredProjects.map(project => <button type="button" className={project.id === draft.id ? 'selected' : ''} key={project.id} onClick={() => edit(project)}>
          <span>{project.title}</span><small>{project.status === 'published' ? 'Public' : 'Draft'}</small>
        </button>)}
        {!filteredProjects.length && <p>No matching projects.</p>}
      </div>}
    </div>

    {(error || notice || uploadProgress) && <div className={error ? 'portfolio-feedback error' : 'portfolio-feedback'} role={error ? 'alert' : 'status'}>
      <strong>{error ? 'Action needed' : uploadProgress ? 'Working…' : 'Success ✓'}</strong>
      <span>{error || uploadProgress || notice}</span>
      {error && <button type="button" onClick={() => setError('')} aria-label="Dismiss error">×</button>}
    </div>}
    {!ready && <p role="status">Loading projects…</p>}

    <nav className="portfolio-steps" aria-label="Edit project section">
      {steps.map(([key, title], index) => <button key={key} type="button" aria-current={section === key ? 'step' : undefined}
        className={section === key ? 'active' : ''} onClick={() => goTo(key)}>
        <span className="portfolio-step-number">{index + 1}</span>{title}
        {key === 'photos' && draft.media?.length > 0 ? <small>{draft.media.length}</small> : null}
      </button>)}
    </nav>

    <form id="portfolio-project-form" onSubmit={save} className="portfolio-editor-form">
      {section === 'details' && <div className="portfolio-panel">
        <div className="portfolio-panel-heading"><h3>Project details</h3><p>Start with a short, clear story.</p></div>
        <label className="admin-field"><span>Project title *</span><input required value={draft.title} onChange={e => {
          const title = e.target.value
          setDraft(current => ({ ...current, title, slug: current.id ? current.slug : slugify(title) }))
          setDirty(true); setNotice('')
        }}/></label>
        <label className="admin-field"><span>Shareable URL *</span><input required pattern="[a-z0-9]+(-[a-z0-9]+)*" value={draft.slug} onChange={e => change('slug', e.target.value)}/><small>cafe.jointx.co.za/our-work/{draft.slug || 'your-project'}</small></label>
        <label className="admin-field"><span>Short description</span><textarea rows="2" value={draft.summary || ''} onChange={e => change('summary', e.target.value)}/></label>
        <label className="admin-field"><span>Project story</span><textarea rows="4" value={draft.description || ''} onChange={e => change('description', e.target.value)}/></label>
      </div>}

      {section === 'links' && <div className="portfolio-panel">
        <div className="portfolio-panel-heading"><h3>Categories & products</h3><p>Tap a tile to select or remove it. Selected tiles turn green.</p></div>
        <h4>Categories <span className="portfolio-count">{draft.categorySlugs.length} selected</span></h4>
        <div className="portfolio-choice-grid">{categories.map(([slug, name]) => {
          const selected = draft.categorySlugs.includes(slug)
          return <button key={slug} type="button" className={selected ? 'portfolio-choice selected' : 'portfolio-choice'}
            aria-pressed={selected} onClick={() => toggle('categorySlugs', slug)}>
            <span>{name}</span><span aria-hidden="true">{selected ? '✓' : '+'}</span>
          </button>
        })}</div>
        <div className="portfolio-related-heading"><h4>Related products <span className="portfolio-count">{draft.productKeys.length} selected</span></h4>
          <input aria-label="Search related products" placeholder="Search products…" value={productSearch} onChange={e => setProductSearch(e.target.value)}/></div>
        <div className="portfolio-choice-grid">{filteredProducts.map(product => {
          const selected = draft.productKeys.includes(product.id)
          return <button key={product.id} type="button" className={selected ? 'portfolio-choice selected' : 'portfolio-choice'}
            aria-pressed={selected} onClick={() => toggle('productKeys', product.id)}>
            <span>{product.name}</span><span aria-hidden="true">{selected ? '✓' : '+'}</span>
          </button>
        })}</div>
        {!filteredProducts.length && <p>No products match your search.</p>}
      </div>}

      {section === 'photos' && <div className="portfolio-panel">
        <div className="portfolio-panel-heading"><h3>Project photos</h3><p>{draft.media?.length || 0} uploaded · Only use photos approved for showcasing.</p></div>
        {!draft.id && <div className="portfolio-hint">Enter the project details first, then return to Photos. A private draft will be saved automatically.</div>}
        {draft.status === 'published' && <div className="portfolio-hint portfolio-photo-unlock"><span>This project is public. To add photos, make it private temporarily.</span><button type="button" className="portfolio-action" disabled={busy} onClick={makePrivateForPhotos}>Make private to edit photos</button></div>}
        <label className={draft.id && draft.status === 'draft' && !busy && !dirty ? 'portfolio-upload' : 'portfolio-upload disabled'}>
          <span aria-hidden="true">↑</span><strong>{busy ? 'Please wait…' : 'Choose photos to upload'}</strong>
          <small>JPEG, PNG or WebP · max 10 MB each</small>
          <input aria-label="Upload project photographs" type="file" accept="image/jpeg,image/png,image/webp" multiple disabled={!draft.id || draft.status !== 'draft' || busy || dirty} onChange={upload}/>
        </label>
        {dirty && draft.id && <p className="portfolio-hint">Save your changes before uploading photos.</p>}
        <div className="portfolio-photo-grid">{(draft.media || []).map((item, i) => <figure key={item.id || i}>
          {item.url ? <img src={item.url} alt={item.altText || draft.title} loading="lazy"/> : <div className="portfolio-image-pending">Photo {i + 1} · preview unavailable</div>}
          <figcaption>Photo {i + 1}{i === 0 ? ' · Cover' : ''}</figcaption>
        </figure>)}</div>
      </div>}

      {section === 'publish' && <div className="portfolio-panel">
        <div className="portfolio-panel-heading"><h3>Review & publish</h3><p>Control when this project appears to customers.</p></div>
        <div className="portfolio-visibility">
          <button type="button" aria-pressed={draft.status === 'draft'} className={draft.status === 'draft' ? 'selected' : ''} onClick={() => change('status', 'draft')}>
            <strong>Private draft</strong><small>Only authorized staff can view it</small>
          </button>
          <button type="button" aria-pressed={draft.status === 'published'} className={draft.status === 'published' ? 'selected' : ''} onClick={() => change('status', 'published')}>
            <strong>Publish publicly</strong><small>Show in the Café Our Work gallery</small>
          </button>
        </div>
        <button type="button" className={draft.featured ? 'portfolio-choice selected' : 'portfolio-choice'} aria-pressed={Boolean(draft.featured)} onClick={() => change('featured', !draft.featured)}>
          <span>Featured project</span><span>{draft.featured ? '✓ On' : '+ Off'}</span>
        </button>
        <div className="portfolio-review"><strong>Quick review</strong>
          <p>{draft.title || 'Untitled project'} · {draft.media?.length || 0} photos · {draft.productKeys.length} products linked</p>
          {draft.status === 'published' && !draft.media?.length && <p className="portfolio-hint">Consider adding photos before publishing.</p>}
          {draft.id && <a href={`/our-work/${draft.slug}`} target="_blank" rel="noreferrer">Open public project ↗</a>}
        </div>
      </div>}
    </form>

    <div className="portfolio-sticky-actions">
      <div className="portfolio-save-status">
        <strong>{busy ? 'Working…' : dirty ? '● Changes in progress' : draft.id ? '✓ Draft up to date' : 'New project'}</strong>
        <small>Step {steps.findIndex(([key]) => key === section) + 1} of 4 · {status}</small>
      </div>
      <div className="portfolio-flow-buttons">
        {section !== 'details' && <button type="button" className="portfolio-back-button" disabled={busy} onClick={previousStep}>← Back</button>}
        {section !== 'publish'
          ? <button type="button" className="portfolio-primary" disabled={busy} onClick={nextStep}>{busy ? 'Saving…' : section === 'links' ? 'Continue to photos →' : section === 'photos' ? 'Review & publish →' : 'Continue →'}</button>
          : <button type="submit" form="portfolio-project-form" className="portfolio-primary" disabled={busy}>{busy ? 'Saving…' : draft.status === 'published' ? 'Save & publish' : 'Save as private draft'}</button>}
      </div>
    </div>
  </section>
}
