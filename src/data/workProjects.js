// Joint X shared project content contract (QS frontend seed).
// This temporary curated catalogue is intentionally not a production database.
// Future source of truth: one approved, tenant-scoped project library in Supabase.
// Other sites should use the same project IDs and filtered publication records,
// not copy this file to create separate editable versions.
export const WORK_SITES = Object.freeze(['qs', 'xlab', 'x1'])

export const workProjects = [
  {
    id: 'cue-corner-miss-sa-2026',
    title: 'Cue Corner',
    subtitle: 'Work seen at Miss South Africa',
    category: 'Business branding',
    year: 2026,
    detail: 'Our work for Cue Corner appeared at the Miss South Africa event.',
    relationship: 'client-work-event-appearance',
    media: [], // { kind: 'image'|'video', src, poster, alt, aspectRatio, focalPoint }
    sites: { qs: { featured: true, order: 1 }, xlab: { featured: true, order: 1 } },
    serviceTag: 'branding',
    mediaStatus: 'placeholder',
    reviewStatus: 'needs-evidence'
  },
  {
    id: 'brandon-dhludhlu-show-2026',
    title: 'Brandon Dhludhlu',
    subtitle: 'Shirts for the 30 October show',
    category: 'Artist merchandise',
    year: 2026,
    detail: 'We supplied and printed shirts for the 30 October 2026 show.',
    relationship: 'artist-merchandise',
    media: [],
    sites: { qs: { featured: true, order: 2 }, xlab: { featured: true, order: 2 }, x1: { featured: true, order: 1 } },
    serviceTag: 'merch',
    mediaStatus: 'placeholder',
    reviewStatus: 'needs-evidence'
  },
  {
    id: 'leta-mbulu-merch-2025',
    title: 'Leta Mbulu',
    subtitle: 'Artist merchandise',
    category: 'Artist merchandise',
    year: 2025,
    detail: 'Merchandise produced in 2025.',
    relationship: 'artist-merchandise',
    media: [],
    sites: { qs: { featured: true, order: 3 }, xlab: { featured: true, order: 3 }, x1: { featured: true, order: 2 } },
    serviceTag: 'merch',
    mediaStatus: 'placeholder',
    reviewStatus: 'needs-evidence'
  },
  {
    id: 'uber-eats-project',
    title: 'Uber Eats',
    subtitle: 'Selected project work',
    category: 'Brand projects',
    year: null,
    detail: 'Project details to be confirmed before publication.',
    relationship: 'scope-unconfirmed',
    media: [],
    sites: { xlab: { featured: false, order: 4 } },
    serviceTag: 'branding',
    mediaStatus: 'placeholder',
    reviewStatus: 'needs-scope'
  },
  {
    id: 'netflix-project',
    title: 'Netflix',
    subtitle: 'Selected project work',
    category: 'Brand projects',
    year: null,
    detail: 'Project details to be confirmed before publication.',
    relationship: 'scope-unconfirmed',
    media: [],
    sites: { xlab: { featured: false, order: 5 } },
    serviceTag: 'branding',
    mediaStatus: 'placeholder',
    reviewStatus: 'needs-scope'
  }
]

export function getProjectsForSite(site, { featuredOnly = true } = {}) {
  if (!WORK_SITES.includes(site)) return []
  return workProjects
    .filter(project => project.sites[site] && (!featuredOnly || project.sites[site].featured))
    .sort((a, b) => a.sites[site].order - b.sites[site].order)
}
