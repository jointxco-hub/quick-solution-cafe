import React from 'react'
import Icon from './Icon.jsx'

// QS-18: mode/onModeChange add the subtle, always-available Simple|Pro
// toggle (presentation-only - see src/lib/languageMode.js); onSendDocuments
// opens the existing document-printing Guided flow directly (no new
// upload implementation) from anywhere on the site. Both props are
// optional so Header keeps rendering even before App.jsx wires them up.
export default function Header({ mode = 'simple', onModeChange, onSendDocuments }) {
  const homePrefix = window.location.pathname === '/' ? '' : '/'
  return (
    <header className="site-header">
      <a className="brand" href={homePrefix ? '/' : '#top'} aria-label="Joint X Quick Solution Café home">
        <img className="brand-mark-image" src="/jointx-mark.png" alt="" />
        <span>
          <strong>Quick Solution</strong>
          <small>by Joint X</small>
        </span>
      </a>
      <nav className="desktop-nav" aria-label="Primary navigation">
        <a href={`${homePrefix}#shop`}>Shop</a>
        <a href={`${homePrefix}#quick-points`}><Icon name="pin" size={16}/> Quick Points</a>
        <a href="/track"><Icon name="search" size={15}/> Track order</a>
      </nav>
      <div className="qs18-header-actions">
        {onModeChange && (
          <div className="qs18-mode-toggle" role="group" aria-label="Language mode">
            <button type="button" className={mode === 'simple' ? 'active' : ''} onClick={() => onModeChange('simple')} aria-pressed={mode === 'simple'}>Simple</button>
            <button type="button" className={mode === 'pro' ? 'active' : ''} onClick={() => onModeChange('pro')} aria-pressed={mode === 'pro'}>Pro</button>
          </div>
        )}
        {onSendDocuments && (
          <button type="button" className="qs18-send-docs" onClick={onSendDocuments} aria-label="Send documents">
            <Icon name="document" size={16}/>
            <span className="qs18-send-docs-desktop">Send documents</span>
            <span className="qs18-send-docs-mobile">Send docs</span>
          </button>
        )}
        <a className="bag-button" href={`${homePrefix}#configure`} aria-label="Start an order"><Icon name="bag" size={18}/><span>Start order</span></a>
      </div>
    </header>
  )
}
