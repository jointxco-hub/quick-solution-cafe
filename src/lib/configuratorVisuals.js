import { deriveVariantAxisValues, resolveProductMedia } from './productContent.js'

const BUILTIN_VISUAL_OPTIONS = {
  flags: {
    style: {
      telescopic: { image: '/qs21/flags-hero-single.webp', label: 'Straight / telescopic', helper: 'A tall straight promotional flag.' },
      sharkfin: { image: '/qs21/flags-shark-fin-pair.webp', label: 'Shark fin', helper: 'A tapered flag with the familiar fin shape.' },
      curved: { image: '/qs21/flags-hero-single-alt.webp', label: 'Curved', helper: 'A softer curved-top promotional flag.' }
    }
  }
}

function configuredStyle(product, config = {}) {
  if (config.variantAxis_style) return config.variantAxis_style
  if (!config.variant) return ''
  return deriveVariantAxisValues(product, config.variant)?.style || ''
}

export function resolveVisualAxisOption(product, axisId, option) {
  const entry = product?.visualOptions?.[axisId]?.[option?.id]
    || product?.customer_definition?.visualOptions?.[axisId]?.[option?.id]
    || BUILTIN_VISUAL_OPTIONS[product?.id]?.[axisId]?.[option?.id]
  if (!entry) return null
  if (typeof entry === 'string') return { image: entry, label: option.label || option.id, helper: '' }
  return { image: entry.image || null, label: entry.label || option.label || option.id, helper: entry.helper || '' }
}

export function resolveConfiguratorPreviewImage(product, config = {}) {
  const style = configuredStyle(product, config)
  if (style) {
    const axis = product?.pricing?.variantAxes?.find((item) => item.id === 'style')
    const option = axis?.options?.find((item) => item.id === style)
    const visual = resolveVisualAxisOption(product, 'style', option || { id: style, label: style })
    if (visual?.image) return visual.image
  }
  return resolveProductMedia(product)?.hero || null
}

export function resolveConfiguratorPreviewDetail(product, config = {}) {
  const style = configuredStyle(product, config)
  if (!style) return ''
  const axis = product?.pricing?.variantAxes?.find((item) => item.id === 'style')
  const option = axis?.options?.find((item) => item.id === style)
  const visual = resolveVisualAxisOption(product, 'style', option || { id: style, label: style })
  return visual?.label || option?.label || ''
}
