import React, { useEffect, useRef } from 'react'

export default function StaffPopover({ children, ...props }) {
  const ref = useRef(null)
  useEffect(() => {
    const dismiss = (event) => {
      if (ref.current?.open && !ref.current.contains(event.target)) ref.current.open = false
    }
    document.addEventListener('pointerdown', dismiss)
    document.addEventListener('focusin', dismiss)
    return () => {
      document.removeEventListener('pointerdown', dismiss)
      document.removeEventListener('focusin', dismiss)
    }
  }, [])
  return <details {...props} ref={ref} onKeyDown={(event) => {
    if (event.key === 'Escape') {
      event.currentTarget.open = false
      event.currentTarget.querySelector('summary')?.focus()
      event.stopPropagation()
    }
  }}>{children}</details>
}
