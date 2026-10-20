import test from 'node:test'
import assert from 'node:assert/strict'
import { portfolioProjectPath, resolvePortfolioPath, visiblePortfolioProjects } from '../src/lib/portfolio.js'

test('portfolio URLs are canonical and reject invalid slugs', () => {
  assert.equal(portfolioProjectPath('printed-tshirts'), '/our-work/printed-tshirts')
  assert.equal(portfolioProjectPath('../admin'), null)
  assert.deepEqual(resolvePortfolioPath('/our-work/'), { page: 'listing' })
  assert.deepEqual(resolvePortfolioPath('/our-work/printed-tshirts'), { page: 'project', slug: 'printed-tshirts' })
  assert.equal(resolvePortfolioPath('/our-work/../admin'), null)
})

test('only published linked work is returned', () => {
  const projects = [
    { slug: 'draft', status: 'draft', productKeys: ['shirts'], categorySlugs: ['apparel'] },
    { slug: 'live', status: 'published', productKeys: ['shirts', 'stickers'], categorySlugs: ['apparel'] },
    { slug: 'other', status: 'published', productKeys: ['cards'], categorySlugs: ['print'] }
  ]
  assert.deepEqual(visiblePortfolioProjects(projects, { productKey: 'shirts' }).map(p => p.slug), ['live'])
  assert.deepEqual(visiblePortfolioProjects(projects, { categorySlug: 'print' }).map(p => p.slug), ['other'])
})
