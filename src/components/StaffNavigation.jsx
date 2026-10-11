import React from 'react'
import '../styles/staff-app.css'

const sections = [
  { id: 'counter', label: 'Counter', href: '/counter' },
  { id: 'orders', label: 'Orders', href: '/admin' },
  { id: 'products', label: 'Products', href: '/admin?section=products' },
  { id: 'quick-points', label: 'Quick Points', href: '/admin?section=quick-points' },
]

export function initialStaffSection(search = typeof window === 'undefined' ? '' : window.location.search) {
  const query = new URLSearchParams(search)
  if (query.has('order')) return 'orders'
  const section = query.get('section')
  return ['products', 'quick-points'].includes(section) ? section : 'orders'
}

export default function StaffNavigation({ active, onChange, orderId = '' }) {
  return <nav className="qs-staff-navigation" aria-label="Café workspaces">
    {sections.map((section) => <a key={section.id}
      href={section.id === 'orders' && orderId ? `/admin?order=${orderId}` : section.href}
      aria-current={active === section.id ? 'page' : undefined}
      onClick={onChange && section.id !== 'counter' ? (event) => {
        if (event.button !== 0 || event.ctrlKey || event.metaKey || event.shiftKey || event.altKey) return
        event.preventDefault()
        onChange(section.id)
      } : undefined}>{section.label}</a>)}
  </nav>
}
