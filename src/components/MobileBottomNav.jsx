import React from 'react'
import Icon from './Icon.jsx'
import { resolveBottomNavActiveId } from '../lib/navigation.js'

// QS-21.5 section 3 — mobile-only bottom navigation. Reuses App.jsx's
// EXISTING page-state navigation functions (goHome/goShop) and the
// existing basket toggle (setCartOpen) - no React Router, no new
// navigation mechanism. "Order" opens the real basket/cart (the closest
// existing concept to a persistent "your order" destination - Start
// order is product-specific and only makes sense once a product is
// already open, so it stays where it is as a header/PDP action; this is
// the basket instead, matching common mobile-commerce bottom-nav
// semantics without copying any specific app's visual design).
//
// Hiding while a full-screen overlay is open (lightbox, Quick Configure
// sheet, the cart sheet itself) is handled by z-index stacking, not
// extra state: every one of those overlays is a `position: fixed;
// inset: 0` backdrop at a higher z-index (qs21-5-mobile-shell.css) that
// already visually covers and intercepts pointer events for anything
// beneath it - the nav needs no knowledge of which overlay is open to
// be correctly hidden/inert under all of them.
const DESTINATIONS = [
  { id: 'home', label: 'Home', icon: 'store' },
  { id: 'shop', label: 'Shop', icon: 'bag' },
  { id: 'quick-points', label: 'Quick Points', icon: 'pin' },
  { id: 'order', label: 'Order', icon: 'checkCircle' }
]

export default function MobileBottomNav({ page, cartOpen, cartCount = 0, onGoHome, onGoShop, onGoQuickPoints, onOpenOrder }) {
  const activeId = resolveBottomNavActiveId(page, cartOpen)

  const handlers = {
    home: onGoHome,
    shop: onGoShop,
    'quick-points': onGoQuickPoints,
    order: onOpenOrder
  }

  return (
    <nav className="qs21-bottom-nav" aria-label="Primary">
      {DESTINATIONS.map((destination) => (
        <button
          key={destination.id}
          type="button"
          className={`qs21-bottom-nav-item${activeId === destination.id ? ' active' : ''}`}
          onClick={handlers[destination.id]}
          aria-current={activeId === destination.id ? 'page' : undefined}
        >
          <span className="qs21-bottom-nav-icon">
            <Icon name={destination.icon} size={19}/>
            {destination.id === 'order' && cartCount > 0 && (
              <span className="qs21-bottom-nav-badge">{cartCount > 9 ? '9+' : cartCount}</span>
            )}
          </span>
          <small>{destination.label}</small>
        </button>
      ))}
    </nav>
  )
}
