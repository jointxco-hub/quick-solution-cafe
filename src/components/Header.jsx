import React, { useEffect, useRef, useState } from 'react'
import Icon from './Icon.jsx'

// QS-18: mode/onModeChange add the subtle, always-available Simple|Pro
// toggle (presentation-only - see src/lib/languageMode.js); onSendDocuments
// opens the existing document-printing Guided flow directly (no new
// upload implementation) from anywhere on the site.
//
// QS-18A: Shop/Product Hub/the configurator/Quick Points now only exist
// in App.jsx's Shop page tree, not permanently on Home - so the nav
// links that used to be plain #anchor scrolls (Shop, Quick Points) and
// the brand logo/bag-button (implicitly "go home"/"go to #configure")
// are now buttons that ask App.jsx to switch page AND scroll, via
// onGoHome/onGoShop/onGoQuickPoints/onStartOrder. All props are optional
// so Header keeps rendering even before App.jsx wires them up (falls
// back to the old plain-anchor behavior in that case).
export default function Header({ onSendDocuments, onGoHome, onGoShop, onGoQuickPoints }) {
  const homePrefix = window.location.pathname === '/' ? '' : '/'
  const [hidden, setHidden] = useState(false)
  const lastScrollY = useRef(0)

  useEffect(() => {
    lastScrollY.current = window.scrollY || 0

    const onScroll = () => {
      const nextY = Math.max(0, window.scrollY || 0)
      const delta = nextY - lastScrollY.current

      if (nextY < 32) setHidden(false)
      else if (delta > 2 && nextY > 64) setHidden(true)
      else if (delta < -4) setHidden(false)

      lastScrollY.current = nextY
    }

    window.addEventListener('scroll', onScroll, { passive: true })
    return () => window.removeEventListener('scroll', onScroll)
  }, [])

  useEffect(() => {
    document.documentElement.classList.toggle('qs217-header-hidden', hidden)
    return () => document.documentElement.classList.remove('qs217-header-hidden')
  }, [hidden])

  const handleGoHome = (event) => {
    if (!onGoHome) return
    event.preventDefault()
    onGoHome()
  }
  return (
    <header
      className={`site-header qs217-auto-header ${hidden ? 'is-hidden' : ''}`}
      onMouseEnter={() => setHidden(false)}
      onFocusCapture={() => setHidden(false)}
    >
      <a className="brand" href={homePrefix ? '/' : '#top'} aria-label="Joint X Quick Solution Café home" onClick={handleGoHome}>
        <img className="brand-mark-image" src="/jointx-mark.png" alt="" />
        <span>
          <strong>Quick Solution</strong>
          <small>by Joint X</small>
        </span>
      </a>
      <nav className="desktop-nav" aria-label="Primary navigation">
        {onGoHome ? <button type="button" onClick={onGoHome}>Home</button> : <a href={`${homePrefix}#top`}>Home</a>}
        {onGoShop ? <button type="button" onClick={onGoShop}>Shop</button> : <a href={`${homePrefix}#shop`}>Shop</a>}
        {onGoQuickPoints
          ? <button type="button" onClick={onGoQuickPoints}><Icon name="pin" size={16}/> Quick Points</button>
          : <a href={`${homePrefix}#quick-points`}><Icon name="pin" size={16}/> Quick Points</a>}
        <a href="/track"><Icon name="search" size={15}/> Track order</a>
      </nav>
      <div className="qs18-header-actions">
        {onSendDocuments && (
          <button type="button" className="qs18-send-docs" onClick={onSendDocuments} aria-label="Send documents">
            <Icon name="document" size={16}/>
            <span className="qs18-send-docs-desktop">Send documents</span>
            <span className="qs18-send-docs-mobile">Send docs</span>
          </button>
        )}
      </div>
    </header>
  )
}
