import assert from 'node:assert/strict'
import test from 'node:test'
import { resolveNextGalleryIndex, resolvePrevGalleryIndex } from '../src/lib/gallery.js'

// ── QS-21.3 — lightbox/gallery index math ───────────────────────────────
// ProductHub.jsx owns the actual lightbox open/close state and the
// keydown (Escape/ArrowLeft/ArrowRight) listener - not unit-tested (no
// jsdom/React-rendering harness in this repo). These are the two pure
// index calculations that logic delegates to. DOM-level lightbox
// behavior (opening on main-image click, next/prev buttons, Escape,
// backdrop click, thumbnails still switching the image) was verified
// with a live dev server + Playwright - see the QS-21.3 report.

test('resolveNextGalleryIndex: advances by one', () => {
  assert.equal(resolveNextGalleryIndex(0, 4), 1)
  assert.equal(resolveNextGalleryIndex(2, 4), 3)
})

test('resolveNextGalleryIndex: wraps from the last image back to the first', () => {
  assert.equal(resolveNextGalleryIndex(3, 4), 0)
})

test('resolvePrevGalleryIndex: goes back by one', () => {
  assert.equal(resolvePrevGalleryIndex(3, 4), 2)
  assert.equal(resolvePrevGalleryIndex(1, 4), 0)
})

test('resolvePrevGalleryIndex: wraps from the first image back to the last', () => {
  assert.equal(resolvePrevGalleryIndex(0, 4), 3)
})

test('both: a gallery with zero/one image never throws and stays at 0', () => {
  assert.equal(resolveNextGalleryIndex(0, 0), 0)
  assert.equal(resolvePrevGalleryIndex(0, 0), 0)
  assert.equal(resolveNextGalleryIndex(0, 1), 0)
  assert.equal(resolvePrevGalleryIndex(0, 1), 0)
})
