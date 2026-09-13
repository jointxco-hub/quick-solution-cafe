import React from 'react'

function money(value) {
  return new Intl.NumberFormat('en-ZA', {
    style: 'currency',
    currency: 'ZAR',
    minimumFractionDigits: 2
  }).format(Number(value || 0))
}

export default function PaymentRedirectLoader({ orderNumber, amount }) {
  return (
    <div className="qs-secure-payment-loader" role="status" aria-live="polite" aria-busy="true">
      <div className="qs-secure-payment-loader-card">
        <div className="qs-secure-payment-loader-brand" aria-hidden="true">
          <span className="qs-secure-dot green"/>
          <span className="qs-secure-dot orange"/>
          <span className="qs-secure-dot lilac"/>
        </div>

        <span className="eyebrow">Secure payment</span>
        <h2>Taking you to PayFast…</h2>
        <p>
          Your order is already saved. We’re creating the secure payment session
          before handing you over to PayFast.
        </p>

        <div className="qs-secure-payment-loader-summary">
          <div>
            <small>Order</small>
            <strong>{orderNumber || 'Quick Solution order'}</strong>
          </div>
          <div>
            <small>Amount</small>
            <strong>{money(amount)}</strong>
          </div>
        </div>

        <div className="qs-secure-payment-progress" aria-hidden="true">
          <span/>
        </div>

        <div className="qs-secure-payment-loader-foot">
          <span className="qs-secure-lock" aria-hidden="true">●</span>
          <span>Connecting securely. Please keep this window open.</span>
        </div>
      </div>
    </div>
  )
}
