import assert from 'node:assert/strict'
import fs from 'node:fs'
import test from 'node:test'

import { resolveFulfilmentPointDisplayName } from '../src/lib/businessInfo.js'
import { resolveProductMedia, resolveProductMediaSequence } from '../src/lib/productContent.js'
import { resolveAvailableGalleryImage } from '../src/lib/gallery.js'
import { resolveMobilePdpCtaVisibility } from '../src/lib/navigation.js'

test('nearby collection resolver replaces the internal cafe label on the real live payload shape', () => {
  const livePoint = {
    id: 'location-001',
    name: 'Quick Solution Cafe - Location 001',
    kind: 'cafe'
  }
  assert.equal(
    resolveFulfilmentPointDisplayName(livePoint),
    'Quick Solution Caf\u00e9 \u00b7 Kite Cres, Riverside View'
  )
  assert.equal(livePoint.id, 'location-001')
})

test('nearby collection resolver preserves non-cafe Quick Point names', () => {
  assert.equal(
    resolveFulfilmentPointDisplayName({ id: 'qp-2', name: 'Riverside Partner', kind: 'quick_point' }),
    'Riverside Partner'
  )
})

test('live Flags customer_definition without media still resolves real QS-21 photography', () => {
  const media = resolveProductMedia({ id: 'flags', name: 'Flags', customer_definition: {} })
  assert.equal(media.hero, '/qs21/flags-hero-single.webp')
  assert.deepEqual(media.gallery, [
    '/qs21/flags-lineup-sizes.webp',
    '/qs21/flags-shark-fin-pair.webp',
    '/qs21/flags-hero-single-alt.webp'
  ])
})

test('global Simple/Pro chrome and persistence are no longer wired into App/Header', () => {
  const app = fs.readFileSync(new URL('../src/App.jsx', import.meta.url), 'utf8')
  const header = fs.readFileSync(new URL('../src/components/Header.jsx', import.meta.url), 'utf8')
  assert.doesNotMatch(app, /LanguageModePrompt|loadLanguageMode|saveLanguageMode/)
  assert.doesNotMatch(header, />Simple<|>Pro<|Start order/)
  assert.match(app, /const languageMode = 'simple'/)
})

test('all three document entry paths converge on the canonical helper', () => {
  const app = fs.readFileSync(new URL('../src/App.jsx', import.meta.url), 'utf8')
  assert.match(app, /onSendDocuments=\{openDocumentPrinting\}/)
  assert.match(app, /nav\.productId === 'a4-print'[\s\S]*openDocumentPrinting\(\)/)
  assert.match(app, /setDocumentEntryRequest\(\(request\) => request \+ 1\)/)
  assert.match(app, /scrollToConfigurator\(configureRef\.current\)/)
})

test('live Flags media with an empty gallery still resolves the real gallery fallback', () => {
  const media = resolveProductMedia({ id: 'flags', name: 'Flags', media: { gallery: [] } })
  assert.equal(media.hero, '/qs21/flags-hero-single.webp')
  assert.deepEqual(media.gallery, [
    '/qs21/flags-lineup-sizes.webp',
    '/qs21/flags-shark-fin-pair.webp',
    '/qs21/flags-hero-single-alt.webp'
  ])
})

test('live Flags placeholder primary resolves real photography as the actual first PDP image', () => {
  const media = resolveProductMedia({
    id: 'flags',
    name: 'Flags',
    image: '/qs14/flags-placeholder.webp',
    media: {
      hero: '/qs14/flags-placeholder.webp',
      gallery: [
        '/qs14/flags-placeholder.webp',
        '/qs21/flags-lineup-sizes.webp',
        '/qs21/flags-shark-fin-pair.webp',
        '/qs21/flags-hero-single-alt.webp'
      ]
    }
  })
  const sequence = resolveProductMediaSequence(media)
  assert.equal(media.hero, '/qs21/flags-hero-single.webp')
  assert.equal(sequence[0], '/qs21/flags-hero-single.webp')
  assert.equal(resolveAvailableGalleryImage(sequence)?.src, '/qs21/flags-hero-single.webp')
  assert.ok(sequence.every((src) => !src.includes('placeholder')))
})

test('PDP media runtime failure advances to the next real image instead of the generic scene', () => {
  const images = ['/broken.webp', '/qs21/flags-lineup-sizes.webp']
  assert.deepEqual(resolveAvailableGalleryImage(images, 0, ['/broken.webp']), {
    src: '/qs21/flags-lineup-sizes.webp',
    index: 1
  })
})

test('mobile PDP CTA is limited to media-only visibility and stays off over details and later sections', () => {
  assert.equal(resolveMobilePdpCtaVisibility({ mediaInView: true, infoInView: false }), true)
  assert.equal(resolveMobilePdpCtaVisibility({ mediaInView: true, infoInView: true }), false)
  assert.equal(resolveMobilePdpCtaVisibility({ mediaInView: false, infoInView: true }), false)
  assert.equal(resolveMobilePdpCtaVisibility({ mediaInView: false, infoInView: false }), false)
})

test('mobile Shop cards explicitly constrain every nested media shrink boundary', () => {
  const css = fs.readFileSync(new URL('../src/styles/qs21-5-mobile-shell.css', import.meta.url), 'utf8')
  assert.match(css, /\.services-section \.product-grid,[\s\S]*?min-width: 0;[\s\S]*?max-width: 100%;[\s\S]*?width: 100%;/)
  assert.match(css, /\.product-card-body,[\s\S]*?\.product-card-media[\s\S]*?min-width: 0;[\s\S]*?max-width: 100%;/)
  assert.match(css, /\.product-card-media\.has-photo img[\s\S]*?min-width: 0;[\s\S]*?max-width: 100%;[\s\S]*?width: 100%;/)
})
