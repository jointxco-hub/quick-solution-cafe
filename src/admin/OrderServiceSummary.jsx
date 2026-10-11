import React, { useState } from 'react'
import { resolveConfiguratorPreviewImage } from '../lib/configuratorVisuals.js'

export default function OrderServiceSummary({ workspace, compact = false }) {
  const items = workspace?.items || []
  if (!items.length) return null
  return <div className={`order-services ${compact ? 'compact' : ''}`}>
    {(compact ? items.slice(0, 1) : items).map(item => <Service key={item.id} item={item} />)}
    {compact && items.length > 1 && <small>+{items.length - 1} more item{items.length > 2 ? 's' : ''}</small>}
  </div>
}
function Service({ item }) {
  const [failed, setFailed] = useState(false)
  const image = resolveConfiguratorPreviewImage(item.product || { id: item.productKey }, item.configuration || {})
  return <div className="order-service">
    {image && !failed ? <img src={image} alt="" loading="lazy" onError={() => setFailed(true)}/> : <span className="order-service-placeholder" aria-hidden="true">▤</span>}
    <div><strong>{item.name}</strong><small>Quantity {item.quantity}</small></div>
  </div>
}
