import React, { useEffect, useState } from 'react'
import { getAdminPortfolio, saveAdminPortfolioProject, uploadAdminPortfolioImage } from '../lib/portfolioAdminApi.js'

const categories = [
  ['printing-documents', 'Printing & Documents'], ['apparel-branding', 'Apparel & Branding'],
  ['stickers-labels', 'Stickers & Labels'], ['signage-displays', 'Signage & Displays'],
  ['business-branding', 'Business Branding'], ['photography-media', 'Photography & Media'],
  ['websites-digital', 'Websites & Digital'], ['custom-projects', 'Custom Projects']
]
const blank = () => ({ title: '', slug: '', summary: '', description: '', categorySlugs: [], productKeys: [], status: 'draft', featured: false, media: [] })
const slugify = value => String(value || '').toLowerCase().normalize('NFKD').replace(/[^a-z0-9]+/g, '-').replace(/^-|-$/g, '')

export default function AdminPortfolioManager({ products = [] }) {
  const [projects, setProjects] = useState([])
  const [draft, setDraft] = useState(blank)
  const [busy, setBusy] = useState(false)
  const [error, setError] = useState('')
  const [notice, setNotice] = useState('')
  const [ready, setReady] = useState(false)
  const reload = async () => {
    setError('')
    try {
      const rows = await getAdminPortfolio()
      setProjects(rows)
      setReady(true)
    } catch (err) {
      setError(err.message || 'Portfolio admin is unavailable')
    }
  }
  useEffect(() => { reload() }, [])
  const update = (key, value) => setDraft(current => ({ ...current, [key]: value }))
  const toggle = (key, value) => setDraft(current => ({
    ...current, [key]: current[key].includes(value) ? current[key].filter(x => x !== value) : [...current[key], value]
  }))
  const save = async (event) => {
    event.preventDefault()
    setError('')
    setNotice('')
    if (!/^[a-z0-9]+(?:-[a-z0-9]+)*$/.test(draft.slug)) { setError('Enter a valid lowercase project slug.'); return }
    setBusy(true)
    try {
      const saved = await saveAdminPortfolioProject(draft)
      setDraft(saved)
      setNotice('Project saved. Publication is controlled by its status.')
      await reload()
    } catch (err) { setError(err.message || 'Could not save project') }
    finally { setBusy(false) }
  }
  const upload = async (event) => {
    const files = [...(event.target.files || [])]
    event.target.value = ''
    if (!draft.id) { setError('Save the draft before uploading images.'); return }
    if (!files.length) return
    setBusy(true)
    setError('')
    try {
      for (const file of files) {
        if (!['image/jpeg', 'image/png', 'image/webp'].includes(file.type) || file.size > 10 * 1024 * 1024) {
          throw new Error('Use JPEG, PNG or WebP images under 10 MB each.')
        }
        await uploadAdminPortfolioImage(draft.id, file)
      }
      const rows = await getAdminPortfolio()
      setProjects(rows)
      setDraft(rows.find(row => row.id === draft.id) || draft)
      setNotice('Images uploaded to the project.')
    } catch (err) { setError(err.message || 'Upload failed') }
    finally { setBusy(false) }
  }
  return <section className="admin-editor" aria-labelledby="our-work-admin-heading">
    <div className="admin-editor-heading">
      <div><span className="eyebrow">Portfolio</span><h2 id="our-work-admin-heading">Our Work</h2></div>
      <button className="button ghost" type="button" onClick={() => { setDraft(blank()); setError(''); setNotice('') }}>New project</button>
    </div>
    <p>Create a draft, connect relevant products, add approved photographs and publish only when ready.</p>
    {error && <p role="alert" className="admin-system-message error">{error}</p>}
    {notice && <p role="status" className="admin-system-message">{notice}</p>}
    {!ready && !error && <p role="status">Loading projects…</p>}
    {ready && <div className="admin-products" aria-label="Existing projects">
      {projects.map(project => <button type="button" key={project.id} onClick={() => { setDraft(project); setError(''); setNotice('') }}>
        <strong>{project.title}</strong><small>{project.status}</small>
      </button>)}
      {!projects.length && <p>No portfolio projects yet.</p>}
    </div>}
    <form onSubmit={save} className="admin-section-block">
      <label className="admin-field"><span>Project title</span><input required value={draft.title} onChange={e => {
        const title = e.target.value
        setDraft(current => ({ ...current, title, slug: current.id ? current.slug : slugify(title) }))
      }}/></label>
      <label className="admin-field"><span>Project URL slug</span><input required pattern="[a-z0-9]+(-[a-z0-9]+)*" value={draft.slug} onChange={e => update('slug', e.target.value)}/></label>
      <label className="admin-field"><span>Short description</span><textarea rows="2" value={draft.summary || ''} onChange={e => update('summary', e.target.value)}/></label>
      <label className="admin-field"><span>Project story</span><textarea rows="4" value={draft.description || ''} onChange={e => update('description', e.target.value)}/></label>
      <fieldset className="admin-section-block"><legend>Offerings</legend>
        <div className="channel-grid">{categories.map(([slug, name]) => <label key={slug} className="channel-card">
          <input type="checkbox" checked={(draft.categorySlugs || []).includes(slug)} onChange={() => toggle('categorySlugs', slug)}/><span>{name}</span>
        </label>)}</div>
      </fieldset>
      <fieldset className="admin-section-block"><legend>Related products</legend>
        <div className="channel-grid">{products.map(product => <label key={product.id} className="channel-card">
          <input type="checkbox" checked={(draft.productKeys || []).includes(product.id)} onChange={() => toggle('productKeys', product.id)}/><span>{product.name}</span>
        </label>)}</div>
      </fieldset>
      <label className="admin-field"><span>Visibility</span><select value={draft.status} onChange={e => update('status', e.target.value)}>
        <option value="draft">Draft — private</option><option value="published">Published — public</option>
      </select></label>
      <label className="switch-row"><input type="checkbox" checked={Boolean(draft.featured)} onChange={e => update('featured', e.target.checked)}/><span>Featured project</span></label>
      <button type="submit" className="button primary-green" disabled={busy}>{busy ? 'Saving…' : 'Save project'}</button>
    </form>
    <div className="admin-section-block">
      <h3>Project photographs</h3>
      <p>Only upload work you have permission to showcase. Save the project first.</p>
      <input aria-label="Upload project photographs" type="file" accept="image/jpeg,image/png,image/webp" multiple disabled={!draft.id || busy} onChange={upload}/>
      <div className="qs10-proof-grid">{(draft.media || []).map((item, i) => <figure key={item.id || i}>
        {item.url && <img src={item.url} alt={item.altText || draft.title} style={{ maxWidth: '100%', height: 'auto' }}/>}
        <figcaption>{item.altText || 'Project photo'}</figcaption>
      </figure>)}</div>
    </div>
  </section>
}
