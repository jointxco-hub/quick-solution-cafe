import test from 'node:test'
import assert from 'node:assert/strict'
import { resolveAppRoute, buildStorefrontPath, buildHistoryState } from '../src/lib/navigation.js'
import { buildShareLinks } from '../src/lib/productContent.js'

test('every generated product and configure URL restores the same product', () => {
  for (const id of ['vinyl-stickers', 'a4-print', 'business-cards', 'flags']) {
    const links = buildShareLinks({id, name: id}, {origin:'https://cafe.example'})
    for (const link of [links.productPageUrl, links.configureUrl]) {
      const url = new URL(link)
      const route = resolveAppRoute(url)
      assert.equal(route.view,'storefront')
      assert.equal(route.page,'product')
      assert.equal(route.productId,id)
      assert.equal(buildStorefrontPath(buildHistoryState(route.page, {selectedProductId:route.productId})),url.pathname)
    }
    assert.match(decodeURIComponent(links.whatsappUrl), new RegExp(links.productPageUrl))
  }
})
test('legacy configure paths remain supported and canonicalize to product routes', () => {
  const route = resolveAppRoute({pathname:'/configure/a4-print/'})
  assert.equal(route.productId,'a4-print')
  assert.equal(route.section,'configure')
  assert.equal(buildStorefrontPath(buildHistoryState(route.page,{selectedProductId:route.productId})),'/products/a4-print')
})
test('malformed product paths are rejected without throwing or interpreting nested routes', () => {
  for (const pathname of ['/products/%','/products/a%2Fb','/products/','/products/a/b','/products/%3Cscript%3E']) {
    assert.equal(resolveAppRoute({pathname}).view,'not-found')
  }
})
test('staff, tracking and storefront route ownership stays explicit', () => {
  for (const [pathname,view] of [['/admin','admin'],['/counter','counter'],['/track/token','track'],['/shop','storefront']]) {
    assert.equal(resolveAppRoute({pathname}).view,view)
  }
  assert.equal(resolveAppRoute({pathname:'/',hash:'#admin'}).view,'admin')
  assert.equal(buildStorefrontPath(buildHistoryState('home')),'/')
  assert.equal(buildStorefrontPath(buildHistoryState('shop')),'/shop')
})
