import assert from 'node:assert/strict'
import fs from 'node:fs'
import test from 'node:test'

import { products } from '../src/data/products.js'
import {
  resolveConfiguratorPreviewDetail,
  resolveConfiguratorPreviewImage,
  resolveVisualAxisOption
} from '../src/lib/configuratorVisuals.js'

const flags = products.find((product) => product.id === 'flags')
const documents = products.find((product) => product.id === 'a4-print')

test('flags visual shape choices preserve the real technical option ids', () => {
  const axis = flags.pricing.variantAxes.find((item) => item.id === 'style')
  const sharkFin = axis.options.find((item) => item.id === 'sharkfin')
  const visual = resolveVisualAxisOption(flags, 'style', sharkFin)

  assert.equal(sharkFin.id, 'sharkfin')
  assert.equal(visual.image, '/qs21/flags-shark-fin-pair.webp')
  assert.equal(visual.label, 'Shark fin')
})

test('configurator preview follows the selected flag style', () => {
  assert.equal(
    resolveConfiguratorPreviewImage(flags, { variantAxis_style: 'telescopic' }),
    '/qs21/flags-hero-single.webp'
  )
  assert.equal(
    resolveConfiguratorPreviewImage(flags, { variantAxis_style: 'sharkfin' }),
    '/qs21/flags-shark-fin-pair.webp'
  )
  assert.equal(
    resolveConfiguratorPreviewImage(flags, { variantAxis_style: 'curved' }),
    '/qs21/flags-hero-single-alt.webp'
  )
})

test('preset variant ids derive their visual style without separate axis state', () => {
  assert.equal(
    resolveConfiguratorPreviewImage(flags, { variant: 'telescopic-3m-ds-full' }),
    '/qs21/flags-hero-single.webp'
  )
  assert.equal(
    resolveConfiguratorPreviewDetail(flags, { variant: 'telescopic-3m-ds-full' }),
    'Straight / telescopic'
  )
})

test('non-visual products retain the normal existing product image', () => {
  assert.equal(
    resolveConfiguratorPreviewImage(documents, {}),
    '/qs11/product-document-printing-clean.webp'
  )
})

test('both Guided and Full options carry product context while configuring', () => {
  const guided = fs.readFileSync(new URL('../src/components/GuidedOrder.jsx', import.meta.url), 'utf8')
  const full = fs.readFileSync(new URL('../src/components/ProductConfigurator.jsx', import.meta.url), 'utf8')

  assert.match(guided, /<ConfiguratorProductContext product=\{product\} config=\{config\}/)
  assert.match(full, /<ConfiguratorProductContext product=\{product\} config=\{config\}/)
})

test('top navigation implements directional auto-hide rather than timer hiding', () => {
  const header = fs.readFileSync(new URL('../src/components/Header.jsx', import.meta.url), 'utf8')

  assert.match(header, /delta > \d+/)
  assert.match(header, /delta < -\d+/)
  assert.match(header, /is-hidden/)
  assert.doesNotMatch(header, /setTimeout/)
})

test('config jumps use the QS-21.7 orientation helper', () => {
  const app = fs.readFileSync(new URL('../src/App.jsx', import.meta.url), 'utf8')

  assert.match(app, /function scrollToConfigurator/)
  assert.match(app, /scrollToConfigurator\(configureRef\.current\)/)
})
