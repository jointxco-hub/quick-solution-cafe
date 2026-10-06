import assert from 'node:assert/strict'
import test from 'node:test'
import fs from 'node:fs'
import { products, guidedJourneys } from '../src/data/products.js'
import { supplierProducts } from '../src/data/supplierProducts.js'
import { baselineProducts } from './helpers/baseline-catalogue.mjs'
import { calculateProductPrice, getDefaultConfig } from '../src/lib/pricing.js'
import { buildPricingDefinition } from '../src/lib/pricingDefinition.js'
import { resolveCounterProduct } from '../src/lib/counterCatalogue.js'
import { supplierPricingDefinition, supplierOperations } from '../scripts/supplier-catalogue-reference-models.mjs'
import { isCounterSubmissionEnabled } from '../src/lib/counterSubmissionReadiness.js'
import { contravisionQuotePreset } from '../src/lib/contravisionAddons.js'
globalThis.File ??= class File {}
const product = supplierProducts.find(p => p.id === 'contravision')
const quoteKeys = ['flyers','pull-up-banners','car-magnets','posters','rigid-signage']
test('all 7 additions exist once; original order and identity remain intact', () => {
  assert.equal(supplierProducts.length,7)
  assert.equal(products.length,baselineProducts.length+7)
  assert.equal(new Set(products.map(p=>p.id)).size,products.length)
  assert.deepEqual(products.slice(0,12),baselineProducts)
  assert.deepEqual(supplierProducts.filter(p=>p.pricing.strategy==='ENQUIRY').map(p=>p.id),quoteKeys)
})
test('every new product has a usable journey and only known fields', () => {
  for(const p of supplierProducts){
    const j=guidedJourneys.find(j=>j.id===p.guidedJourneyId)
    assert.equal(j?.productId,p.id)
    assert.equal(j.steps.at(-1).type,'review')
    for(const step of j.steps) for(const id of step.fields||[]) assert.ok(p.fields.some(f=>f.id===id),`${p.id}: ${id}`)
  }
})
test('application-only and Car Contravision requests retain distinct scope and cannot become paid print orders', () => {
  const signage=supplierProducts.find(p=>p.id==='rigid-signage')
  for (const jobType of ['window-application','vehicle-contravision']) {
    const preset=contravisionQuotePreset(jobType)
    assert.equal(preset.supplyScope,jobType==='window-application'?'application-only':'print-and-application')
    assert.equal(preset.material,'contravision')
    assert.equal(preset.installation,'install')
    for(const [id,value] of Object.entries(preset)) assert.ok(signage.fields.find(f=>f.id===id)?.options.some(o=>o.id===value))
    assert.equal(calculateProductPrice(signage,getDefaultConfig(signage,preset)).metrics.quoteRequired,true)
  }
  assert.throws(()=>contravisionQuotePreset('unknown'))
  const removed=['folded-leaflets','booklets','notepads','presentation-folders','calendars','contravision-installation']
  for(const id of removed) assert.equal(products.some(p=>p.id===id),false)
})
test('unverified supplier products remain quote required, never free or payable', () => {
  for(const p of supplierProducts.filter(p=>!['contravision','correx-boards'].includes(p.id))){
    const r=calculateProductPrice(p,getDefaultConfig(p))
    assert.equal(r.metrics.quoteRequired,true)
    assert.equal(r.total,0)
    assert.equal(buildPricingDefinition(p).quoteRequired,true)
    assert.equal(p.channels.advanced,false)
    assert.equal(p.channels.pos,false)
    assert.match(r.lines[0].text,/Print \/ signage/)
  }
})
test('print-only area price follows the model, artwork fees and disclosed minimum', () => {
  const base=getDefaultConfig(product)
  assert.equal(calculateProductPrice(product,base).total,300)
  assert.equal(calculateProductPrice(product,{...base,width:2,height:1,artwork:'design'}).total,850)
  assert.equal(calculateProductPrice(product,{...base,width:0.5,height:0.5}).total,300)
  assert.equal(buildPricingDefinition(product).baseRate,300)
  for(const bad of [null,'',0,-1,21,'abc',Infinity,NaN]) assert.equal(calculateProductPrice(product,{...base,width:bad}).metrics.invalid,true)
})
test('customer definitions contain no supplier cost, margin or private source fields', () => {
  assert.doesNotMatch(JSON.stringify(supplierProducts),/supplierCost|sourceUrl|marginRate|pricingDefinition/)
})
test('counter rollout is deliberate: print preview only; quotations remain storefront-led', () => {
  assert.equal(resolveCounterProduct(product).visible,true)
  assert.equal(isCounterSubmissionEnabled(resolveCounterProduct(product)),false)
  for(const p of supplierProducts.filter(p=>!['contravision','correx-boards'].includes(p.id))) assert.equal(resolveCounterProduct(p).visible,false)
})
test('print enquiries do not demand media dates or shoot addresses', () => {
  const s=fs.readFileSync(new URL('../src/components/GuidedOrder.jsx',import.meta.url),'utf8')
  assert.match(s,/if \(isMediaRequest && !config.preferredDate\)/)
  assert.match(s,/if \(isMediaRequest && config.shootLocation/)
  assert.match(s,/Send quote request/)
})

test('migration retains the private pricing delegate and classifies print requests', () => {
  const sql=fs.readFileSync(new URL('../supabase/migrations/20261006181706_supplier_catalogue_signage.sql',import.meta.url),'utf8')
  assert.match(sql,/revoke all on function commerce\.qs_calculate_price_catalogue_base\(uuid,text,jsonb\) from public,anon,authenticated;/)
  assert.match(sql,/v_result := commerce\.qs_calculate_price_catalogue_base\(p_tenant_id,p_product_key,p_configuration\);/)
  assert.match(sql,/then 'print_signage' when v_strategy = 'PHOTOGRAPHY_SESSION'/)
  assert.doesNotMatch(sql.replace(/--[^\n]*/g,''),/grant |disable row level security/i)
})

test('Correx standard sizes follow the owner cost allowance and 50% gross margin', () => {
  const p=supplierProducts.find(p=>p.id==='correx-boards')
  const def=supplierPricingDefinition(p,buildPricingDefinition)
  for(const [variant,expected] of [['a3',87.5],['a2',175],['a1',350],['a0',700]]) {
    assert.equal(calculateProductPrice(p,{...getDefaultConfig(p),variant}).total,expected)
    assert.equal(calculateProductPrice(p,{...getDefaultConfig(p),variant,quantity:2,artwork:'design'}).total,expected*2+250)
    assert.equal(def.variants[variant].referencePrice/(1-def.marginRate),expected)
  }
  for(const quantity of [0,-1,1.5,10001,'abc',Infinity,NaN,'']) assert.equal(calculateProductPrice(p,{...getDefaultConfig(p),quantity}).metrics.invalid,true)
  for(const extra of [{sides:'double'},{mounting:'eyelets'},{installation:'install'},{width:1},{size:'custom'}]) assert.equal(calculateProductPrice(p,{...getDefaultConfig(p),...extra}).metrics.invalid,true)
  assert.equal(supplierOperations['correx-boards'].reportedA0PriceConfirmed,false)
  assert.equal(supplierOperations['correx-boards'].a0CostAllowance,350)
  assert.equal(supplierOperations.contravision.vatRate,0)
  assert.equal(supplierOperations.contravision.supplierCost,150)
})

test('removed listings are archived with every channel disabled, preserving historical rows', () => {
  const sql=fs.readFileSync(new URL('../supabase/migrations/20261006202950_refine_signage_catalogue_application_addons.sql',import.meta.url),'utf8')
  assert.match(sql,/status='archived'/)
  assert.match(sql,/"active":false,"channels":\{"storefront":false,"guided":false,"advanced":false,"pos":false,"quote":false\}/)
  for(const id of ['folded-leaflets','booklets','notepads','presentation-folders','calendars','contravision-installation']) assert.ok(sql.includes("'"+id+"'"))
  assert.doesNotMatch(sql,/\bdelete\s+from|\bdrop\b/i)
})
