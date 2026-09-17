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
  const serializable = (items || []).map(({ file, ...item }) => ({
    ...item,
    fileMeta: file ? { name: file.name, size: file.size, type: file.type } : item.fileMeta || null
  }))
  window.localStorage.setItem(STORAGE_KEY, JSON.stringify(serializable))
}

export function clearCart() {
  if (typeof window === 'undefined') return
  window.localStorage.removeItem(STORAGE_KEY)
}
