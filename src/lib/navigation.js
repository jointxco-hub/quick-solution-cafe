// QS-18A — pure navigation-intent helpers for the Home/Shop view split.
//
// App.jsx owns the actual React state (page/shopFilter/selectedId/...)
// and is the only thing that ever calls setPage()/setShopFilter()/
// openGuided() etc - these functions only ever COMPUTE where a given
// action should lead, so that decision is unit-testable without
// rendering React. This repo's test suite is plain Node `--test` over
// pure .mjs modules with no jsdom/React-rendering harness (see QS-17C's
// note on FieldControl.jsx for the same reasoning) - extracting the
// decision this way is the smallest way to get real coverage of "which
// outcome goes where" without adding a rendering dependency.

// Home renders first, always - matches heroOutcomes/App.jsx's own
// useState('home') default. Exported so a test can assert the default
// without needing to render <App/>.
export const DEFAULT_PAGE = 'home'

// Given one of src/data/products.js's heroOutcomes entries, decides
// where it should navigate. Mirrors exactly the two kinds heroOutcomes
// already declares (see products.js's own comment above that array) -
// never invents a third kind or a new recommendation engine.
//
//   { type: 'shop', shopFilter }              - go to Shop, pre-filtered
//   { type: 'guided', productId, journeyId, preset } - open the guided
//                                                flow directly, bypassing
//                                                Shop's browsing UI
export function resolveHeroOutcomeNavigation(outcome) {
  if (!outcome) return null
  if (outcome.kind === 'shop') {
    return { type: 'shop', shopFilter: outcome.shopCategory || 'All' }
  }
  if (outcome.kind === 'guided') {
    return { type: 'guided', productId: outcome.productId, journeyId: outcome.journeyId, preset: outcome.preset || {} }
  }
  return null
}
