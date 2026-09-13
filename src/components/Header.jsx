import React from 'react'
import Icon from './Icon.jsx'

export default function Header() {
  return (
    <header className="site-header">
      <a className="brand" href="#top" aria-label="Joint X Quick Solution Café home">
        <img className="brand-mark-image" src="/jointx-mark.png" alt="" />
        <span>
          <strong>Quick Solution</strong>
          <small>by Joint X</small>
        </span>
      </a>
      <nav className="desktop-nav" aria-label="Primary navigation">
        <a href="#start">Start</a>
        <a href="#services">Services</a>
        <a href="#quick-points"><Icon name="pin" size={16}/> Quick Points</a>
      </nav>
      <a className="bag-button" href="#configure" aria-label="Start an order"><Icon name="bag" size={18}/><span>Start order</span></a>
    </header>
  )
}
