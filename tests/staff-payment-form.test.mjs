import test from 'node:test'
import assert from 'node:assert/strict'
import { build } from 'esbuild'
import { createRequire } from 'node:module'
const hooks=`export function useState(initial){const h=globalThis.__receiptHooks,i=h.index++;if(!(i in h.values))h.values[i]=initial;return[h.values[i],v=>h.values[i]=typeof v==='function'?v(h.values[i]):v]} export function useRef(value){return {current:value}} export function useEffect(effect){globalThis.__captureReceiptEffect?.(effect)} export default {createElement(type,props,...children){return{type,props:{...props,children}}}}`
const api=`export const getStaffPaymentState=()=>globalThis.__loadReceipt();export const recordStaffPayment=(payload)=>globalThis.__saveReceipt(payload)`
const b=await build({entryPoints:['src/admin/OrderPaymentState.jsx'],bundle:true,write:false,format:'cjs',platform:'node',plugins:[{name:'mock',setup(b){b.onResolve({filter:/^react$/},()=>({path:'react',namespace:'mock'}));b.onResolve({filter:/supabaseApi\.js$/},()=>({path:'api',namespace:'mock'}));b.onLoad({filter:/.*/,namespace:'mock'},a=>({contents:a.path==='react'?hooks:api,loader:'js'}))}}]})
const m={exports:{}};new Function('module','exports','require',b.outputFiles[0].text)(m,m.exports,createRequire(import.meta.url));const Component=m.exports.default
const nodes=n=>Array.isArray(n)?n.flatMap(nodes):n&&typeof n==='object'?[n,...nodes(n.props?.children)]:[]
const txt=n=>Array.isArray(n)?n.map(txt).join(''):n&&typeof n==='object'?txt(n.props?.children):n==null||typeof n==='boolean'?'':String(n)
const button=(tree,label)=>nodes(tree).find(n=>n.type==='button'&&txt(n)===label)
const state={balanceDue:5,cafePaid:0,oppsPaid:null,receipts:[],reviewRequired:false,closed:false}
function setup(patch={}){globalThis.__receiptHooks={index:0,values:[{...state,...patch},'',0,false]};let changed=0;return{render:()=>{globalThis.__receiptHooks.index=0;return Component({orderId:'order-test',onChanged:()=>changed++})},changed:()=>changed}}
test('receipt requires confirmation and retries retain the same operation key',async()=>{
 const h=setup(),calls=[];let fail=true
 globalThis.__saveReceipt=async p=>{calls.push(p);if(fail)throw Error('Network interrupted');return{payment:{...state,balanceDue:0,cafePaid:5}}}
 button(h.render(),'Record payment').props.onClick()
 let tree=h.render();await nodes(tree).find(n=>n.type==='form').props.onSubmit({preventDefault(){}});assert.equal(calls.length,0)
 nodes(tree).find(n=>n.type==='input'&&n.props.type==='checkbox').props.onChange({target:{checked:true}})
 tree=h.render();await nodes(tree).find(n=>n.type==='form').props.onSubmit({preventDefault(){}})
 assert.match(txt(h.render()),/Network interrupted/)
 fail=false;await nodes(h.render()).find(n=>n.type==='form').props.onSubmit({preventDefault(){}})
 assert.equal(calls.length,2);assert.equal(calls[0].operationKey,calls[1].operationKey)
 assert.equal(calls[0].amount,5);assert.equal(calls[0].method,'cash');assert.equal(h.changed(),1)
 assert.equal(button(h.render(),'Record payment'),undefined)
})
test('unreconciled and closed orders offer no payment recording',()=>{
 for(const patch of [{reviewRequired:true,balanceDue:null},{closed:true}])assert.equal(button(setup(patch).render(),'Record payment'),undefined)
})
test('EFT selection requires a bank reference and renewed receipt confirmation',()=>{
 const h=setup();button(h.render(),'Record payment').props.onClick();let tree=h.render()
 nodes(tree).find(n=>n.type==='input'&&n.props.type==='checkbox').props.onChange({target:{checked:true}})
 tree=h.render();nodes(tree).find(n=>n.type==='select').props.onChange({target:{value:'eft'}})
 tree=h.render();assert.match(txt(tree),/verified that the money arrived/)
 assert.equal(nodes(tree).find(n=>n.type==='input'&&n.props.maxLength===120).props.required,true)
 assert.equal(button(tree,'Confirm payment received').props.disabled,true)
})

test('payment refresh follows focus and polling, skips hidden pages and cleans up', async () => {
 const h=setup(); const events=new Map(); let tick,cleanup,calls=0
 const oldWindow=globalThis.window,oldDocument=globalThis.document
 globalThis.window={setInterval(fn,delay){assert.equal(delay,15000);tick=fn;return 1},clearInterval(){tick=null},addEventListener(n,fn){events.set(n,fn)},removeEventListener(n){events.delete(n)}}
 globalThis.document={hidden:false,addEventListener(n,fn){events.set(n,fn)},removeEventListener(n){events.delete(n)}}
 globalThis.__captureReceiptEffect=effect=>{cleanup=effect()}
 globalThis.__loadReceipt=async()=>{calls++;return {...state,balanceDue:calls===1?5:0,cafePaid:calls===1?0:5}}
 const settle=()=>new Promise(resolve=>setImmediate(resolve))
 try {
  h.render();delete globalThis.__captureReceiptEffect;await settle()
  assert.ok(button(h.render(),'Re-check payments'));assert.equal(calls,1)
  events.get('focus')();await settle();assert.equal(calls,2);assert.equal(h.changed(),1)
  assert.equal(button(h.render(),'Record payment'),undefined)
  document.hidden=true;tick();await settle();assert.equal(calls,2)
  document.hidden=false;events.get('visibilitychange')();await settle();assert.equal(calls,3)
  cleanup();assert.equal(events.size,0);assert.equal(tick,null)
 } finally {delete globalThis.__captureReceiptEffect;globalThis.window=oldWindow;globalThis.document=oldDocument}
})
