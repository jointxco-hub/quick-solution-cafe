import React from 'react'
import StaffPopover from './StaffPopover.jsx'
import StaffNavigation from './StaffNavigation.jsx'
import StaffAppControls from './StaffAppControls.jsx'

export default function StaffMenu({ app, active, signedIn = true, onChange, onSignOut, orderId }) {
  return <StaffPopover className="qs-staff-menu">
    <summary>Menu <span aria-hidden="true">☰</span></summary>
    <div className="qs-staff-menu-panel" onClick={(event) => {
      if (event.target.closest('a')) event.currentTarget.parentElement.open = false
    }}>
      {signedIn && <StaffNavigation active={active} onChange={onChange} orderId={orderId}/>}
      <StaffAppControls app={app} signedIn={signedIn}/>
      <a className="qs-menu-storefront" href="/">Storefront</a>
      {signedIn && <button type="button" className="qs-menu-signout" onClick={onSignOut}>Sign out</button>}
    </div>
  </StaffPopover>
}
