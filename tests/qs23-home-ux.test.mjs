import test from 'node:test'
import assert from 'node:assert/strict'
import fs from 'node:fs'
import { SHOP_CATEGORIES, filterProductsByShopCategory } from '../src/lib/productContent.js'
import { products } from '../src/data/products.js'

const root = new URL('../src/', import.meta.url)
const app = fs.readFileSync(new URL('App.jsx', root), 'utf8')
const categories = fs.readFileSync(new URL('components/HomeServiceCategories.jsx', root), 'utf8')
const styles = fs.readFileSync(new URL('styles/qs23-home-ux.css', root), 'utf8')

test('home hero offers precisely two primary choices wired to existing flows', () => {
  assert.match(app, /className="qs23-cta qs23-cta-primary" onClick=\{goShop\}/)
  assert.match(app, /className="qs23-cta qs23-cta-secondary" onClick=\{openDocumentPrinting\}/)
  assert.match(app, /<HomeServiceCategories onDocuments=\{openDocumentPrinting\}/)
  assert.doesNotMatch(app.slice(app.indexOf('<section className="hero shell qs18-hero qs23-hero">'), app.indexOf('<HomeServiceCategories')), /<form|<input/)
})

test('four service choices use existing catalogue buckets and real routes', () => {
  assert.equal((categories.match(/id: '/g) || []).length, 4)
  assert.match(categories, /filter: 'Apparel'/)
  assert.match(categories, /filter: 'Signs & Advertising'/)
  assert.match(categories, /filter: 'Events'/)
  for (const filter of ['Apparel', 'Signs & Advertising', 'Events']) {
    assert.ok(SHOP_CATEGORIES.includes(filter), `Missing category ${filter}`)
    assert.ok(filterProductsByShopCategory(products, filter).length > 0, `Empty category ${filter}`)
  }
  assert.match(categories, /onDocuments\(\)/)
  assert.match(categories, /onCategory\(service\.filter\)/)
})

test('homepage category actions use product mode rather than surprise offers', () => {
  assert.match(app, /setShopFilter\(filter\)\s+setShopMode\('products'\)\s+goShop\(\)/)
})

test('no giant inherited hero height and mobile layout supports narrow screens', () => {
  assert.match(styles, /\.qs23-hero\s*\{[^}]*min-height:\s*0/)
  assert.match(styles, /@media \(max-width: 620px\)/)
  assert.match(styles, /grid-template-columns: repeat\(2,minmax\(0,1fr\)\)/)
})

test('homepage changes avoid touching pricing and payment code', () => {
  const hero = app.slice(app.indexOf('<section className="hero shell qs18-hero qs23-hero">'), app.indexOf('<FeaturedWork site="qs"/>'))
  assert.doesNotMatch(hero, /PayFast|checkout|pricingStrategy|paymentEligibility/i)
})
