import React, { useEffect, useMemo, useState } from 'react'
import Icon from './Icon.jsx'
import ProductScene from './ProductScene.jsx'
import { fulfilmentOptions } from '../data/products.js'
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
  composeVariantSummary,
  resolveProductDisplayName,
  buildShareLinks
} from '../lib/productContent.js'
import { resolveQuickConfigureEligibility } from '../lib/navigation.js'
import { resolveRelatedDisclosureState } from '../lib/relatedContent.js'

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
// behavior), while the new Presets section's "Choose this"/"Customise"
// buttons call them WITH a preset's config. No new App.jsx state or
// prop was introduced for this - openAdvanced/openGuided already accept
// a `nextPreset` argument (used since QS-16 for related-product/
// continue-from-advanced handoffs), so passing a preset's config through
// these same two existing props reuses that exact mechanism.
export default function ProductHub({ product, catalog = [], mode = 'simple', onConfigure, onGuided, onSelectRelated, onQuickConfigure }) {
  const [galleryIndex, setGalleryIndex] = useState(0)
  const [mediaFailed, setMediaFailed] = useState(false)
  // QS-21.1: which related-product row (if any) is expanded into its
  // local disclosure preview - see resolveRelatedDisclosureState()
  // (src/lib/relatedContent.js) for the "only one at a time" rule. Reset
  // on product change so switching products never leaves a stale card
  // expanded for a related list that's about to be replaced.
  const [expandedRelatedId, setExpandedRelatedId] = useState(null)

  useEffect(() => {
    setGalleryIndex(0)
    setMediaFailed(false)
    setExpandedRelatedId(null)
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

  return (
    <section id="product" className="shell product-hub">
      {/* 1 — Hero */}
      <div className="product-hub-hero">
        <div className="product-hub-hero-copy">
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

          {/* QS-21.1 section 7: a compact trust row right next to the
              primary configure actions - the SAME 4 verified-true claims
              App.jsx's full trust strip makes lower down the page
              (.qs21-trust-strip, near the configurator itself), just a
              single condensed line here so the two never feel like
              repeated blocks. */}
          <ul className="product-hub-trust-compact">
            <li><Icon name="checkCircle" size={14}/> Secure checkout</li>
            <li><Icon name="store" size={14}/> Collect locally</li>
            <li><Icon name="truck" size={14}/> Courier or delivery</li>
            <li><Icon name="document" size={14}/> Artwork checked</li>
          </ul>
        </div>

        {/* 2 — Media */}
        <div className="product-hub-media">
          <div className="product-hub-media-frame">
            {activeImage ? (
              <img src={activeImage} alt={product.name} loading="lazy" onError={() => setMediaFailed(true)}/>
            ) : (
              <ProductScene productId={product.id} className="product-hub-scene"/>
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
      </div>

      {/* QS-17 — Quick options / Quick Presets. Only renders when the
          product actually has valid presets - products without any
          (every product except flags/gazebos, this phase) render
          exactly as they did before this section existed. */}
      {presets.length > 0 && (
        <div className="product-hub-presets">
          <h3>Quick options</h3>
          <div className="product-hub-preset-grid">
            {presets.map((preset) => {
              const price = presetPrices[preset.id]
              // QS-18: a generic, mode-aware spec line composed straight
              // from product.pricing.variantAxes (see composeVariantSummary()/
              // productContent.js) - e.g. "Telescopic — 3.0m — Printed on
              // both sides — Complete kit" (Simple) vs "... — Double-sided
              // — Full kit" (Pro). Never changes preset.name/description,
              // never a second copy of the variant's spec.
              const specLine = composeVariantSummary(product, preset.config?.variant, mode)
              return (
                <div key={preset.id} className="product-hub-preset-card">
                  <strong>{preset.name}</strong>
                  {specLine && <small className="product-hub-preset-spec">{specLine}</small>}
                  {preset.description && <p>{preset.description}</p>}
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
          {/* 4 — Highlights */}
          {content.highlights.length > 0 && (
            <div className="product-hub-block">
              <h3>Good to know</h3>
              <ul className="product-hub-highlights">
                {content.highlights.map((highlight) => (
                  <li key={highlight.label}>
                    <Icon name="checkCircle" size={17}/>
                    <span>{highlight.label}</span>
                  </li>
                ))}
              </ul>
            </div>
          )}

          {/* 5 — Configuration preview */}
          {previewFields.length > 0 && (
            <div className="product-hub-block">
              <h3>Choices you will make</h3>
              <div className="product-hub-preview-grid">
                {previewFields.map((field) => (
                  <div key={field.id} className="product-hub-preview-field">
                    <span className="product-hub-preview-label">{field.label}</span>
                    <div className="product-hub-preview-options">
                      {field.options.map((option) => (
                        <span key={option.id} className="product-hub-preview-option" title={option.helper || undefined}>
                          {option.label}
                        </span>
                      ))}
                    </div>
                  </div>
                ))}
              </div>
            </div>
          )}

          {/* 6 — Artwork */}
          {artwork.help && (
            <div className="product-hub-block">
              <h3>Artwork</h3>
              <p className="product-hub-artwork-note"><Icon name="upload" size={17}/> {artwork.help}</p>
            </div>
          )}

          {/* 7 — Fulfilment */}
          <div className="product-hub-block">
            <h3>Collection or delivery</h3>
            <div className="product-hub-fulfilment">
              {fulfilmentOptions.map((option) => (
                <div key={option.id} className="product-hub-fulfilment-option">
                  <Icon name={option.icon} size={19}/>
                  <div>
                    <strong>{option.label}</strong>
                    <span>{option.helper}</span>
                  </div>
                </div>
              ))}
            </div>
            <p className="product-hub-fulfilment-note">You will choose collection or delivery when you configure your order.</p>
          </div>
        </div>

        <aside className="product-hub-side">
          {/* 8 — Related products. QS-21.1: the row itself no longer
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

          {/* 9 — Share, collapsed to a slim utility row (QS-21.1 section
              8 audit): QS-21 added real page/selectedProductId browser-
              history STATE, but never a visible URL (path or query never
              change - only history.state does), so a copied address bar
              link still cannot restore a specific product. Deep links
              are therefore still genuinely unavailable, not just
              unbuilt - shareLinks.productPageUrl/configureUrl remain
              unexposed. This used to be a full bordered card with a
              filler note for content that does not exist yet; now it is
              one line, WhatsApp is the only real action, and the "coming
              soon" copy is kept but de-emphasised rather than removed. */}
          <div className="product-hub-share-compact">
            <a href={shareLinks.whatsappUrl} target="_blank" rel="noreferrer" className="product-hub-share-primary">
              <Icon name="send" size={16}/> Share on WhatsApp
            </a>
            <span className="product-hub-share-status">Direct product links coming soon</span>
          </div>
        </aside>
      </div>

      {/* Mobile sticky Configure CTA — hidden on desktop via CSS. Not
          aria-hidden: it holds real, focusable buttons on the
          viewports where it's actually visible. */}
      <div className="product-hub-sticky-cta">
        {hasGuided ? (
          <button type="button" className="button dark" onClick={() => onGuided()}>
            Start guided order <Icon name="arrowRight" size={17}/>
          </button>
        ) : hasAdvanced ? (
          <button type="button" className="button dark" onClick={() => onConfigure()}>
            Configure <Icon name="arrowUpRight" size={16}/>
          </button>
        ) : (
          <a className="button dark" href={shareLinks.whatsappUrl} target="_blank" rel="noreferrer">
            <Icon name="message" size={16}/> WhatsApp help
          </a>
        )}
      </div>
    </section>
  )
}
