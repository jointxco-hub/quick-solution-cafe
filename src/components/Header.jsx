import React from 'react'
import Icon from './Icon.jsx'

export default function Header() {
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
        <a href={`${homePrefix}#start`}>Start</a>
        <a href={`${homePrefix}#services`}>Services</a>
        <a href={`${homePrefix}#quick-points`}><Icon name="pin" size={16}/> Quick Points</a>
        <a href="/track"><Icon name="search" size={15}/> Track order</a>
      </nav>
      <a className="bag-button" href={`${homePrefix}#configure`} aria-label="Start an order"><Icon name="bag" size={18}/><span>Start order</span></a>
    </header>
  )
}
