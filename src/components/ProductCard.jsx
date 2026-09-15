import React, { useState } from 'react'
import Icon from './Icon.jsx'
import ProductScene from './ProductScene.jsx'

const productImages = {
  'pvc-banner': '/qs11/product-pvc-banner-clean.webp',
  'vinyl-stickers': '/qs11/product-vinyl-labels-clean.webp',
  'a4-print': '/qs11/product-document-printing-clean.webp',
  'business-cards': '/qs11/product-business-cards-clean.webp',
  'printed-tshirt': '/qs11/product-tshirt-clean.webp'
}

export default function ProductCard({ product, active = false, onConfigure }) {
  const [imageFailed, setImageFailed] = useState(false)
  const imageSrc = productImages[product.id]
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
        <h3>{product.name}</h3>
        <p>{product.description}</p>
      </div>

      <div className="product-card-footer">
        <span className="product-link">Configure <Icon name="arrowRight" size={15}/></span>
        {product.guidedJourneyId && <span className="product-mode-label">Guided available</span>}
      </div>
    </button>
  )
}


