import React, { useState } from 'react'
import Icon from './Icon.jsx'
import ProductScene from './ProductScene.jsx'
import { resolveProductMedia, resolveProductDisplayName } from '../lib/productContent.js'

// QS-21: two distinct intentions, two distinct controls - previously
// the WHOLE card was one <button onClick={onConfigure}>, so "view this
// product" and "configure it" were the same action wearing two labels.
// Card body/image/name now always means "go to Product Detail"
// (onViewProduct); the separate Configure control means "quick
// configure this, right here" (onQuickConfigure) - App.jsx decides
// whether that opens the Quick Configure sheet or falls back straight
// to Product Detail's configuration step, per
// resolveQuickConfigureEligibility() (src/lib/navigation.js).
export default function ProductCard({ product, active = false, mode = 'simple', onViewProduct, onQuickConfigure }) {
  const [imageFailed, setImageFailed] = useState(false)
  // QS-16: lookup order is product.media?.hero -> product.image ->
  // the legacy hardcoded map (moved into productContent.js so
  // ProductCard and ProductHub share one copy) -> ProductScene.
  const imageSrc = resolveProductMedia(product).hero
  const showImage = imageSrc && !imageFailed

  return (
    <div className={`product-card ${active ? 'active' : ''}`}>
      <button className="product-card-body" type="button" onClick={() => onViewProduct(product)}>
        <div className="product-card-top">
          <span className="eyebrow">{product.category}</span>
          <Icon name="arrowUpRight" size={18}/>
        </div>

        <div className={`product-card-media ${showImage ? 'has-photo' : ''}`} aria-hidden="true">
          {showImage ? (
            <img
              src={imageSrc}
              alt=""
              loading="lazy"
              onError={() => setImageFailed(true)}
            />
          ) : (
            <ProductScene productId={product.id}/>
          )}
        </div>

        <div className="product-card-copy">
          <h3>{resolveProductDisplayName(product, mode)}</h3>
          <p>{product.description}</p>
        </div>
      </button>

      <div className="product-card-footer">
        <button type="button" className="product-link" onClick={() => onViewProduct(product)}>
          View product <Icon name="arrowRight" size={15}/>
        </button>
        {onQuickConfigure && (
          <button type="button" className="product-card-configure" onClick={() => onQuickConfigure(product)}>
            Configure
          </button>
        )}
      </div>
    </div>
  )
}


