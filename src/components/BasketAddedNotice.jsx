import React from 'react'
import Icon from './Icon.jsx'

export default function BasketAddedNotice({ message, count, onView, onDismiss }) {
  return <div className="qs-cart-toast qs-cart-added-notice">
    <div role="status" aria-live="polite"><Icon name="checkCircle" size={20}/><span>{message}<small>{count} item{count === 1 ? '' : 's'} in your basket</small></span></div>
    <button type="button" className="qs-cart-notice-view" onClick={onView}>View basket</button>
    <button type="button" className="qs-cart-notice-dismiss" aria-label="Dismiss basket confirmation" onClick={onDismiss}>×</button>
  </div>
}
