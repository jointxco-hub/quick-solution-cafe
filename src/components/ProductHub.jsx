import React, { useEffect, useMemo, useState } from 'react'
import Icon from './Icon.jsx'
import ProductScene from './ProductScene.jsx'
import { fulfilmentOptions } from '../data/products.js'
import { calculateProductPrice, formatMoney, getDefaultConfig } from '../lib/pricing.js'
import {
  resolveProductMedia,
  resolveProductPageContent,
  resolveConfigPreviewFields,
  resolveArtworkGuidance,
  deriveRelatedProducts,
  resolveStartingPriceEligibility,
  resolveHubAvailability,
  resolveProductPresets,
  composeVariantSummary,
  buildShareLinks
} from '../lib/productContent.js'

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
export default function ProductHub({ product, catalog = [], mode = 'simple', onConfigure, onGuided, onSelectRelated }) {
  const [galleryIndex, setGalleryIndex] = useState(0)
  const [mediaFailed, setMediaFailed] = useState(false)

  useEffect(() => {
    setGalleryIndex(0)
    setMediaFailed(false)
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
  // resolveStartingPriceEligibility() (src/lib/productContent.js) for
  // the full reasoning. The actual number, when eligible, still comes
  // from calculateProductPrice()/getDefaultConfig() only.
  const priceEligibility = useMemo(() => resolveStartingPriceEligibility(product), [product])
  const priceCue = useMemo(() => {
    if (priceEligibility.mode === 'quote') return { quoteRequired: true }
    if (priceEligibility.mode === 'amount') {
      try {
        const result = calculateProductPrice(product, getDefaultConfig(product, {}))
        return { quoteRequired: false, total: result.total }
      } catch {
        return null
      }
    }
    return null
  }, [priceEligibility, product])

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
          {/* 8 — Related products */}
          {related.length > 0 && (
            <div className="product-hub-block product-hub-related">
              <h3>Related products</h3>
              <div className="product-hub-related-list">
                {related.map((item) => (
                  <button key={item.id} type="button" onClick={() => onSelectRelated?.(item)}>
                    <span>{item.name}</span>
                    <Icon name="arrowRight" size={15}/>
                  </button>
                ))}
              </div>
            </div>
          )}

          {/* 9 — Share Kit placeholder */}
          <div className="product-hub-block product-hub-share">
            <h3>Share this product</h3>
            <p className="product-hub-share-note">Brochures, spec sheets and artwork templates can be added here later.</p>
            <div className="product-hub-share-links">
              {/* Correction: this app has no routing for /products/:id or
                  /configure/:id yet, so shareLinks.productPageUrl/
                  configureUrl do not resolve to anything if opened -
                  never exposed as copyable/clickable. A single compact
                  status line replaces what used to be two disabled
                  full-width rows. buildShareLinks() still computes both
                  URLs (kept for tests/future use). WhatsApp is the one
                  primary, actionable row. */}
              <p className="product-hub-share-status">Direct product and configure links are coming soon.</p>
              <a href={shareLinks.whatsappUrl} target="_blank" rel="noreferrer" className="product-hub-share-primary">
                <Icon name="send" size={16}/> Share on WhatsApp
              </a>
            </div>
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
