import test from 'node:test'
import assert from 'node:assert/strict'
import { mapQsWorkRow, loadQsPublishedWork } from '../src/lib/qsPublishedWork.js'

test('maps a published direct MP4 with video poster', () => {
  const project = mapQsWorkRow({ id: 'one', title: 'Afro Nubian', category: 'Branding', qs_summary: 'ignored', summary: 'Counter branding', video_url: 'https://cdn.example.test/afro.mp4', video_thumbnail: 'https://cdn.example.test/poster.webp', qs_featured: true, qs_sort_order: 2 })
  assert.equal(project.media.kind, 'video')
  assert.equal(project.media.poster, 'https://cdn.example.test/poster.webp')
  assert.equal(project.subtitle, 'Counter branding')
  assert.equal(project.featured, true)
  assert.equal(project.sortOrder, 2)
})

test('maps YouTube with safe cover and external watch action', () => {
  const project = mapQsWorkRow({ id: 'two', title: 'QS Events', video_url: 'https://youtu.be/123', cover_image: 'https://cdn.example.test/cover.webp' })
  assert.equal(project.media.kind, 'image')
  assert.equal(project.media.externalVideo, 'https://youtu.be/123')
})

test('video-only external project has clickable video', () => {
  const project = mapQsWorkRow({ id: 'three', title: 'Cronynizer', video_url: 'https://vimeo.com/123' })
  assert.equal(project.media.kind, 'link')
})

test('rejects unsafe URLs and malformed records', () => {
  assert.equal(mapQsWorkRow(null), null)
  assert.equal(mapQsWorkRow({ id: 'missing-title' }), null)
  const project = mapQsWorkRow({ id: 'bad', title: 'Bad', cover_image: 'javascript:alert(1)', video_url: 'data:text/html,evil' })
  assert.equal(project.media, null)
  assert.equal(project.videoUrl, '')
})

test('no public key means no unauthenticated request', async () => {
  assert.deepEqual(await loadQsPublishedWork(), [])
})
