import { getAdminSession } from './supabaseApi.js'

const URL = String(import.meta.env.VITE_SUPABASE_URL || '').replace(/\/$/, '')
const KEY = String(import.meta.env.VITE_SUPABASE_PUBLISHABLE_KEY || import.meta.env.VITE_SUPABASE_ANON_KEY || '')
const TENANT = String(import.meta.env.VITE_QS_TENANT_SLUG || 'quick-solution')

function headers(json = true) {
  const token = getAdminSession()?.access_token
  if (!token) throw new Error('Staff sign-in is required.')
  if (!URL || !KEY) throw new Error('Supabase is not configured.')
  return { apikey: KEY, Authorization: `Bearer ${token}`, ...(json ? { 'Content-Type': 'application/json' } : {}) }
}
async function checked(response) {
  if (!response.ok) {
    const payload = await response.json().catch(() => ({}))
    throw new Error(payload.message || payload.error || `Portfolio request failed (${response.status})`)
  }
  return response.json()
}
async function rpc(name, body) {
  return checked(await fetch(`${URL}/rest/v1/rpc/${name}`, {
    method: 'POST', headers: headers(), body: JSON.stringify(body)
  }))
}
export async function getAdminPortfolio() {
  const result = await rpc('admin_get_quick_solution_portfolio', { p_tenant_slug: TENANT })
  return Array.isArray(result) ? result : result?.projects || []
}
export async function saveAdminPortfolioProject(project) {
  return rpc('admin_save_quick_solution_portfolio_project', { p_tenant_slug: TENANT, p_project: project })
}
export async function uploadAdminPortfolioImage(projectId, file) {
  const form = new FormData()
  form.append('project_id', projectId)
  form.append('tenant_slug', TENANT)
  form.append('file', file, file.name)
  return checked(await fetch(`${URL}/functions/v1/quick-solution-portfolio-upload`, {
    method: 'POST', headers: headers(false), body: form
  }))
}
