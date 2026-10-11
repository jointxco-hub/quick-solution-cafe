import test from 'node:test'
import assert from 'node:assert/strict'
import { prepareOrderDownload, saveOrderDownload } from '../src/admin/orderDownload.js'

const attachment = { id: 'file-id', name: 'Artwork final.jpg', mime: 'image/jpeg' }
test('download fetches authorized bytes and preserves the original filename and MIME', async () => {
  const controller = new AbortController()
  const file = await prepareOrderDownload({ orderId: 'order-id', attachment, signal: controller.signal,
    signFile: async (...args) => { assert.deepEqual(args, ['order-id', 'file-id', 'download']); return { url: 'https://files.test/signed' } },
    fetchFile: async (url, options) => {
      assert.equal(url, 'https://files.test/signed')
      assert.equal(options.signal, controller.signal)
      assert.equal(options.cache, 'no-store')
      return new Response('image bytes')
    }
  })
  assert.equal(file.name, attachment.name)
  assert.equal(file.type, attachment.mime)
  assert.equal(await file.text(), 'image bytes')
})
test('failed or aborted preparation cannot produce a savable error document', async () => {
  const controller = new AbortController()
  const args = { orderId: 'order-id', attachment, signal: controller.signal, signFile: async () => ({ url: 'https://files.test/signed' }) }
  await assert.rejects(prepareOrderDownload({ ...args, fetchFile: async () => new Response('expired', { status: 403 }) }), /Could not download/)
  controller.abort()
  await assert.rejects(prepareOrderDownload({ ...args, fetchFile: () => assert.fail('aborted request fetched') }), { name: 'AbortError' })
})
test('mobile Save starts file sharing synchronously in the click, without a popup or navigation', async () => {
  const file = new File(['data'], 'print.pdf', { type: 'application/pdf' })
  let shared = false
  const result = saveOrderDownload({ file, url: 'blob:prepared' }, {
    nav: { maxTouchPoints: 5, canShare: data => data.files[0] === file, share: data => { assert.equal(data.files[0], file); shared = true; return Promise.resolve() } },
    doc: { createElement: () => assert.fail('share must not create a link') }
  })
  assert.equal(shared, true, 'share starts before awaiting, while user activation is available')
  assert.equal(await result, 'shared')
})
test('share cancellation propagates and leaves the prepared file reusable', async () => {
  const prepared = { file: new File(['data'], 'print.pdf'), url: 'blob:prepared' }
  const nav = { maxTouchPoints: 1, canShare: () => true, share: () => Promise.reject(new DOMException('Cancelled', 'AbortError')) }
  await assert.rejects(saveOrderDownload(prepared, { nav, doc: {} }), { name: 'AbortError' })
  assert.equal(await prepared.file.text(), 'data')
})
test('desktop or unsupported sharing uses a blob download with the filename, without a new window', async () => {
  for (const nav of [{ maxTouchPoints: 0 }, { maxTouchPoints: 5, share() { assert.fail('unsupported sharing') }, canShare: () => false }]) {
    const events = []
    const link = { click() { events.push('clicked') }, remove() { events.push('removed') } }
    const doc = { createElement(tag) { assert.equal(tag, 'a'); return link }, body: { appendChild(node) { assert.equal(node, link); events.push('attached') } } }
    assert.equal(await saveOrderDownload({ file: new File(['data'], 'original.pdf'), url: 'blob:prepared' }, { nav, doc }), 'download')
    assert.equal(link.href, 'blob:prepared')
    assert.equal(link.download, 'original.pdf')
    assert.equal(link.target, undefined)
    assert.deepEqual(events, ['attached', 'clicked', 'removed'])
  }
})
