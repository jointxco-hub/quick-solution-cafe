import test from 'node:test'
import assert from 'node:assert/strict'
import { mergeOrderActivity } from '../src/admin/orderActivity.js'
import { resolveConfiguratorPreviewImage } from '../src/lib/configuratorVisuals.js'
test('late view response cannot erase a newer acknowledgement',()=>{
 const view={actorId:'one',event:'viewed',at:'2026-10-11T01:00:00Z'}
 const ack={actorId:'two',event:'acknowledged',at:'2026-10-11T01:01:00Z'}
 assert.deepEqual(mergeOrderActivity([view,ack],[view]),[view,ack])
 assert.deepEqual(mergeOrderActivity([view],[view]),[view])
})
test('order imagery reflects chosen flag style and default document service',()=>{
 assert.equal(resolveConfiguratorPreviewImage({id:'flags'},{variantAxis_style:'sharkfin'}),'/qs21/flags-shark-fin-pair.webp')
 assert.equal(resolveConfiguratorPreviewImage({id:'a4-print'},{}),'/qs11/product-document-printing-clean.webp')
})
