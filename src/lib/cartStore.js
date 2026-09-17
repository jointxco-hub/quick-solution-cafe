const STORAGE_KEY = 'qsc_cart_v1'

export function loadCart() {
  if (typeof window === 'undefined') return []
  try {
    const raw = window.localStorage.getItem(STORAGE_KEY)
    if (!raw) return []
    const parsed = JSON.parse(raw)
    return Array.isArray(parsed) ? parsed : []
  } catch {
    return []
  }
}

export function saveCart(items) {
  if (typeof window === 'undefined') return
  const serializable = (items || []).map(({ file, files, ...item }) => {
    const normalizedFiles = Array.isArray(files) ? files : file ? [file] : []
    return {
      ...item,
      fileMeta: normalizedFiles[0]
        ? { name: normalizedFiles[0].name, size: normalizedFiles[0].size, type: normalizedFiles[0].type }
        : item.fileMeta || null,
      filesMeta: normalizedFiles.length
        ? normalizedFiles.map((entry) => ({ name: entry.name, size: entry.size, type: entry.type }))
        : item.filesMeta || []
    }
  })
  window.localStorage.setItem(STORAGE_KEY, JSON.stringify(serializable))
}

export function clearCart() {
  if (typeof window === 'undefined') return
  window.localStorage.removeItem(STORAGE_KEY)
}
