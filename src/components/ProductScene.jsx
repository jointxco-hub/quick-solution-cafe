import React from 'react'

export default function ProductScene({ productId, className = '' }) {
  const common = {
    width: 220,
    height: 152,
    viewBox: '0 0 220 152',
    fill: 'none',
    xmlns: 'http://www.w3.org/2000/svg',
    className,
    'aria-hidden': true
  }

  if (productId === 'a4-print') {
    return (
      <svg {...common}>
        <rect x="16" y="20" width="96" height="112" rx="18" fill="rgba(255,255,255,0.94)" />
        <rect x="38" y="42" width="52" height="6" rx="3" fill="rgba(0,139,114,0.18)" />
        <rect x="38" y="58" width="74" height="6" rx="3" fill="rgba(17,17,15,0.14)" />
        <rect x="38" y="74" width="66" height="6" rx="3" fill="rgba(17,17,15,0.1)" />
        <rect x="38" y="90" width="58" height="6" rx="3" fill="rgba(17,17,15,0.1)" />
        <rect x="106" y="34" width="80" height="96" rx="18" fill="rgba(255,255,255,0.75)" />
        <circle cx="160" cy="57" r="18" fill="rgba(215,191,255,0.65)" />
        <path d="M152 57h16" stroke="#3B3565" strokeWidth="2.5" strokeLinecap="round" />
        <path d="M160 49v16" stroke="#3B3565" strokeWidth="2.5" strokeLinecap="round" />
        <rect x="126" y="92" width="40" height="6" rx="3" fill="rgba(17,17,15,0.12)" />
        <rect x="126" y="106" width="28" height="6" rx="3" fill="rgba(17,17,15,0.12)" />
      </svg>
    )
  }

  if (productId === 'business-cards') {
    return (
      <svg {...common}>
        <rect x="34" y="74" width="120" height="54" rx="18" transform="rotate(-10 34 74)" fill="rgba(255,255,255,0.98)" />
        <rect x="52" y="58" width="120" height="54" rx="18" transform="rotate(3 52 58)" fill="rgba(255,255,255,0.82)" />
        <rect x="70" y="36" width="120" height="54" rx="18" fill="rgba(255,255,255,0.92)" />
        <rect x="86" y="54" width="48" height="7" rx="3.5" fill="rgba(0,139,114,0.22)" />
        <rect x="86" y="70" width="76" height="6" rx="3" fill="rgba(17,17,15,0.14)" />
        <rect x="86" y="84" width="58" height="6" rx="3" fill="rgba(17,17,15,0.1)" />
      </svg>
    )
  }

  if (productId === 'printed-tshirt') {
    return (
      <svg {...common}>
        <path d="M81 28c7 10 14 14 29 14s22-4 29-14l26 17-17 28-12-6v57H74V67l-12 6-17-28 26-17Z" fill="rgba(255,255,255,0.96)" />
        <rect x="90" y="60" width="40" height="40" rx="10" fill="rgba(0,139,114,0.12)" />
        <path d="M98 80h24" stroke="#008B72" strokeWidth="3" strokeLinecap="round" />
        <path d="M98 88h14" stroke="#008B72" strokeWidth="3" strokeLinecap="round" />
      </svg>
    )
  }

  if (productId === 'quick-point') {
    return (
      <svg {...common}>
        <rect x="26" y="62" width="84" height="56" rx="18" fill="rgba(255,255,255,0.94)" />
        <path d="M42 62c1-16 10-24 26-24s25 8 26 24" stroke="rgba(17,17,15,0.2)" strokeWidth="6" strokeLinecap="round" />
        <circle cx="150" cy="56" r="26" fill="rgba(215,191,255,0.72)" />
        <path d="M150 42c-8.8 0-16 6.9-16 15.5 0 10 16 24.5 16 24.5s16-14.5 16-24.5C166 48.9 158.8 42 150 42Z" fill="rgba(255,255,255,0.9)" />
        <circle cx="150" cy="57" r="5" fill="#3B3565" />
        <rect x="122" y="95" width="54" height="10" rx="5" fill="rgba(255,255,255,0.8)" />
        <rect x="122" y="110" width="38" height="8" rx="4" fill="rgba(255,255,255,0.56)" />
      </svg>
    )
  }

  return (
    <svg {...common}>
      <rect x="26" y="24" width="168" height="104" rx="28" fill="rgba(255,255,255,0.9)" />
      <rect x="54" y="52" width="68" height="10" rx="5" fill="rgba(0,139,114,0.2)" />
      <rect x="54" y="74" width="112" height="8" rx="4" fill="rgba(17,17,15,0.12)" />
      <rect x="54" y="92" width="84" height="8" rx="4" fill="rgba(17,17,15,0.1)" />
    </svg>
  )
}
