import test from 'node:test'
import assert from 'node:assert/strict'
import { getProjectsForSite, workProjects } from '../src/data/workProjects.js'

test('each project has a stable unique id and no media source invented', () => {
  assert.equal(new Set(workProjects.map(p => p.id)).size, workProjects.length)
  assert.ok(workProjects.every(p => p.mediaStatus !== 'placeholder' || p.media.length === 0))
})

test('QS only includes the three known projects marked as featured for QS', () => {
  assert.deepEqual(getProjectsForSite('qs').map(p => p.id), [
    'cue-corner-miss-sa-2026', 'brandon-dhludhlu-show-2026', 'leta-mbulu-merch-2025'
  ])
})

test('different sites can curate the same project without duplication', () => {
  const x1 = getProjectsForSite('x1')
  const qs = getProjectsForSite('qs')
  assert.ok(x1.some(p => p.id === 'brandon-dhludhlu-show-2026'))
  assert.ok(qs.some(p => p.id === 'brandon-dhludhlu-show-2026'))
  assert.equal(getProjectsForSite('invalid').length, 0)
})

test('unclear Uber Eats and Netflix scopes do not appear in QS showcase', () => {
  const ids = getProjectsForSite('qs').map(p => p.id)
  assert.ok(!ids.includes('uber-eats-project'))
  assert.ok(!ids.includes('netflix-project'))
})
