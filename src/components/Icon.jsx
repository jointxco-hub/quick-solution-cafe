import React from 'react'
export default function Icon({ name, size = 20, className = '' }) {
  const common = { width: size, height: size, viewBox: '0 0 24 24', fill: 'none', stroke: 'currentColor', strokeWidth: 2, strokeLinecap: 'round', strokeLinejoin: 'round', className, 'aria-hidden': true }

  const icons = {
    search: <><circle cx="11" cy="11" r="8"/><path d="m21 21-4.3-4.3"/></>,
    upload: <><path d="M12 3v12"/><path d="m7 8 5-5 5 5"/><path d="M5 21h14"/></>,
    pin: <><path d="M20 10c0 5-8 11-8 11S4 15 4 10a8 8 0 1 1 16 0Z"/><circle cx="12" cy="10" r="2.5"/></>,
    arrowRight: <><path d="M5 12h14"/><path d="m13 6 6 6-6 6"/></>,
    arrowUpRight: <><path d="M7 17 17 7"/><path d="M7 7h10v10"/></>,
    store: <><path d="M3 9h18"/><path d="M5 9v10h14V9"/><path d="m5 3-2 6h18l-2-6Z"/><path d="M9 19v-6h6v6"/></>,
    truck: <><path d="M3 6h11v10H3z"/><path d="M14 10h4l3 3v3h-7z"/><circle cx="7" cy="18" r="2"/><circle cx="18" cy="18" r="2"/></>,
    clock: <><circle cx="12" cy="12" r="9"/><path d="M12 7v5l3 2"/></>,
    bag: <><path d="M5 8h14l-1 12H6Z"/><path d="M9 8a3 3 0 0 1 6 0"/></>,
    document: <><path d="M6 2h8l4 4v16H6z"/><path d="M14 2v5h5"/><path d="M9 12h6"/><path d="M9 16h6"/></>,
    user: <><circle cx="12" cy="8" r="4"/><path d="M4 21a8 8 0 0 1 16 0"/></>,
    shirt: <><path d="m8 4-5 3 3 5 2-1v9h8v-9l2 1 3-5-5-3a4 4 0 0 1-8 0Z"/></>,
    help: <><circle cx="12" cy="12" r="9"/><path d="M9.8 9a2.4 2.4 0 1 1 3.8 2c-.9.6-1.6 1.1-1.6 2.5"/><path d="M12 17h.01"/></>,
    message: <><path d="M21 15a4 4 0 0 1-4 4H8l-5 3V7a4 4 0 0 1 4-4h10a4 4 0 0 1 4 4z"/></>,
    checkCircle: <><circle cx="12" cy="12" r="9"/><path d="m8.5 12 2.4 2.4 4.8-5"/></>,
    alertCircle: <><circle cx="12" cy="12" r="9"/><path d="M12 7v5"/><path d="M12 16h.01"/></>,
    xCircle: <><circle cx="12" cy="12" r="9"/><path d="m9 9 6 6"/><path d="m15 9-6 6"/></>,
    refresh: <><path d="M21 2v6h-6"/><path d="M3 22v-6h6"/><path d="M20 8a8.5 8.5 0 0 0-14.5-3L3 8"/><path d="M4 16a8.5 8.5 0 0 0 14.5 3L21 16"/></>,
    send: <><path d="M22 2 11 13"/><path d="M22 2 15 22l-4-9-9-4 20-7Z"/></>,
    external: <><path d="M7 17 17 7"/><path d="M10 7h7v7"/><path d="M17 14v3a2 2 0 0 1-2 2H7a2 2 0 0 1-2-2V9a2 2 0 0 1 2-2h3"/></>,
    layers: <><path d="m12 3 9 5-9 5-9-5 9-5Z"/><path d="m3 12 9 5 9-5"/><path d="m3 16 9 5 9-5"/></>,
    copy: <><rect x="9" y="9" width="11" height="11" rx="2"/><path d="M5 15H4a2 2 0 0 1-2-2V4a2 2 0 0 1 2-2h9a2 2 0 0 1 2 2v1"/></>
  }

  return <svg {...common}>{icons[name] || icons.arrowRight}</svg>
}
