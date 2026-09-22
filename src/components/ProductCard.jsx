import React, { useState } from 'react'
import Icon from './Icon.jsx'
import ProductScene from './ProductScene.jsx'
import { resolveProductMedia, resolveProductDisplayName } from '../lib/productContent.js'

export default function ProductCard({ product, active = false, mode = 'simple', onConfigure }) {
  const [imageFailed, setImageFailed] = useState(false)
  // QS-16: lookup order is product.media?.hero -> product.image ->
  // the legacy hardcoded map (moved into productContent.js so
  // ProductCard and ProductHub share one copy) -> ProductScene.
  const imageSrc = resolveProductMedia(product).hero
  const showImage = imageSrc && !imageFailed

  return (
    <button className={`product-card ${active ? 'active' : ''}`} type="button" onClick={() => onConfigure(product)}>
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

      <div className="product-card-footer">
        <span className="product-link">View product <Icon name="arrowRight" size={15}/></span>
        {product.guidedJourneyId && <span className="product-mode-label">Guided available</span>}
      </div>
    </button>
  )
}


