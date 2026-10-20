// Our Work — pure helpers; no customer or staff data is embedded here.
export const PORTFOLIO_ROOT = '/our-work'

export function portfolioProjectPath(slug) {
  if (typeof slug !== 'string' || !/^[a-z0-9]+(?:-[a-z0-9]+)*$/.test(slug)) return null
  return `${PORTFOLIO_ROOT}/${slug}`
}

export function resolvePortfolioPath(pathname = '/') {
  const path = pathname.replace(/\/+$/, '') || '/'
  if (path === PORTFOLIO_ROOT) return { page: 'listing' }
  if (!path.startsWith(PORTFOLIO_ROOT + '/')) return null
  const slug = path.slice(PORTFOLIO_ROOT.length + 1)
  return portfolioProjectPath(slug) ? { page: 'project', slug } : null
}

export function visiblePortfolioProjects(projects = [], { productKey = null, categorySlug = null } = {}) {
  return projects.filter(project => {
    if (!project || project.status !== 'published') return false
    if (productKey && !(project.productKeys || []).includes(productKey)) return false
    if (categorySlug && !(project.categorySlugs || []).includes(categorySlug)) return false
    return true
  }).sort((a, b) => Number(Boolean(b.featured)) - Number(Boolean(a.featured)) ||
    String(b.publishedAt || '').localeCompare(String(a.publishedAt || '')))
}
