import React from 'react'
import Icon from './Icon.jsx'
import ProductScene from './ProductScene.jsx'

export default function ProductCard({ product, active = false, onConfigure }) {
  return (
    <button className={`product-card ${active ? 'active' : ''}`} type="button" onClick={() => onConfigure(product)}>
      <div className="product-card-top">
        <span className="eyebrow">{product.category}</span>
        <Icon name="arrowUpRight" size={18}/>
      </div>
      <div className="product-card-media" aria-hidden="true">
        <ProductScene productId={product.id} />
      </div>
      <div>
        <h3>{product.name}</h3>
        <p>{product.description}</p>
      </div>
      <span className="product-link">Start guided <Icon name="arrowRight" size={15}/></span>
    </button>
  )
}
