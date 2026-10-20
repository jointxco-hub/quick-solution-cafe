// Public portfolio RPC. The server must enforce publication and media visibility.
// This client never requests draft or private customer/order data.
const URL = String(import.meta.env.VITE_SUPABASE_URL || '').replace(/\/$/, '')
const KEY = String(import.meta.env.VITE_SUPABASE_PUBLISHABLE_KEY || import.meta.env.VITE_SUPABASE_ANON_KEY || '')
const TENANT = String(import.meta.env.VITE_QS_TENANT_SLUG || 'quick-solution')

export async function loadPublishedPortfolio() {
  if (!URL || !KEY) return []
  const response = await fetch(`${URL}/rest/v1/rpc/get_quick_solution_portfolio`, {
    method: 'POST',
    headers: { apikey: KEY, 'Content-Type': 'application/json', ...(KEY.startsWith('eyJ') ? { Authorization: `Bearer ${KEY}` } : {}) },
    body: JSON.stringify({ p_tenant_slug: TENANT })
  })
  if (!response.ok) throw new Error('Published portfolio is unavailable')
  const result = await response.json()
  const projects = Array.isArray(result) ? result : Array.isArray(result?.projects) ? result.projects : []
  return Promise.all(projects.map(async project => {
    if (!project.media?.length) return project
    try {
      const response = await fetch(`${URL}/functions/v1/quick-solution-portfolio-media`, {
        method: 'POST', headers: { apikey: KEY, 'Content-Type': 'application/json' },
        body: JSON.stringify({ project_id: project.id, tenant_slug: TENANT })
      })
      if (!response.ok) return project
      const payload = await response.json()
      const media = Array.isArray(payload.media) ? payload.media : []
      return { ...project, media, coverUrl: media.find(item => item.url)?.url || null, coverAlt: media[0]?.altText || project.title }
    } catch { return project }
  }))
}
