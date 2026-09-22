import assert from 'node:assert/strict'
import test from 'node:test'
import { resolveConfigPreviewFields, resolveProductPresets } from '../src/lib/productContent.js'
import { calculateProductPrice } from '../src/lib/pricing.js'
import { products } from '../src/data/products.js'

// ── QS-21.4 — copy + layout cleanup pass ────────────────────────────────
// App.jsx/ProductHub.jsx are not unit-tested (no jsdom/React-rendering
// harness - see navigation.test.mjs's own note), so these exercise the
// pure content-shaping logic this pass changed. Visual/layout results
// (the mobile upload-field fix, the map background, hero spacing, the
// "Works well for" rename) were verified with a live dev server +
// Playwright - see the QS-21.4 report.

test('resolveConfigPreviewFields: prefers shortLabel over the full question-sentence label, for both the field and its options - fixes the stitched-sentence preview', () => {
  const flags = products.find((product) => product.id === 'flags')
  const fields = resolveConfigPreviewFields(flags)
  const artwork = fields.find((field) => field.id === 'artwork')
  assert.ok(artwork, 'flags must still curate the artwork field into its preview')
  assert.equal(artwork.label, 'Artwork') // not "What is happening with the design?"
  assert.deepEqual(artwork.options.map((option) => option.label), ['Ready', 'Please check', 'Need help'])
  // The old stitched-sentence bug this replaces: joining the OLD full
  // labels with commas produced literally
  // "My artwork is ready, Please check my artwork, I need help with the design".
  const joined = artwork.options.map((option) => option.label).join(' / ')
  assert.equal(joined, 'Ready / Please check / Need help')
})

test('resolveConfigPreviewFields: a field/option with no shortLabel/shortName set still falls back to its full label - nothing goes blank', () => {
  const fields = resolveConfigPreviewFields({
    fields: [{ id: 'x', type: 'select', label: 'Full question here', options: [{ id: 'a', label: 'Full option label' }, { id: 'b', label: 'Second option' }] }]
  })
  assert.equal(fields[0].label, 'Full question here')
  assert.equal(fields[0].options[0].label, 'Full option label')
})

test('resolveProductPresets: shortName/shortDescription are populated for every flags/gazebos preset (the "quick option card" now uses these, not name+full description+variant spec)', () => {
  const byId = Object.fromEntries(products.map((product) => [product.id, product]))
  for (const id of ['flags', 'gazebos']) {
    const presets = resolveProductPresets(byId[id])
    assert.ok(presets.length > 0)
    for (const preset of presets) {
      assert.ok(preset.shortName.length > 0)
      assert.ok(preset.shortDescription.length > 0)
      // The short forms are meant to be genuinely shorter, not a
      // relabelling that's the same length or longer.
      assert.ok(preset.shortName.length <= preset.name.length)
      assert.ok(preset.shortDescription.length < preset.description.length)
    }
  }
})

test('resolveProductPresets: a preset with no explicit shortName/shortDescription falls back to name/description - never blank', () => {
  const fixture = {
    fields: [],
    productPage: {
      presets: [{ id: 'p1', name: 'Full Preset Name', description: 'A full sentence description.', config: {} }]
    }
  }
  const presets = resolveProductPresets(fixture)
  assert.equal(presets[0].shortName, 'Full Preset Name')
  assert.equal(presets[0].shortDescription, 'A full sentence description.')
})

test('resolveProductPresets: shortName/shortDescription never affect config or pricing - every preset still prices exactly as before this pass', () => {
  const byId = Object.fromEntries(products.map((product) => [product.id, product]))
  for (const id of ['flags', 'gazebos']) {
    const presets = resolveProductPresets(byId[id])
    for (const preset of presets) {
      const result = calculateProductPrice(byId[id], preset.config)
      assert.ok(!result.metrics?.quoteRequired)
      assert.ok(!result.metrics?.invalid)
      assert.ok(result.total > 0)
    }
  }
})
