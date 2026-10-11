import test from 'node:test'
import assert from 'node:assert/strict'
import { createFileHandler } from '../supabase/functions/quick-solution-order-file/handler.js'
const id = '11111111-1111-4111-8111-111111111111'
const req = (body = {}, token = 'staff') => new Request('https://example.test/file', { method:'POST', headers: token ? { authorization:`Bearer ${token}` } : {}, body: JSON.stringify({ orderId:id, fileId:id, mode:'open', ...body }) })
function setup(responses) {
 const calls=[]
 const handler=createFileHandler({url:'https://project.supabase.co',anonKey:'anon',serviceKey:'secret',fetcher:async (...args)=>{calls.push(args);return responses.shift()}})
 return {handler,calls}
}
const ok = body => Response.json(body)
test('unsigned callers and server/anon keys cannot sign documents', async()=>{
 for(const token of [null,'anon','secret']) { const {handler,calls}=setup([]); assert.equal((await handler(req({},token))).status,401); assert.equal(calls.length,0) }
})
test('invalid sessions and unauthorized file requests never reach privileged storage',async()=>{
 let s=setup([new Response('',{status:401})]);assert.equal((await s.handler(req())).status,401);assert.equal(s.calls.length,1)
 s=setup([ok({id}),new Response('',{status:403})]);assert.equal((await s.handler(req())).status,403);assert.equal(s.calls.length,2)
})
test('file signing resolves path from authorized RPC and ignores injected path/expiry',async()=>{
 const {handler,calls}=setup([ok({id}),ok({bucket:'uploads',path:'tenant/order/my doc.pdf',name:'my doc.pdf',mime:'application/pdf'}),ok({signedURL:'/object/sign/uploads/tenant/order/my%20doc.pdf?token=short'})])
 const r=await handler(req({path:'other/private',expiresIn:99999})); assert.equal(r.status,200)
 assert.equal(calls[1][1].headers.Authorization,'Bearer staff')
 assert.deepEqual(JSON.parse(calls[1][1].body),{p_order_id:id,p_file_id:id})
 assert.match(calls[2][0],/tenant\/order\/my%20doc.pdf$/)
 assert.equal(JSON.parse(calls[2][1].body).expiresIn,120)
 const data=await r.json(); assert.equal(data.expiresIn,120);assert.match(data.url,/^https:\/\/project.supabase.co\/storage\/v1\/object\/sign\//)
 assert.equal(r.headers.get('cache-control'),'no-store')
})
test('non-viewable documents force download and signer failures do not leak details',async()=>{
 let s=setup([ok({id}),ok({bucket:'uploads',path:'t/f',name:'file.docx',mime:'application/vnd.openxmlformats-officedocument.wordprocessingml.document'}),ok({signedURL:'/object/sign/uploads/t/f?token=short'})]);assert.equal(new URL((await (await s.handler(req())).json()).url).searchParams.get('download'),'file.docx')
 s=setup([ok({id}),ok({bucket:'uploads',path:'t/f'}),new Response('internal secret',{status:500})]);const r=await s.handler(req());assert.equal(r.status,502);assert.doesNotMatch(await r.text(),/secret/)
})
test('invalid IDs and traversal paths are denied before signing',async()=>{
 let s=setup([ok({id})]);assert.equal((await s.handler(req({fileId:'bad'}))).status,400);assert.equal(s.calls.length,1)
 s=setup([ok({id}),ok({bucket:'uploads',path:'../other/file'})]);assert.equal((await s.handler(req())).status,404);assert.equal(s.calls.length,2)
})
