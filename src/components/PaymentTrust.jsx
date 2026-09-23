import React from 'react'
import Icon from './Icon.jsx'
import { PAYMENT_TRUST_TEXT } from '../lib/businessInfo.js'

// QS-21.5 section 11/12 — compact payment-confidence component, shared
// by Product Detail's supporting-info accordion and the footer (per the
// brief's own "near primary purchase/configuration confidence area, and
// optionally in footer" - one component, not two copies).
//
// No official PayFast logo asset exists anywhere in this repo (audited:
// public/ contains only product photography, the map background and the
// Joint X mark). Per the brief's explicit instruction for exactly this
// case ("do not draw fake logos, add clean text/icon treatment
// temporarily, report which official assets are missing") this renders
// a plain text/icon wordmark badge, NOT a recreated PayFast logo -
// flagged again in the QS-21.5 report as a real asset gap.
//
// Payment-method audit: GuidedOrder/OrderBasket/PaymentReturn/
// supabaseApi.js only ever handle an opaque hosted PayFast redirect
// (init -> payment_url -> redirect -> server-side ITN confirms). No
// env var, config or comment anywhere states which card/EFT/wallet
// methods are actually enabled on the live merchant account - that is a
// PayFast-dashboard fact this codebase cannot see. Per the brief's own
// fallback for exactly this case, this deliberately shows ONLY the
// conservative "Secure checkout via PayFast" claim - no Visa/Mastercard/
// Apple Pay/etc icons, since none of those could be verified as enabled.
export default function PaymentTrust({ compact = false }) {
  return (
    <div className={`qs21-payment-trust${compact ? ' compact' : ''}`}>
      <span className="qs21-payfast-mark" aria-label="PayFast">
        <Icon name="checkCircle" size={14}/> PayFast
      </span>
      <span className="qs21-payment-trust-text">{PAYMENT_TRUST_TEXT}</span>
    </div>
  )
}
