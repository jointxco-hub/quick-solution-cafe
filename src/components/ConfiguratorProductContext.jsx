import React, { useEffect, useState } from 'react'
import Icon from './Icon.jsx'
import { resolveProductDisplayName, resolveProductMedia } from '../lib/productContent.js'
import { resolveConfiguratorPreviewDetail, resolveConfiguratorPreviewImage } from '../lib/configuratorVisuals.js'

export default function ConfiguratorProductContext({ product, config = {}, mode = 'simple' }) {
  const [lightboxOpen, setLightboxOpen] = useState(false)
  const image = resolveConfiguratorPreviewImage(product, config)
  const fallbackImage = resolveProductMedia(product).hero
  const [displayImage, setDisplayImage] = useState(image)
  const detail = resolveConfiguratorPreviewDetail(product, config)
  const name = resolveProductDisplayName(product, mode)

  useEffect(() => setLightboxOpen(false), [product?.id])

  useEffect(() => {
    setDisplayImage(image)
  }, [image])

  const handleImageError = () => {
    if (fallbackImage && displayImage !== fallbackImage) {
      setDisplayImage(fallbackImage)
      return
    }
    setDisplayImage(null)
    setLightboxOpen(false)
  }

  return (
    <>
      <div className="qs217-config-context">
        {displayImage ? (
          <button type="button" className="qs217-config-thumb" onClick={() => setLightboxOpen(true)}>
            <img src={displayImage} alt="" onError={handleImageError}/>
            <span><Icon name="search" size={12}/></span>
          </button>
        ) : null}
        <div className="qs217-config-context-copy">
          <span>You're configuring</span>
          <strong>{name}</strong>
          {detail ? <small>{detail}</small> : null}
        </div>
      </div>

      {lightboxOpen && image ? (
        <div className="qs217-config-lightbox" onClick={() => setLightboxOpen(false)}>
          <div className="qs217-config-lightbox-card" onClick={(event) => event.stopPropagation()}>
            <button type="button" className="qs217-config-lightbox-close" onClick={() => setLightboxOpen(false)}>×</button>
            <img src={displayImage} alt={name} onError={handleImageError}/>
          </div>
        </div>
      ) : null}
    </>
  )
}
