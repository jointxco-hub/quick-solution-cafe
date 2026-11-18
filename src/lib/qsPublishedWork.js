// QS public portfolio feed: shared X LAB library, published-only Postgres view.
// No write credentials, tenant admin tokens or temporary static project catalogue.
const env = import.meta.env || {}\nconst url = String(env.VITE_QS_WORK_SUPABASE_URL || env.VITE_SUPABASE_URL || '').replace(/\/$/, '')
const key = String(env.VITE_QS_WORK_SUPABASE_PUBLISHABLE_KEY || env.VITE_SUPABASE_PUBLISHABLE_KEY || env.VITE_SUPABASE_ANON_KEY || '')

export function mapQsWorkRow(row) {
  if (!row || !row.id || !row.title) return null
  const video = String(row.video_url || '').trim()
  const image = String(row.cover_image || row.video_thumbnail || '').trim()
  const safeUrl = (s) => {
    try {
      const parsed = new URL(s)
      return parsed.protocol === 'https:' ? parsed.href : ''
    } catch { return '' }
  }
  const videoUrl = safeUrl(video)
  const posterUrl = safeUrl(String(row.video_thumbnail || row.cover_image || ''))
  const coverUrl = safeUrl(image)
  const directVideo = /\.(mp4|webm|ogg)(?:[?#]|$)/i.test(videoUrl)
  const media = directVideo
    ? { kind: 'video', src: videoUrl, poster: posterUrl, alt: row.title }
    : coverUrl
      ? { kind: 'image', src: coverUrl, alt: row.title, externalVideo: videoUrl }
      : videoUrl ? { kind: 'link', externalVideo: videoUrl } : null
  return {
    id: row.id,
    title: row.title,
    category: row.category || 'Our work',
    subtitle: row.summary || '',
    featured: row.qs_featured === true,
    sortOrder: Number(row.qs_sort_order) || 0,
    media,
    videoUrl,
  }
}

export async function loadQsPublishedWork({ signal } = {}) {
  if (!url || !key) return []
  const endpoint = new URL(url + '/rest/v1/qs_published_work')
  endpoint.searchParams.set('select', 'id,title,category,summary,cover_image,video_url,video_thumbnail,qs_featured,qs_sort_order')
  endpoint.searchParams.set('order', 'qs_featured.desc,qs_sort_order.asc,title.asc')
  endpoint.searchParams.set('limit', '12')
  const response = await fetch(endpoint.href, { headers: { apikey: key }, signal })
  if (!response.ok) throw new Error('Public project feed is unavailable (' + response.status + ')')
  const rows = await response.json()
  if (!Array.isArray(rows)) throw new Error('Invalid project feed')
  return rows.map(mapQsWorkRow).filter(Boolean)
}
