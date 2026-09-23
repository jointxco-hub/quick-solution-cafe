import React, { useEffect, useMemo, useState } from 'react'
import Icon from './Icon.jsx'
import ProductScene from './ProductScene.jsx'
import ProductSupportInfo from './ProductSupportInfo.jsx'
import { calculateProductPrice, formatMoney } from '../lib/pricing.js'
import {
  resolveProductMedia,
  resolveProductPageContent,
  resolveConfigPreviewFields,
  resolveArtworkGuidance,
  deriveRelatedProducts,
  resolveProductPriceCue,
  resolveHubAvailability,
  resolveProductPresets,
  resolveProductDisplayName,
  buildShareLinks
} from '../lib/productContent.js'
import { resolveQuickConfigureEligibility } from '../lib/navigation.js'
import { resolveRelatedDisclosureState } from '../lib/relatedContent.js'
import { resolveNextGalleryIndex, resolvePrevGalleryIndex } from '../lib/gallery.js'

// QS-16 — generic Product Hub / Product Detail page.
//
// This is the visual/sales layer that sits between the product grid and
// the existing configurators — it does NOT fork or replace
// ProductConfigurator.jsx or GuidedOrder.jsx. Every "Configure"/"Guided
// order" action here calls straight into the handlers App.jsx already
// passes down (openAdvanced/openGuided, unchanged), and every price
// shown is computed by calling calculateProductPrice()/getDefaultConfig()
// from ../lib/pricing.js directly — nothing here reimplements pricing or
// reads a private/staff-only field. Built generic-first: every section
// reads from resolveProductPageContent()/resolveConfigPreviewFields()
// etc (src/lib/productContent.js), which fall back gracefully for any
// product that has not been given curated productPage content yet, so
// this same component already works for every product in the catalogue,
// not just vinyl-stickers.
//
// QS-17: `onGuided`/`onConfigure` now optionally accept a preset config
// argument (`onGuided(presetConfig)`/`onConfigure(presetConfig)`) - the
// plain hero CTAs still call them with no argument (unchanged, existing
// behavior), while the Presets section's "Choose this"/"Customise"
// buttons call them WITH a preset's config. No new App.jsx state or
// prop was introduced for this - openAdvanced/openGuided already accept
// a `nextPreset` argument (used since QS-16 for related-product/
// continue-from-advanced handoffs), so passing a preset's config through
// these same two existing props reuses that exact mechanism.
//
// QS-21.3 — reworked into a real PDP layout: a sticky media/gallery
// column on the left, a compact title+CTA+quick-facts column on the
// right (was copy-left/media-right, and "Good to know"/"Choices you
// will make" lived much further down the page, each a full heavy
// section - see the QS-21.3 report for the before/after). Also adds
// lightbox behavior for the existing gallery - no new pricing/config
// logic anywhere in this pass.
export default function ProductHub({ product, catalog = [], mode = 'simple', onConfigure, onGuided, onSelectRelated, onQuickConfigure, configureInView = false, overlayOpen = false }) {
  const [galleryIndex, setGalleryIndex] = useState(0)
  const [mediaFailed, setMediaFailed] = useState(false)
  const [lightboxOpen, setLightboxOpen] = useState(false)
  // QS-21.1: which related-product row (if any) is expanded into its
  // local disclosure preview - see resolveRelatedDisclosureState()
  // (src/lib/relatedContent.js) for the "only one at a time" rule. Reset
  // on product change so switching products never leaves a stale card
  // expanded for a related list that's about to be replaced.
  const [expandedRelatedId, setExpandedRelatedId] = useState(null)
  const [ctaRegionInView, setCtaRegionInView] = useState(true)

  useEffect(() => {
    setGalleryIndex(0)
    setMediaFailed(false)
    setExpandedRelatedId(null)
    setLightboxOpen(false)
  }, [product?.id])


  // Keep the fixed mobile CTA inside the primary PDP region. It leaves
  // before Quick options, support and related content can pass beneath it.
  useEffect(() => {
    const node = document.querySelector('.product-hub-pdp')
    if (!node || typeof IntersectionObserver === 'undefined') return
    const observer = new IntersectionObserver(
      ([entry]) => setCtaRegionInView(entry.isIntersecting),
      { rootMargin: '-68px 0px -18% 0px', threshold: 0 }
    )
    observer.observe(node)
    return () => observer.disconnect()
  }, [product?.id])
  const media = useMemo(() => resolveProductMedia(product), [product])
  const content = useMemo(() => resolveProductPageContent(product), [product])
  const previewFields = useMemo(() => resolveConfigPreviewFields(product), [product])
  const artwork = useMemo(() => resolveArtworkGuidance(product), [product])
  const related = useMemo(() => deriveRelatedProducts(product, catalog, 3), [product, catalog])
  const shareLinks = useMemo(() => buildShareLinks(product, {
    origin: typeof window !== 'undefined' ? window.location.origin : ''
  }), [product])

  // Correction: a monetary "From R..." cue is opt-in only
  // (productPage.showStartingPrice === true) - a product's default
  // configuration is not necessarily its cheapest valid one, so merely
  // having a pricing object is not enough to justify a starting-price
  // claim. ENQUIRY products always get "Get a quote" - see
  // resolveProductPriceCue() (src/lib/productContent.js) for the full
  // reasoning. QS-21.1: also reused, unchanged, by App.jsx's sticky
  // Configure affordance - one shared computation, not two.
  const priceCue = useMemo(() => resolveProductPriceCue(product), [product])

  // QS-17: resolveProductPresets() already guarantees every entry here
  // is both structurally safe and semantically valid against this
  // product's real field/option/accessory catalog (see
  // validatePresetConfig() in productContent.js) - nothing further to
  // check before rendering a card. Each preset's OWN price (shown only
  // "if and only if calculateProductPrice can safely return it" per
  // spec) is computed directly from the preset's saved config - never
  // stored on the preset itself, never a second pricing implementation.
  const presets = useMemo(() => resolveProductPresets(product), [product])
  const presetPrices = useMemo(() => {
    const prices = {}
    for (const preset of presets) {
      try {
        const result = calculateProductPrice(product, preset.config)
        prices[preset.id] = result?.metrics?.quoteRequired || result?.metrics?.invalid ? null : result.total
      } catch {
        prices[preset.id] = null
      }
    }
    return prices
  }, [presets, product])

  if (!product) return null

  const galleryImages = media.hero ? [media.hero, ...media.gallery.filter((src) => src !== media.hero)] : media.gallery
  const activeImage = !mediaFailed ? (galleryImages[galleryIndex] || galleryImages[0] || null) : null
  // Correction: metadata (channels.guided/guidedJourneyId) alone is not
  // enough - App.jsx can pass onGuided=null when no matching local
  // guided journey actually exists, and a button that looks active with
  // no handler is a dead end. Hero actions AND the mobile sticky CTA
  // both read from this same resolveHubAvailability() call so they can
  // never disagree.
  const { hasGuided, hasAdvanced } = resolveHubAvailability(product, { onGuided, onConfigure })

  // Correction: clicking a thumbnail must be able to recover from a
  // previous image failure - mediaFailed is reset here, before the
  // index changes, not left stuck true forever once any one image 404s.
  const selectGalleryImage = (index) => {
    setMediaFailed(false)
    setGalleryIndex(index)
  }

  // QS-21.3 — lightbox. Only ever opens for a real photo (activeImage) -
  // the ProductScene placeholder has nothing to zoom into. Next/Prev
  // reuse the exact same selectGalleryImage() path the thumbnails use
  // (resets mediaFailed the same way), so the lightbox and the inline
  // gallery can never disagree about which image is "current" - one
  // index, one source of truth.
  const openLightbox = () => { if (activeImage) setLightboxOpen(true) }
  const closeLightbox = () => setLightboxOpen(false)
  const showNextImage = () => selectGalleryImage(resolveNextGalleryIndex(galleryIndex, galleryImages.length))
  const showPrevImage = () => selectGalleryImage(resolvePrevGalleryIndex(galleryIndex, galleryImages.length))

  useEffect(() => {
    if (!lightboxOpen) return
    const onKeyDown = (event) => {
      if (event.key === 'Escape') closeLightbox()
      else if (event.key === 'ArrowRight') showNextImage()
      else if (event.key === 'ArrowLeft') showPrevImage()
    }
    window.addEventListener('keydown', onKeyDown)
    return () => window.removeEventListener('keydown', onKeyDown)
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [lightboxOpen, galleryIndex, galleryImages.length])

  return (
    <section id="product" className="shell product-hub">
      {/* QS-21.3 — real PDP layout: sticky media/gallery on the left,
          title/price/CTA/quick-facts on the right (desktop only - see
          qs21-3-product-detail.css; mobile stacks in this same DOM
          order, media first, same as it already did). "Good to know"
          and "Choices you will make" moved up here from much further
          down the page and compacted (pills / one line per field
          instead of a full bulleted list and a full options grid) -
          same truthful content, no invented copy, just less of it
          before the customer can actually act. */}
      <div className="product-hub-pdp">
        {/* 1 — Media / gallery */}
        <div className="product-hub-pdp-media">
          <div
            className={`product-hub-media-frame${activeImage ? ' has-lightbox' : ''}`}
            role={activeImage ? 'button' : undefined}
            tabIndex={activeImage ? 0 : undefined}
            aria-label={activeImage ? `View larger photo of ${product.name}` : undefined}
            onClick={activeImage ? openLightbox : undefined}
            onKeyDown={activeImage ? (event) => { if (event.key === 'Enter' || event.key === ' ') { event.preventDefault(); openLightbox() } } : undefined}
          >
            {activeImage ? (
              <img src={activeImage} alt={product.name} loading="lazy" onError={() => setMediaFailed(true)}/>
            ) : (
              <ProductScene productId={product.id} className="product-hub-scene"/>
            )}
            {activeImage && (
              <span className="product-hub-media-zoom" aria-hidden="true">
                <Icon name="arrowUpRight" size={15}/> Enlarge
              </span>
            )}
          </div>
          {galleryImages.length > 1 && (
            <div className="product-hub-thumbs" role="tablist" aria-label={`${product.name} photos`}>
              {galleryImages.map((src, index) => (
                <button
                  key={src}
                  type="button"
                  role="tab"
                  aria-selected={index === galleryIndex}
                  className={index === galleryIndex ? 'active' : ''}
                  onClick={() => selectGalleryImage(index)}
                >
                  <img src={src} alt="" loading="lazy"/>
                </button>
              ))}
            </div>
          )}
        </div>

        {/* 2 — Title / price / CTAs / quick facts */}
        <div className="product-hub-pdp-info">
          <span className="eyebrow">{product.category}</span>
          <h2>{content.headline}</h2>
          <p className="product-hub-intro">{content.intro}</p>

          {priceCue && (
            <p className="product-hub-price-cue">
              {priceCue.quoteRequired ? 'Get a quote' : <>From <strong>{formatMoney(priceCue.total)}</strong></>}
            </p>
          )}

          <div className="product-hub-hero-actions">
            {hasGuided && (
              // QS-17: called with no argument, explicitly - onGuided
              // now optionally accepts a preset config (see the Presets
              // section below), and onClick={onGuided} directly would
              // pass the DOM click event as that argument instead.
              <button type="button" className="button dark" onClick={() => onGuided()}>
                Start guided order <Icon name="arrowRight" size={17}/>
              </button>
            )}
            {hasAdvanced && (
              <button type="button" className={`button ${hasGuided ? 'ghost' : 'dark'}`} onClick={() => onConfigure()}>
                {hasGuided ? 'Full options' : 'Configure'} <Icon name="arrowUpRight" size={16}/>
              </button>
            )}
            <a className="button ghost product-hub-whatsapp" href={shareLinks.whatsappUrl} target="_blank" rel="noreferrer">
              <Icon name="message" size={16}/> WhatsApp help
            </a>
          </div>

          {/* QS-21.1 section 7 / QS-21.3: the one compact trust row - now
              the ONLY trust mention on Product Detail (the separate full
              4-card trust strip App.jsx used to render lower down the
              page was removed as duplication, per this pass's brief). */}
          <ul className="product-hub-trust-compact">
            <li><Icon name="checkCircle" size={14}/> Secure checkout</li>
            <li><Icon name="store" size={14}/> Collect locally</li>
            <li><Icon name="truck" size={14}/> Courier or delivery</li>
            <li><Icon name="document" size={14}/> Artwork checked</li>
          </ul>

          {/* QS-21.3: "Good to know" compacted from a bulleted, icon-per-
              row list into inline fact pills - same facts, a fraction of
              the vertical space. */}
          {content.highlights.length > 0 && (
            <ul className="product-hub-quickfacts">
              {content.highlights.map((highlight) => (
                <li key={highlight.label}><Icon name="checkCircle" size={13}/> {highlight.label}</li>
              ))}
            </ul>
          )}

          {/* QS-21.3: "Choices you will make" compacted from a full grid
              of one block + a wrapped row of option chips PER FIELD, down
              to one line per field ("Label — option, option, option").
              Every option is still listed (truthful, nothing hidden) -
              the configurator itself remains the place to actually
              choose, per this pass's brief. */}
          {previewFields.length > 0 && (
            <div className="product-hub-quickchoices">
              <strong>You will choose:</strong>
              <ul>
                {previewFields.map((field) => (
                  <li key={field.id}>
                    <span>{field.label}</span> — {field.options.map((option) => option.label).join(' / ')}
                  </li>
                ))}
              </ul>
            </div>
          )}
        </div>
      </div>

      {/* QS-17 — Quick options / Quick Presets. Only renders when the
          product actually has valid presets - products without any
          render exactly as they did before this section existed. Kept
          full-width (outside the sticky PDP grid above) so the
          horizontal rail (QS-21.1) still has room for 3-4 comfortable
          cards, not squeezed into a half-width column. */}
      {presets.length > 0 && (
        <div className="product-hub-presets">
          <h3>Quick options</h3>
          <div className="product-hub-preset-grid">
            {presets.map((preset) => {
              const price = presetPrices[preset.id]
              return (
                <div key={preset.id} className="product-hub-preset-card">
                  {/* QS-21.4: a quick-option card now shows only ONE
                      support line (preset.shortDescription) - the full
                      variant spec (composeVariantSummary, e.g. "Steel —
                      2m × 2m — Full kit (print + system + carry bag +
                      toolkit)") and the full sentence description used
                      to BOTH render here at once, on top of the title -
                      the "detailed wording" now lives only in the
                      product detail content above and the configurator
                      itself, per this pass's brief. shortName/
                      shortDescription are curated per preset (see
                      resolveProductPresets, productContent.js) and fall
                      back to the existing name/description for any
                      preset without a short form. */}
                  <strong>{preset.shortName}</strong>
                  {preset.shortDescription && <p>{preset.shortDescription}</p>}
                  {price != null && <p className="product-hub-preset-price">{formatMoney(price)}</p>}
                  <div className="product-hub-preset-actions">
                    {/* "Choose this": the fast path - Guided when
                        available (pre-filled, walks the remaining
                        steps), otherwise Advanced. Does not add to cart
                        directly - QS-17 scope stops at handing the
                        preset's config into the existing configurator,
                        per instruction. */}
                    {(hasGuided || hasAdvanced) && (
                      <button
                        type="button"
                        className="button dark"
                        onClick={() => (hasGuided ? onGuided(preset.config) : onConfigure(preset.config))}
                      >
                        Choose this
                      </button>
                    )}
                    {/* "Customise": always Advanced/full options,
                        pre-filled with the preset's config - lets the
                        user see and change any field, including the
                        variant itself, on one page. */}
                    {hasAdvanced && (
                      <button type="button" className="button ghost" onClick={() => onConfigure(preset.config)}>
                        Customise
                      </button>
                    )}
                  </div>
                </div>
              )
            })}
          </div>
          {/* Always retained: an explicit way out of the presets for
              anyone who wants full control from a blank slate - the
              same plain (no preset) Guided/Advanced entry points the
              hero actions above already offer, surfaced again here so
              it's not necessary to scroll back up. */}
          {(hasGuided || hasAdvanced) && (
            <button
              type="button"
              className="product-hub-preset-buildown"
              onClick={() => (hasGuided ? onGuided() : onConfigure())}
            >
              Build your own <Icon name="arrowRight" size={15}/>
            </button>
          )}
        </div>
      )}

      {/* 3 — Use cases */}
      {content.useCases.length > 0 && (
        <div className="product-hub-usecases">
          {content.useCases.map((useCase) => (
            <span key={useCase.label} className="product-hub-usecase-pill">{useCase.label}</span>
          ))}
        </div>
      )}

      <div className="product-hub-grid">
        <div className="product-hub-main">
          {/* 4 — Collection & delivery / Payment / Returns / Artwork.
              QS-21.5 section 14: consolidates what used to be two
              separate standalone blocks here (a plain "Artwork" block
              and a "Collection or delivery" block duplicating the exact
              same fulfilmentOptions list every OTHER product's
              configurator step already shows) into one compact
              accordion, plus genuinely new Payment/Returns content this
              pass adds. Still reuses the same real fulfilmentOptions
              facts (via DELIVERY_INFO, src/lib/businessInfo.js) - never
              a second, conflicting data source. */}
          <ProductSupportInfo artworkHelp={artwork.help}/>
        </div>

        <aside className="product-hub-side">
          {/* 6 — Related products. QS-21.1: the row itself no longer
              navigates on click (was abrupt - straight to another
              Product Detail page, top of page, no warning) - it toggles
              a local disclosure preview instead (thumbnail, short
              description, View product, Quick configure where
              eligible). Only "View product" navigates; only one related
              item can be expanded at a time (resolveRelatedDisclosureState,
              src/lib/relatedContent.js). Expanding/collapsing never
              touches page/history state - see App.jsx's history-sync
              effect, which this never reaches. */}
          {related.length > 0 && (
            <div className="product-hub-block product-hub-related">
              <h3>Related products</h3>
              <div className="product-hub-related-list">
                {related.map((item) => {
                  const isExpanded = expandedRelatedId === item.id
                  const itemMedia = resolveProductMedia(item)
                  const quickConfigEligible = resolveQuickConfigureEligibility(item)
                  return (
                    <div key={item.id} className={`product-hub-related-row${isExpanded ? ' expanded' : ''}`}>
                      <button
                        type="button"
                        className="product-hub-related-toggle"
                        aria-expanded={isExpanded}
                        onClick={() => setExpandedRelatedId((current) => resolveRelatedDisclosureState(current, item.id))}
                      >
                        <span>{resolveProductDisplayName(item, mode)}</span>
                        <Icon name={isExpanded ? 'arrowUpRight' : 'arrowRight'} size={15}/>
                      </button>
                      {isExpanded && (
                        <div className="product-hub-related-preview">
                          <div className="product-hub-related-preview-media">
                            {itemMedia.hero ? (
                              <img src={itemMedia.hero} alt="" loading="lazy"/>
                            ) : (
                              <ProductScene productId={item.id}/>
                            )}
                          </div>
                          <div className="product-hub-related-preview-copy">
                            {item.description && <p>{item.description}</p>}
                            <div className="product-hub-related-preview-actions">
                              <button type="button" className="button ghost" onClick={() => onSelectRelated?.(item)}>
                                View product
                              </button>
                              {quickConfigEligible && onQuickConfigure && (
                                <button type="button" className="button dark" onClick={() => onQuickConfigure(item)}>
                                  Quick configure
                                </button>
                              )}
                            </div>
                          </div>
                        </div>
                      )}
                    </div>
                  )
                })}
              </div>
            </div>
          )}

          {/* 7 — Share, collapsed to a slim utility row (QS-21.1 section
              8 audit): QS-21 added real page/selectedProductId browser-
              history STATE, but never a visible URL (path or query never
              change - only history.state does), so a copied address bar
              link still cannot restore a specific product. Deep links
              are therefore still genuinely unavailable, not just
              unbuilt - shareLinks.productPageUrl/configureUrl remain
              unexposed. */}
          <div className="product-hub-share-compact">
            <a href={shareLinks.whatsappUrl} target="_blank" rel="noreferrer" className="product-hub-share-primary">
              <Icon name="send" size={16}/> Share on WhatsApp
            </a>
            <span className="product-hub-share-status">Direct product links coming soon</span>
          </div>
        </aside>
      </div>

      {/* Mobile sticky Configure CTA — hidden on desktop via CSS (kept
          separate from .qs21-sticky-configure, which is desktop-only).
          QS-21.5 section 4 fix: this used to be a static, always-visible
          div with zero state awareness, so "Start guided order" stayed
          pinned over content even while the customer was already
          actively inside the Guided/Full configurator. Now gated by the
          SAME configureInView App.jsx already computes for the desktop
          sticky CTA (resolveStickyConfigureVisibility, navigation.js) -
          disappears the moment the real configurator section is on
          screen, exactly like the desktop one already did. Not
          aria-hidden when rendered: it holds real, focusable buttons on
          the viewports where it's actually visible. */}
      {!configureInView && !overlayOpen && !lightboxOpen && ctaRegionInView && (
        <div className="product-hub-sticky-cta">
          {hasGuided ? (
            <button type="button" className="button dark" onClick={() => onGuided()}>
              Start guided order {priceCue && !priceCue.quoteRequired && <>· {formatMoney(priceCue.total)}</>} <Icon name="arrowRight" size={17}/>
            </button>
          ) : hasAdvanced ? (
            <button type="button" className="button dark" onClick={() => onConfigure()}>
              Configure {priceCue && !priceCue.quoteRequired && <>· {formatMoney(priceCue.total)}</>} <Icon name="arrowUpRight" size={16}/>
            </button>
          ) : (
            <a className="button dark" href={shareLinks.whatsappUrl} target="_blank" rel="noreferrer">
              <Icon name="message" size={16}/> WhatsApp help
            </a>
          )}
        </div>
      )}

      {/* QS-21.3 — lightbox. Same backdrop-click-to-close pattern
          QuickConfigureSheet.jsx already established (role="presentation"
          backdrop + stopPropagation on the inner content), plus Escape/
          Arrow keys (see the keydown effect above) and explicit
          next/prev buttons when there is more than one image. */}
      {lightboxOpen && activeImage && (
        <div className="qs21-lightbox-backdrop" role="presentation" onClick={closeLightbox}>
          <div
            className="qs21-lightbox-dialog"
            role="dialog"
            aria-modal="true"
            aria-label={`${product.name} photo ${galleryIndex + 1} of ${galleryImages.length}`}
            onClick={(event) => event.stopPropagation()}
          >
            <button type="button" className="qs21-lightbox-close" onClick={closeLightbox} aria-label="Close">×</button>
            {galleryImages.length > 1 && (
              <button type="button" className="qs21-lightbox-nav qs21-lightbox-prev" onClick={showPrevImage} aria-label="Previous photo">
                <Icon name="arrowLeft" size={20}/>
              </button>
            )}
            <img src={activeImage} alt={product.name} className="qs21-lightbox-image"/>
            {galleryImages.length > 1 && (
              <button type="button" className="qs21-lightbox-nav qs21-lightbox-next" onClick={showNextImage} aria-label="Next photo">
                <Icon name="arrowRight" size={20}/>
              </button>
            )}
            {galleryImages.length > 1 && (
              <span className="qs21-lightbox-count">{galleryIndex + 1} / {galleryImages.length}</span>
            )}
          </div>
        </div>
      )}
    </section>
  )
}
