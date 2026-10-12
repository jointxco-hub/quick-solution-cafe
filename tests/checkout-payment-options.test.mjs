import test from 'node:test'
import assert from 'node:assert/strict'
import { build } from 'esbuild'
import { createRequire } from 'node:module'

// Run the real component's click handlers across rerenders. Replace only
// hooks/element creation and the API boundary; no network or payment writes.
const hookMock = `
const h = () => globalThis.__checkoutHooks
export function useState(initial) { const s=h(), i=s.index++; if (!(i in s.values)) s.values[i]=typeof initial==='function'?initial():initial; return [s.values[i],v=>{s.values[i]=typeof v==='function'?v(s.values[i]):v}] }
export function useRef(initial) { const s=h(),i=s.index++; return s.values[i]||(s.values[i]={current:initial}) }
export function useMemo(fn) { return fn() }
export function useEffect() {}
export default {createElement(type,props,...children){return {type,props:{...props,children}}}}
`
const apiMock = `
export const createQuickSolutionCartOrder=(...args)=>globalThis.__checkoutApi.create(...args)
export const beginQuickSolutionPayment=(...args)=>globalThis.__checkoutApi.pay(...args)
export const recordQuickSolutionPaymentIntent=()=>Promise.resolve({})
export const uploadQuickSolutionFile=()=>Promise.resolve({})
`
const bundle = await build({entryPoints:['src/components/OrderBasket.jsx'],bundle:true,write:false,format:'cjs',platform:'node',logLevel:'silent',plugins:[{name:'checkout-mocks',setup(b){
  b.onResolve({filter:/^react$/},()=>({path:'react',namespace:'mock'}))
  b.onResolve({filter:/supabaseApi\.js$/},()=>({path:'api',namespace:'mock'}))
  b.onLoad({filter:/.*/,namespace:'mock'},args=>({contents:args.path==='react'?hookMock:apiMock,loader:'js'}))
}}]})
const module={exports:{}}
new Function('module','exports','require',bundle.outputFiles[0].text)(module,module.exports,createRequire(import.meta.url))
const OrderBasket=module.exports.default
function nodes(node, result=[]) {
  if(Array.isArray(node)) {node.forEach(n=>nodes(n,result));return result}
  if(!node || typeof node!=='object')return result
  if(typeof node.type==='string')result.push(node)
  nodes(node.props?.children,result);return result
}
function textOf(node) {if(Array.isArray(node))return node.map(textOf).join(' ');if(node==null || typeof node==='boolean')return '';if(typeof node==='object')return textOf(node.props?.children);return String(node)}
async function submit(amount, rules={allowPayfast:true,allowPayAtCounter:true}) {
  globalThis.__checkoutHooks={index:0,values:[]}
  let items=[{cartId:'line-1',productId:'vinyl-stickers',name:'Vinyl Stickers & Labels',total:amount,quantity:1,config:{},paymentEligibility:rules}]
  const payCalls=[]
  globalThis.__checkoutApi={create:async()=>({orderId:'order-1',orderNumber:'QS-TEST',totalAmount:amount,paymentToken:'payment-token',deliveryFeeStatus:'not_required',items:[{clientItemKey:'line-1'}]}),pay:async(...args)=>{payCalls.push(args);return {paid:true}}}
  const render=()=>{globalThis.__checkoutHooks.index=0;return OrderBasket({items,open:true,onOrderCreated:()=>{items=[]}})}
  let tree=render()
  nodes(tree).find(n=>n.type==='button' && textOf(n)==='Checkout').props.onClick()
  tree=render()
  nodes(tree).find(n=>n.type==='input' && n.props.autoComplete==='name').props.onChange({target:{value:'Test Customer'}})
  nodes(tree).find(n=>n.type==='input' && n.props.autoComplete==='tel').props.onChange({target:{value:'0751234567'}})
  tree=render()
  await nodes(tree).find(n=>n.props.className?.includes('qs-place-order')).props.onClick()
  assert.equal(items.length,0,'parent cleared the live basket')
  return {tree:render(),payCalls}
}
test('R350 order retains its PayFast button after parent clears the basket',async()=>{
  const {tree,payCalls}=await submit(350)
  const pay=nodes(tree).find(n=>n.type==='button' && textOf(n).includes('securely'))
  assert.ok(pay,'PayFast option remains on success')
  assert.equal(pay.props.disabled,false)
  await pay.props.onClick()
  assert.deepEqual(payCalls,[['order-1','payment-token']])
  assert.match(textOf(tree),/One order\.\s+1\s+item\s*\./)
  const whatsapp=nodes(tree).find(n=>n.type==='a' && textOf(n).includes('WhatsApp'))
  assert.match(decodeURIComponent(whatsapp.props.href),/Vinyl Stickers/)
})
test('R2 order retains minimum explanation and pay-at-counter after clearing',async()=>{
  const {tree}=await submit(2)
  assert.equal(nodes(tree).some(n=>n.type==='button' && textOf(n).includes('securely')),false)
  assert.match(textOf(tree),/Card payment is available from/)
  assert.ok(nodes(tree).find(n=>n.type==='button' && textOf(n)==='Pay at counter'))
})
test('submitted product restrictions still hide PayFast above the minimum',async()=>{
  const {tree}=await submit(350,{allowPayfast:false,allowPayAtCounter:true})
  assert.equal(nodes(tree).some(n=>n.type==='button' && textOf(n).includes('securely')),false)
  assert.ok(nodes(tree).find(n=>n.type==='button' && textOf(n)==='Pay at counter'))
})
