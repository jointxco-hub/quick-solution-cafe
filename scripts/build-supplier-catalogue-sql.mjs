import { writeFileSync, readdirSync } from 'node:fs'
import { supplierProducts } from '../src/data/supplierProducts.js'
import { buildPricingDefinition } from '../src/lib/pricingDefinition.js'
import { supplierOperations, supplierPricingDefinition } from './supplier-catalogue-reference-models.mjs'
const quote = value => `'${String(value).replaceAll("'", "''")}'`
const json = value => `${quote(JSON.stringify(value))}::jsonb`
const sql = []
for (const [index, product] of supplierProducts.entries()) {
  const operations = supplierOperations[product.id] || { rollout: 'quote-first', checkedAt: '2026-10-06', priceConfirmed: false, supplierCandidates: ['Flyerz', 'Printulu'], scope: 'Confirm matching specifications, delivered cost and installation before quoting.' }
  sql.push(`
insert into commerce.products (tenant_id,slug,name,description,currency,availability,status,source_system,source_ref)
select t.id,${quote(product.id)},${quote(product.name)},${quote(product.description)},'ZAR','available','published','quick_solution',${quote(product.id)}
from public.tenants t where t.slug='quick-solution'
and not exists (select 1 from commerce.products p where p.tenant_id=t.id and p.slug=${quote(product.id)});
insert into commerce.service_product_configs (tenant_id,product_id,source_key,customer_definition,pricing_version,pricing_definition,status,sort_order,operations_definition)
select t.id,p.id,${quote(product.id)},${json(product)},${quote(product.pricingVersion)},${json(supplierPricingDefinition(product, buildPricingDefinition))},'published',${150 + index},${json(operations)}
from public.tenants t join commerce.products p on p.tenant_id=t.id and p.slug=${quote(product.id)}
where t.slug='quick-solution' and not exists (select 1 from commerce.service_product_configs c where c.tenant_id=t.id and c.source_key=${quote(product.id)});
`)
}
writeFileSync('/tmp/cafe-catalogue-data.sql', sql.join('\n'))
console.log(`Generated ${supplierProducts.length} additive catalogue entries. Existing rows are preserved.`)
