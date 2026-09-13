const STORAGE_KEY = 'qsc_catalog_v1'

export function cloneCatalog(products) {
  return JSON.parse(JSON.stringify(products))
}

export function loadCatalog(fallbackProducts) {
  if (typeof window === 'undefined') return cloneCatalog(fallbackProducts)
  try {
    const raw = window.localStorage.getItem(STORAGE_KEY)
    if (!raw) return cloneCatalog(fallbackProducts)
    const parsed = JSON.parse(raw)
    if (!Array.isArray(parsed) || parsed.length === 0) return cloneCatalog(fallbackProducts)
    return parsed
  } catch {
    return cloneCatalog(fallbackProducts)
  }
}

export function saveCatalog(products) {
  window.localStorage.setItem(STORAGE_KEY, JSON.stringify(products))
}

export function resetCatalog() {
  window.localStorage.removeItem(STORAGE_KEY)
}

export function exportCatalog(products) {
  const blob = new Blob([JSON.stringify({ schemaVersion: 'qsc-catalog-1', exportedAt: new Date().toISOString(), products }, null, 2)], { type: 'application/json' })
  const url = URL.createObjectURL(blob)
  const link = document.createElement('a')
  link.href = url
  link.download = `quick-solution-catalog-${new Date().toISOString().slice(0, 10)}.json`
  link.click()
  URL.revokeObjectURL(url)
}
