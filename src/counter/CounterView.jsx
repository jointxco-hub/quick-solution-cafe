import React, { useState } from 'react'
import Icon from '../components/Icon.jsx'
import FieldControl from '../components/FieldControl.jsx'
import { formatMoney } from '../lib/pricing.js'
import { COUNTER_ACTIONS } from '../lib/counterCatalogue.js'
import { BUSINESS_NAME } from '../lib/businessInfo.js'
import { buildCounterPreview, counterFields, groupCounterEntries } from '../lib/counterDraft.js'
import { COUNTER_SUBMISSION, resolveCounterSubmission } from '../lib/counterSubmissionReadiness.js'
import { describeCounterOrder } from '../lib/counterOrders.js'
import { buildCounterReceipt } from '../lib/counterReceipt.js'
import { addBusinessDays, describeCounterCashup, formatBusinessDate } from '../lib/counterCashup.js'
import { describeCounterUnpaid } from '../lib/counterUnpaid.js'
import { describeCounterCancelled, isCancelledListAvailable } from '../lib/counterCancelled.js'
import { CANCEL_PHASES, COUNTER_CANCEL_REASON_MAX, describeCancelOffer, initialCancel } from '../lib/counterCancel.js'
import { COUNTER_PAYMENT_METHODS, PAYMENT_PHASES, counterPaymentMethodLabel, describeCounterOrderDetail, initialPayment } from '../lib/counterPayment.js'
import { COUNTER_UNKNOWN_RESULT_MESSAGE, EMPTY_COUNTER_CUSTOMER, SALE_PHASES, initialSale, isSaleLocked, validateCounterCustomer } from '../lib/counterSale.js'

// The staff Counter screen (CAFE-GUEST-01N preview, CAFE-GUEST-01O first writable flow). Pure presentation:
// it receives the screen state (from loadCounterCatalogueState), the one draft, the one sale and the
// handlers. It never calls the API and never decides who may use the counter or which product may be
// written - the server's answer arrives as `state`, and write readiness comes from
// counterSubmissionReadiness.js.

function TopBar({ signedIn, onSignOut }) {
  return (
    <header className="qsc-bar">
      <a className="brand" href="/" aria-label={`${BUSINESS_NAME} home`}>
        <img className="brand-mark-image" src="/jointx-mark.png" alt=""/>
        <span><strong>{BUSINESS_NAME}</strong><small>Counter</small></span>
      </a>
      <div className="qsc-bar-actions">
        <span className="qsc-mode">Cash &amp; card</span>
        {signedIn ? <button className="admin-signout-button" type="button" onClick={onSignOut}>Sign out</button> : null}
      </div>
    </header>
  )
}

function Notice({ tone = 'info', icon, title, children, action }) {
  return (
    <section className={`qsc-notice qsc-notice-${tone}`} role={tone === 'info' ? 'status' : 'alert'}>
      <Icon name={icon} size={26}/>
      <div>
        <h1>{title}</h1>
        {children ? <p>{children}</p> : null}
        {action}
      </div>
    </section>
  )
}

export function CounterSignIn({ onSignIn, error = '', busy = false, heading = 'Sign in to use the counter', intro = 'Use your staff account. What you can do here is decided by the server, not by this screen.' }) {
  const [email, setEmail] = useState('')
  const [password, setPassword] = useState('')
  const submit = (event) => {
    event.preventDefault()
    onSignIn?.(email, password)
  }
  return (
    <section className="qsc-signin">
      <span className="eyebrow">Staff counter</span>
      <h1>{heading}</h1>
      <p>{intro}</p>
      <form onSubmit={submit} className="admin-auth-form">
        <label className="admin-field"><span>Email</span><input autoComplete="username" type="email" required value={email} onChange={(event) => setEmail(event.target.value)}/></label>
        <label className="admin-field"><span>Password</span><input autoComplete="current-password" type="password" required value={password} onChange={(event) => setPassword(event.target.value)}/></label>
        {error ? <div className="admin-auth-error" role="alert">{error}</div> : null}
        <button className="button dark admin-auth-submit" type="submit" disabled={busy}>{busy ? 'Signing in…' : 'Sign in'}</button>
      </form>
    </section>
  )
}

function ActionBadge({ action }) {
  const isRequest = action === COUNTER_ACTIONS.REQUEST
  return <span className={`qsc-badge ${isRequest ? 'qsc-badge-request' : 'qsc-badge-order'}`}>{isRequest ? 'Request' : 'Order'}</span>
}

function ProductList({ sections, selectedId, onSelect, locked }) {
  return (
    <nav className="qsc-products" aria-label="Counter products">
      {sections.map((section) => (
        <section key={section.group} className="qsc-group" aria-label={section.group}>
          <h2>{section.group}</h2>
          <div className="qsc-tiles">
            {section.entries.map((entry) => {
              const selected = entry.product.id === selectedId
              return (
                <button
                  key={entry.product.id}
                  type="button"
                  className={`qsc-tile ${selected ? 'selected' : ''} ${entry.action === COUNTER_ACTIONS.REQUEST ? 'is-request' : ''}`}
                  aria-pressed={selected}
                  data-product-id={entry.product.id}
                  disabled={locked}
                  onClick={() => onSelect?.(entry.product.id)}
                >
                  <span className="qsc-tile-top"><strong>{entry.product.name}</strong><ActionBadge action={entry.action}/></span>
                  {entry.product.description ? <small>{entry.product.description}</small> : null}
                </button>
              )
            })}
          </div>
        </section>
      ))}
    </nav>
  )
}

function ProductForm({ entry, draft, onChange }) {
  const { product } = entry
  if (entry.action === COUNTER_ACTIONS.REQUEST) {
    return (
      <div className="qsc-request-note">
        <Icon name="message" size={22}/>
        <div>
          <strong>Request workflow coming next</strong>
          <span>{product.name} is handled as a request, not a counter order. Nothing can be created for it from this screen yet.</span>
        </div>
      </div>
    )
  }
  return (
    <div className="field-grid qsc-fields">
      {counterFields(product).map((field) => (
        <FieldControl
          key={`${product.id}:${field.id}`}
          field={field}
          value={draft?.values?.[field.id] ?? ''}
          onChange={(value) => onChange?.(field.id, value)}
        />
      ))}
    </div>
  )
}

// Optional. Blank is fine: the server records Walk-in. No search, no linking to an existing client.
function CustomerFields({ customer, onChange }) {
  const checked = validateCounterCustomer(customer)
  const field = (id, label, props) => (
    <label className="field">
      <span>{label}</span>
      <input value={customer?.[id] ?? ''} onChange={(event) => onChange?.(id, event.target.value)} aria-invalid={checked.errors[id] ? 'true' : undefined} {...props}/>
      {checked.errors[id] ? <small className="qsc-field-error">{checked.errors[id]}</small> : null}
    </label>
  )
  return (
    <fieldset className="qsc-customer">
      <legend>Customer <small>optional · leave blank for Walk-in</small></legend>
      <div className="field-grid">
        {field('name', 'Name', { autoComplete: 'off', placeholder: 'Walk-in' })}
        {field('phone', 'Phone', { autoComplete: 'off', inputMode: 'tel', placeholder: 'e.g. 075 123 4567' })}
        {field('email', 'Email', { autoComplete: 'off', inputMode: 'email', placeholder: 'name@example.com' })}
      </div>
    </fieldset>
  )
}

function Preview({ entry, draft, customer, onReview }) {
  const preview = buildCounterPreview(entry, draft)
  const submission = resolveCounterSubmission(entry)
  const isRequest = preview.action === COUNTER_ACTIONS.REQUEST
  const customerOk = validateCounterCustomer(customer).ok
  const label = validateCounterCustomer(customer).value.name || preview.customer
  return (
    <aside className="qsc-preview" aria-live="polite" aria-label="Preview">
      <span className="eyebrow inverse">{isRequest ? 'Request preview' : 'Order preview'}</span>
      <h2>{preview.productName}</h2>
      <dl className="qsc-preview-rows">
        <div><dt>Action</dt><dd><ActionBadge action={preview.action}/></dd></div>
        <div><dt>Customer</dt><dd>{label}</dd></div>
        {preview.rows.map((row) => <div key={row.label}><dt>{row.label}</dt><dd>{row.value}</dd></div>)}
        {preview.unitSummary && !preview.rows.some((row) => row.value === preview.unitSummary) ? <div><dt>Amount</dt><dd>{preview.unitSummary}</dd></div> : null}
      </dl>
      {isRequest ? (
        <p className="qsc-preview-note">Request workflow coming next. No price is shown for a request.</p>
      ) : preview.valid ? (
        preview.estimate ? (
          <div className="qsc-estimate">
            <span>Estimated total</span>
            <strong>{formatMoney(preview.estimate.total)}</strong>
            <small>Estimate only. The server sets the final price when an order is created.</small>
          </div>
        ) : (
          <p className="qsc-preview-note">No estimate for this configuration. The server prices it when an order is created.</p>
        )
      ) : (
        <ul className="qsc-errors" role="status">
          {preview.errors.map((error, index) => <li key={`${error.field}-${index}`}>{error.message}</li>)}
        </ul>
      )}
      {submission.status === COUNTER_SUBMISSION.WRITABLE ? (
        <button className="button primary-light qsc-action" type="button" disabled={!preview.valid || !customerOk} onClick={onReview}>Review order</button>
      ) : submission.status === COUNTER_SUBMISSION.NOT_READY ? (
        <p className="qsc-not-ready" role="status">{submission.message}</p>
      ) : null}
      <p className="qsc-preview-foot">{submission.status === COUNTER_SUBMISSION.WRITABLE ? 'Nothing is created until you confirm on the next step.' : 'Preview only. Nothing has been created.'}</p>
    </aside>
  )
}

const STATUS_LABELS = { submitted: 'Submitted' }
const PAYMENT_LABELS = { unpaid: 'Unpaid' }
const label = (map, value) => (value ? map[value] || String(value).charAt(0).toUpperCase() + String(value).slice(1) : '—')

function SaleSummary({ summary }) {
  return (
    <dl className="qsc-preview-rows">
      <div><dt>Product</dt><dd>{summary.productName}</dd></div>
      {summary.rows.map((row) => <div key={row.label}><dt>{row.label}</dt><dd>{row.value}</dd></div>)}
      {summary.unitSummary && !summary.rows.some((row) => row.value === summary.unitSummary) ? <div><dt>Amount</dt><dd>{summary.unitSummary}</dd></div> : null}
      <div><dt>Customer</dt><dd>{summary.customerLabel}</dd></div>
      <div><dt>Payment</dt><dd>Unpaid</dd></div>
    </dl>
  )
}

function EstimateBox({ summary }) {
  return summary.estimateTotal !== null ? (
    <div className="qsc-estimate">
      <span>Estimated total</span>
      <strong>{formatMoney(summary.estimateTotal)}</strong>
      <small>Estimate only. The server calculates the final amount when the order is created.</small>
    </div>
  ) : (
    <p className="qsc-preview-note">No estimate for this order. The server calculates the final amount when it is created.</p>
  )
}

function SalePanel({ sale, onBackToEdit, onSubmit, onNewSale, onSignIn, signInError, signInBusy }) {
  const { phase, attempt, result, error } = sale
  const summary = attempt?.summary
  const busy = phase === SALE_PHASES.SUBMITTING

  if (phase === SALE_PHASES.SUCCESS) {
    const estimate = summary?.estimateTotal ?? null
    const differs = estimate !== null && Math.abs(estimate - result.totalAmount) > 0.004
    return (
      <section className="qsc-sale qsc-sale-success" aria-label="Order created" role="status">
        <span className="eyebrow inverse">Order created</span>
        <h2>{result.orderNumber}</h2>
        {result.replayed ? <p className="qsc-preview-note">This order had already been created. This is the original order, not a new one.</p> : null}
        <dl className="qsc-preview-rows">
          <div><dt>Product</dt><dd>{result.productName || summary?.productName}</dd></div>
          {summary?.rows.map((row) => <div key={row.label}><dt>{row.label}</dt><dd>{row.value}</dd></div>)}
          <div><dt>Customer</dt><dd>{[result.customerName, result.customerPhone, result.customerEmail].filter(Boolean).join(' · ') || 'Walk-in'}</dd></div>
          <div><dt>Status</dt><dd>{label(STATUS_LABELS, result.status)}</dd></div>
          <div><dt>Payment</dt><dd>{label(PAYMENT_LABELS, result.paymentStatus)}</dd></div>
        </dl>
        <div className="qsc-estimate qsc-final">
          <span>Final total (from the server)</span>
          <strong>{formatMoney(result.totalAmount)}</strong>
          {estimate !== null ? (
            <small>{differs ? `The earlier estimate was ${formatMoney(estimate)}. The server’s total is the amount for this order.` : `Matches the earlier estimate of ${formatMoney(estimate)}.`}</small>
          ) : <small>No estimate was shown for this order.</small>}
        </div>
        <p className="qsc-preview-foot">No payment has been taken. The order is unpaid.</p>
        <button className="button primary-light qsc-action" type="button" onClick={onNewSale}>Start new sale</button>
      </section>
    )
  }

  return (
    <section className={`qsc-sale qsc-sale-${phase}`} aria-label="Confirm order" aria-busy={busy || undefined}>
      <span className="eyebrow inverse">{phase === SALE_PHASES.CONFIRMING || busy ? 'Confirm order' : 'Order not confirmed'}</span>
      <h2>{summary.productName}</h2>
      <SaleSummary summary={summary}/>
      <EstimateBox summary={summary}/>

      {phase === SALE_PHASES.CONFIRMING || busy ? (
        <>
          <ul className="qsc-terms">
            <li>The order is created <strong>unpaid</strong>. No payment method is recorded yet.</li>
            <li>The server works out the final amount when you create it.</li>
          </ul>
          <div className="qsc-actions">
            <button className="button ghost-light qsc-action" type="button" disabled={busy} onClick={onBackToEdit}>Back to edit</button>
            <button className="button primary-light qsc-action" type="button" disabled={busy} onClick={onSubmit}>{busy ? 'Creating order…' : 'Create unpaid order'}</button>
          </div>
        </>
      ) : null}

      {phase === SALE_PHASES.REJECTED ? (
        <>
          <p className="qsc-problem" role="alert">{error}</p>
          <p className="qsc-preview-note">Nothing was created. Change the order and try again.</p>
          <button className="button primary-light qsc-action" type="button" onClick={onBackToEdit}>Edit order</button>
        </>
      ) : null}

      {phase === SALE_PHASES.UNKNOWN ? (
        <>
          <p className="qsc-problem" role="alert">{error || COUNTER_UNKNOWN_RESULT_MESSAGE}</p>
          <div className="qsc-actions">
            <button className="button primary-light qsc-action" type="button" onClick={onSubmit}>Retry safely</button>
            <button className="button ghost-light qsc-action" type="button" onClick={onNewSale}>Start new sale</button>
          </div>
          <p className="qsc-preview-note">Starting a new sale leaves this one behind: the first order may already exist, so check before entering it again.</p>
        </>
      ) : null}

      {phase === SALE_PHASES.CONFLICT ? (
        <>
          <p className="qsc-problem" role="alert">{error}</p>
          <p className="qsc-preview-note">This sale attempt cannot be retried as it stands. Start a new sale and enter the order again.</p>
          <button className="button primary-light qsc-action" type="button" onClick={onNewSale}>Start new sale</button>
        </>
      ) : null}

      {phase === SALE_PHASES.DENIED ? (
        <>
          <p className="qsc-problem" role="alert">{error}</p>
          <button className="button primary-light qsc-action" type="button" onClick={onNewSale}>Start new sale</button>
        </>
      ) : null}

      {phase === SALE_PHASES.SIGNED_OUT ? (
        <>
          <p className="qsc-problem" role="alert">{error}</p>
          <CounterSignIn onSignIn={onSignIn} error={signInError} busy={signInBusy} heading="Sign in to continue this sale" intro="Nothing was created. After you sign in you will return to this confirmation."/>
        </>
      ) : null}
    </section>
  )
}


// CAFE-GUEST-01P - the two views of the Counter. Switching never touches the sale in progress: it lives in the
// page, so a sale waiting on an unconfirmed result is still there when staff come back from the list.
function ViewTabs({ view, onView, saleWaiting, showCancelled }) {
  return (
    <div className="qsc-tabs" role="group" aria-label="Counter views">
      <button type="button" className={view === 'sale' ? 'active' : ''} aria-current={view === 'sale' ? 'page' : undefined} onClick={() => onView?.('sale')}>
        New sale{saleWaiting ? <i className="qsc-dot" title="A sale is waiting on an unconfirmed result"/> : null}
      </button>
      <button type="button" className={view === 'orders' ? 'active' : ''} aria-current={view === 'orders' ? 'page' : undefined} onClick={() => onView?.('orders')}>Today’s orders</button>
      <button type="button" className={view === 'unpaid' ? 'active' : ''} aria-current={view === 'unpaid' ? 'page' : undefined} onClick={() => onView?.('unpaid')}>Unpaid</button>
      <button type="button" className={view === 'cashup' ? 'active' : ''} aria-current={view === 'cashup' ? 'page' : undefined} onClick={() => onView?.('cashup')}>Cash-up</button>
      {showCancelled ? <button type="button" className={view === 'cancelled' ? 'active' : ''} aria-current={view === 'cancelled' ? 'page' : undefined} onClick={() => onView?.('cancelled')}>Cancelled</button> : null}
    </div>
  )
}

function OrderRow({ order, onOpen }) {
  return (
    <li className="qsc-order-item" data-order-number={order.orderNumber}>
      <button type="button" className="qsc-order" aria-label={`Open order ${order.orderNumber}`} onClick={() => onOpen?.(order.orderId)}>
      <div className="qsc-order-head">
        <strong>{order.orderNumber}</strong>
        <span className="qsc-order-time">{order.time}</span>
      </div>
      <div className="qsc-order-body">
        <div className="qsc-order-what">
          {order.items.length ? order.items.map((item, index) => (
            <span key={index}>{item.name}{item.detail ? <small> · {item.detail}</small> : null}</span>
          )) : <span>No items</span>}
          <small>{order.customer}{order.contact ? ` · ${order.contact}` : ''}</small>
        </div>
        <div className="qsc-order-money">
          <strong>{order.total}</strong>
          <span className={`qsc-state qsc-state-${order.paymentStatus || 'unknown'}`}>{order.paymentLabel}</span>
        </div>
      </div>
      <small className="qsc-order-status">{order.statusLabel}</small>
      </button>
    </li>
  )
}

function OrdersPanel({ orders, entries, saleWaiting, onRefresh, onOpenOrder, onSignIn, signInError, signInBusy }) {
  const status = orders?.status || 'loading'
  const rows = (orders?.orders || []).map((order) => describeCounterOrder(order, entries))
  return (
    <section className="qsc-orders" aria-label="Today’s orders">
      <div className="qsc-orders-head">
        <div>
          <span className="eyebrow">{orders?.businessDate ? `Counter · ${orders.businessDate}` : 'Counter'}</span>
          <h2>Today’s orders</h2>
        </div>
        <button className="button ghost qsc-refresh" type="button" disabled={status === 'loading' || orders?.refreshing} onClick={onRefresh}>
          {orders?.refreshing || status === 'loading' ? 'Refreshing…' : 'Refresh'}
        </button>
      </div>
      {saleWaiting ? (
        <p className="qsc-waiting" role="status">A sale is waiting on an unconfirmed result. Look for it here, then go back to New sale to retry safely - the retry cannot create a second order.</p>
      ) : null}
      {status === 'loading' && rows.length === 0 ? <p className="qsc-orders-note" role="status">Loading today’s orders…</p> : null}
      {status === 'signed-out' ? (
        <CounterSignIn onSignIn={onSignIn} error={signInError} busy={signInBusy} heading="Sign in to see today’s orders" intro="Your staff session has ended. Your sale in progress is kept."/>
      ) : null}
      {status === 'denied' || status === 'unavailable' || status === 'error' ? (
        <div className="qsc-problem" role="alert">
          <strong>{status === 'denied' ? 'No counter access' : status === 'unavailable' ? 'Counter unavailable' : 'Could not load today’s orders'}</strong>
          <span>{orders.message}</span>
          {status === 'error' ? <button className="button dark" type="button" onClick={onRefresh}>Try again</button> : null}
        </div>
      ) : null}
      {status === 'empty' ? <p className="qsc-orders-note" role="status">No counter orders yet today.</p> : null}
      {rows.length > 0 && (status === 'ready' || status === 'loading') ? (
        <ul className="qsc-order-list">{rows.map((order) => <OrderRow key={order.orderId || order.orderNumber} order={order} onOpen={onOpenOrder}/>)}</ul>
      ) : null}
    </section>
  )
}

// CAFE-GUEST-01Q - one order, read fresh from the server, and the two ways to record its payment. The amount
// on every confirmation is the outstanding the server just reported; there is no amount to type, and no other method.
function PaymentArea({ view, payment, onChoose, onCancel, onConfirm, onReset, onSignIn, signInError, signInBusy }) {
  const attempt = payment.attempt
  const method = attempt ? counterPaymentMethodLabel(attempt.method) : null
  const busy = payment.phase === PAYMENT_PHASES.SUBMITTING

  if (payment.phase === PAYMENT_PHASES.SUCCESS) {
    return (
      <div className="qsc-paid" role="status">
        <strong>Paid</strong>
        <span>{payment.result.methodLabel} · {payment.result.amountLabel}{payment.result.time ? ` · ${payment.result.time}` : ''}</span>
        {payment.result.replayed ? <small>This payment had already been recorded. This is the original payment, not a new one.</small> : null}
      </div>
    )
  }
  if (payment.phase === PAYMENT_PHASES.ALREADY_PAID) {
    return <div className="qsc-paid" role="status"><strong>Already paid</strong><span>This order has already been paid. Nothing more was recorded.</span></div>
  }
  if (payment.phase === PAYMENT_PHASES.CONFIRMING || busy) {
    return (
      <section className="qsc-confirm-pay" aria-label={`Confirm ${method.toLowerCase()} payment`} aria-busy={busy || undefined}>
        <h3>Record {attempt.amountLabel} as {method}?</h3>
        <dl className="qsc-preview-rows">
          <div><dt>Order</dt><dd>{attempt.orderNumber}</dd></div>
          <div><dt>Method</dt><dd>{method}</dd></div>
          <div><dt>Amount</dt><dd>{attempt.amountLabel}</dd></div>
        </dl>
        <p className="qsc-preview-note">{attempt.method === 'cash'
          ? 'Confirm the whole amount was received in cash. The server records the full outstanding amount.'
          : 'Confirm the whole amount was taken on the card machine. Card details are never entered here.'}</p>
        <div className="qsc-actions">
          <button className="button ghost-light qsc-action" type="button" disabled={busy} onClick={onCancel}>Back</button>
          <button className="button primary-light qsc-action" type="button" disabled={busy} onClick={onConfirm}>{busy ? 'Recording…' : `Confirm ${attempt.method} payment`}</button>
        </div>
      </section>
    )
  }
  if (payment.phase === PAYMENT_PHASES.UNKNOWN) {
    return (
      <div className="qsc-problem" role="alert">
        <strong>Result not confirmed</strong>
        <span>{payment.error}</span>
        <small>{method} · {attempt.amountLabel} · {attempt.orderNumber}</small>
        <button className="button dark qsc-action" type="button" onClick={onConfirm}>Retry safely</button>
      </div>
    )
  }
  if (payment.phase === PAYMENT_PHASES.SIGNED_OUT) {
    return (
      <div className="qsc-problem" role="alert">
        <strong>Sign in to continue</strong>
        <span>{payment.error}</span>
        <CounterSignIn onSignIn={onSignIn} error={signInError} busy={signInBusy} heading="Sign in to continue this payment" intro="Nothing was recorded. After you sign in you will return to this confirmation."/>
      </div>
    )
  }
  if (payment.phase === PAYMENT_PHASES.IDLE) return null
  return (
    <div className="qsc-problem" role="alert">
      <strong>{payment.phase === PAYMENT_PHASES.CONFLICT ? 'Payment attempt conflict' : payment.phase === PAYMENT_PHASES.DENIED ? 'No counter access' : 'Payment not recorded'}</strong>
      <span>{payment.error}</span>
      <button className="button dark qsc-action" type="button" onClick={onReset}>Reload order</button>
    </div>
  )
}

// CAFE-GUEST-01V - cancelling a never-paid order. The action exists only when the SERVER's check says this caller may cancel it and that the
// order can be cancelled; a plain counter member never sees it. It asks for a reason and a confirmation, and shows what the server answered.
function CancelArea({ check, order, rawOrder, cancel, onStart, onReason, onAbort, onConfirm, onReset, onSignIn, signInError, signInBusy }) {
  const busy = cancel.phase === CANCEL_PHASES.SUBMITTING
  if (cancel.phase === CANCEL_PHASES.SUCCESS) {
    return (
      <div className="qsc-cancelled" role="status">
        <strong>Order cancelled</strong>
        <span>{cancel.result.orderNumber} was cancelled. Reason: {cancel.result.reason}</span>
        {cancel.result.replayed ? <small>This cancellation had already been recorded. Nothing new was written.</small> : null}
      </div>
    )
  }
  if (cancel.phase === CANCEL_PHASES.CONFIRMING || busy) {
    return (
      <section className="qsc-confirm-cancel" aria-label="Confirm cancellation" aria-busy={busy || undefined}>
        <h3>Cancel order {cancel.attempt.orderNumber}?</h3>
        <p className="qsc-preview-note">Nothing has been paid on this order. It will be cancelled, will leave the unpaid list, and cannot be paid afterwards. Your name, the time and the reason are recorded.</p>
        <label className="qsc-cancel-reason">
          <span>Reason for cancelling</span>
          <textarea rows={3} maxLength={COUNTER_CANCEL_REASON_MAX} value={cancel.reason} disabled={busy} placeholder="e.g. Customer left without paying" onChange={(event) => onReason?.(event.target.value)}/>
        </label>
        {cancel.error ? <p className="qsc-field-error" role="alert">{cancel.error}</p> : null}
        <div className="qsc-actions">
          <button className="button ghost-light qsc-action" type="button" disabled={busy} onClick={onAbort}>Keep order</button>
          <button className="button primary-light qsc-action qsc-danger" type="button" disabled={busy} onClick={onConfirm}>{busy ? 'Cancelling…' : 'Cancel this order'}</button>
        </div>
      </section>
    )
  }
  if (cancel.phase === CANCEL_PHASES.UNKNOWN) {
    return (
      <div className="qsc-problem" role="alert">
        <strong>Result not confirmed</strong>
        <span>{cancel.error}</span>
        <small>{cancel.attempt.orderNumber}</small>
        <button className="button dark qsc-action" type="button" onClick={onConfirm}>Retry safely</button>
      </div>
    )
  }
  if (cancel.phase === CANCEL_PHASES.SIGNED_OUT) {
    return (
      <div className="qsc-problem" role="alert">
        <strong>Sign in to continue</strong>
        <span>{cancel.error}</span>
        <CounterSignIn onSignIn={onSignIn} error={signInError} busy={signInBusy} heading="Sign in to finish cancelling" intro="Nothing was cancelled. After you sign in you will return to this confirmation."/>
      </div>
    )
  }
  if (cancel.phase === CANCEL_PHASES.REJECTED || cancel.phase === CANCEL_PHASES.DENIED) {
    return (
      <div className="qsc-problem" role="alert">
        <strong>{cancel.phase === CANCEL_PHASES.DENIED ? 'Not allowed' : 'Order not cancelled'}</strong>
        <span>{cancel.error}</span>
        <button className="button dark qsc-action" type="button" onClick={onReset}>Reload order</button>
      </div>
    )
  }
  const offer = describeCancelOffer(check, rawOrder)
  if (offer.offer) return <button className="button ghost qsc-action qsc-cancel-order" type="button" onClick={onStart}>Cancel order</button>
  return offer.note ? <p className="qsc-not-ready qsc-cancel-note" role="status">{offer.note}</p> : null
}

function OrderDetailPanel({ detail, entries, payment, cancelCheck, cancel = initialCancel(), onStartCancel, onCancelReason, onAbortCancel, onConfirmCancel, onResetCancel, backLabel = '← Today’s orders', onBack, onChoose, onCancel, onConfirm, onReset, onReload, onOpenReceipt, onSignIn, signInError, signInBusy }) {
  const status = detail?.status || 'loading'
  const order = status === 'ready' ? describeCounterOrderDetail(detail.order, entries) : null
  const paid = order?.paymentStatus === 'paid'
  const cancelling = cancel.phase !== CANCEL_PHASES.IDLE
  return (
    <section className="qsc-detail" aria-label="Order">
      <button className="qsc-back" type="button" onClick={onBack}>{backLabel}</button>
      {status === 'loading' ? <p className="qsc-orders-note" role="status">Loading the order…</p> : null}
      {status === 'signed-out' ? <CounterSignIn onSignIn={onSignIn} error={signInError} busy={signInBusy} heading="Sign in to see this order" intro="Your staff session has ended."/> : null}
      {['denied', 'unavailable', 'error', 'not-found'].includes(status) ? (
        <div className="qsc-problem" role="alert">
          <strong>{status === 'denied' ? 'No counter access' : status === 'not-found' ? 'Order not found' : status === 'unavailable' ? 'Counter unavailable' : 'Could not load the order'}</strong>
          <span>{detail.message}</span>
          {status === 'error' ? <button className="button dark" type="button" onClick={onReload}>Try again</button> : null}
        </div>
      ) : null}
      {order ? (
        <>
          <div className="qsc-detail-head">
            <div><span className="eyebrow">Counter order · {order.time}</span><h2>{order.orderNumber}</h2></div>
            <span className={`qsc-state qsc-state-${order.paymentStatus || 'unknown'}`}>{order.paymentLabel}</span>
          </div>
          <div className="qsc-detail-card">
            <dl className="qsc-detail-rows">
              <div><dt>Customer</dt><dd>{order.customer}{order.contact ? <small>{order.contact}</small> : null}</dd></div>
              {order.items.map((item, index) => (
                <div key={index}><dt>{index === 0 ? 'Items' : ''}</dt><dd>{item.name}{item.detail ? <small>{item.detail}</small> : null}<small>{item.lineTotal}</small></dd></div>
              ))}
              <div><dt>Status</dt><dd>{order.statusLabel}</dd></div>
              <div><dt>Total</dt><dd>{order.total}</dd></div>
              <div><dt>Paid</dt><dd>{order.amountPaid}</dd></div>
              <div className="qsc-outstanding"><dt>Outstanding</dt><dd>{order.outstanding}</dd></div>
              {order.payments.map((entry, index) => (
                <div key={`p${index}`}><dt>Payment</dt><dd>{entry.method} · {entry.amount}<small>{entry.time}</small></dd></div>
              ))}
            </dl>
            {order.receiptReady ? (
              <button className="button dark qsc-action qsc-view-receipt" type="button" onClick={onOpenReceipt}>View receipt</button>
            ) : null}
            <PaymentArea payment={payment} onChoose={onChoose} onCancel={onCancel} onConfirm={onConfirm} onReset={onReset} onSignIn={onSignIn} signInError={signInError} signInBusy={signInBusy}/>
            {payment.phase === PAYMENT_PHASES.IDLE && !cancelling ? (
              order.canPay ? (
                <div className="qsc-pay-actions">
                  {COUNTER_PAYMENT_METHODS.map((method) => (
                    <button key={method.id} className="button dark qsc-action" type="button" data-method={method.id} onClick={() => onChoose?.(method.id)}>Record {method.label} Payment</button>
                  ))}
                </div>
              ) : paid ? (
                <p className="qsc-paid-note" role="status">This order is paid.</p>
              ) : order.cancelled ? (
                <p className="qsc-not-ready" role="status">This order is cancelled. Nothing is owed and it cannot be paid.</p>
              ) : (
                <p className="qsc-not-ready" role="status">A payment cannot be recorded for this order here.</p>
              )
            ) : null}
            {payment.phase === PAYMENT_PHASES.IDLE || cancelling ? (
              <CancelArea check={cancelCheck} order={order} rawOrder={detail.order} cancel={cancel} onStart={onStartCancel} onReason={onCancelReason} onAbort={onAbortCancel} onConfirm={onConfirmCancel} onReset={onResetCancel} onSignIn={onSignIn} signInError={signInError} signInBusy={signInBusy}/>
            ) : null}
          </div>
        </>
      ) : null}
    </section>
  )
}

// CAFE-GUEST-01R - the paid receipt: one document, on screen and on paper (window.print). It is built only from the
// server's order detail (counterReceipt.js); anything that is not fully paid has no receipt. There is nothing to edit here:
// no refund, void, email or message action, and no way to change what was paid.
export function Receipt({ receipt }) {
  return (
    <article className="qsc-receipt" aria-label="Payment receipt">
      <header className="qsc-receipt-head">
        <strong>{receipt.business.name}</strong>
        {receipt.business.addressLines.map((line) => <span key={line}>{line}</span>)}
        <span>WhatsApp {receipt.business.phone}</span>
      </header>
      <h2 className="qsc-receipt-title">{receipt.title}</h2>
      <dl className="qsc-receipt-meta">
        <div><dt>Reference</dt><dd>{receipt.reference}</dd></div>
        <div><dt>Ordered</dt><dd>{receipt.orderDate} {receipt.orderTime}</dd></div>
        <div><dt>Paid</dt><dd>{receipt.paidDate} {receipt.paidTime}</dd></div>
        <div><dt>Customer</dt><dd>{receipt.customer}{receipt.contact.map((line) => <small key={line}>{line}</small>)}</dd></div>
      </dl>
      <table className="qsc-receipt-items">
        <thead><tr><th scope="col">Item</th><th scope="col">Total</th></tr></thead>
        <tbody>
          {receipt.items.map((item, index) => (
            <tr key={index}>
              <td>
                <span className="qsc-receipt-item">{item.name}</span>
                {item.detail ? <small>{item.detail}</small> : null}
                {item.quantity !== 1 ? <small>Qty {item.quantity}</small> : null}
              </td>
              <td className="qsc-receipt-money">{item.lineTotal}</td>
            </tr>
          ))}
        </tbody>
      </table>
      <dl className="qsc-receipt-totals">
        {receipt.subtotal !== null ? <div><dt>Subtotal</dt><dd>{receipt.subtotal}</dd></div> : null}
        {receipt.fulfilmentFee ? <div><dt>Fulfilment fee</dt><dd>{receipt.fulfilmentFee}</dd></div> : null}
        <div className="qsc-receipt-total"><dt>Total</dt><dd>{receipt.total}</dd></div>
        <div><dt>Amount paid</dt><dd>{receipt.amountPaid}</dd></div>
        <div><dt>Outstanding</dt><dd>{receipt.outstanding}</dd></div>
      </dl>
      <div className="qsc-receipt-payments">
        {receipt.payments.map((payment, index) => (
          <p key={index}>Payment method: {payment.methodLabel}<span>{payment.amount} · {payment.date} {payment.time}</span></p>
        ))}
      </div>
      <p className="qsc-receipt-thanks">Thank you.</p>
    </article>
  )
}

function ReceiptScreen({ detail, entries, onBack, onPrint }) {
  const status = detail?.status || 'loading'
  const receipt = status === 'ready' ? buildCounterReceipt(detail.order, entries) : null
  return (
    <section className="qsc-receipt-screen" aria-label="Receipt">
      <div className="qsc-receipt-actions">
        <button className="qsc-back" type="button" onClick={onBack}>← Back to order</button>
        {receipt ? <button className="button dark qsc-action qsc-print" type="button" onClick={onPrint}>Print receipt</button> : null}
      </div>
      {status === 'loading' ? <p className="qsc-orders-note" role="status">Loading the receipt…</p> : null}
      {status !== 'ready' && status !== 'loading' ? <p className="qsc-orders-note" role="alert">{detail.message || 'The receipt could not be loaded.'}</p> : null}
      {status === 'ready' && !receipt ? <p className="qsc-not-ready" role="status">A receipt is available only for a fully paid order.</p> : null}
      {receipt ? <Receipt receipt={receipt}/> : null}
    </section>
  )
}

// CAFE-GUEST-01S / 01U - the cash-up: what the counter TOOK on a Cafe day by Cash and Card (by the time each payment was completed),
// the payments that make it up, and - kept apart, never counted as money received - the orders made that day that are STILL unpaid. Today
// is the default; another day can be chosen. Read-only: no till to close, no float, no counted cash, no adjustment, no refund. Every figure
// is the server's; the rows open the existing order detail. For an earlier day "unpaid" means unpaid NOW, not at that day's close.
function CashupDateBar({ selectedDate, todayDate, onSelectDate }) {
  const atToday = !selectedDate || (todayDate && selectedDate === todayDate)
  const current = selectedDate || todayDate
  return (
    <div className="qsc-datebar" role="group" aria-label="Cash-up date">
      <button type="button" className="qsc-datebtn" disabled={!current} onClick={() => onSelectDate?.(addBusinessDays(current, -1))}>← Previous day</button>
      <input type="date" className="qsc-dateinput" aria-label="Cash-up date" value={current || ''} max={todayDate || undefined} onChange={(event) => onSelectDate?.(event.target.value)}/>
      <button type="button" className="qsc-datebtn" disabled={atToday || !current} onClick={() => onSelectDate?.(addBusinessDays(current, 1))}>Next day →</button>
      <button type="button" className="qsc-datebtn qsc-datetoday" disabled={atToday} onClick={() => onSelectDate?.(null)}>Today</button>
    </div>
  )
}

function CashupPanel({ cashup, entries, onRefresh, onOpenOrder, onSelectDate, onSignIn, signInError, signInBusy }) {
  const status = cashup?.status || 'loading'
  const view = status === 'ready' || status === 'empty' ? describeCounterCashup(cashup.summary, entries) : null
  const busy = status === 'loading' || cashup?.refreshing
  const selectedDate = cashup?.date || null
  const todayDate = cashup?.todayDate || null
  const isToday = !selectedDate || (todayDate && selectedDate === todayDate)
  const shownDate = view?.businessDate || selectedDate || todayDate
  const words = isToday
    ? { title: 'Today’s cash-up', orders: 'Orders today', paid: 'Orders paid today', unpaid: 'Unpaid orders', outstanding: 'Outstanding today', payments: 'Payments taken today', none: 'No cash or card payments yet today.', empty: 'No counter sales yet today.', unpaidHead: 'Unpaid today', noUnpaid: 'No unpaid counter orders from today.', loading: 'Loading today’s cash-up…' }
    : { title: 'Cash-up', orders: 'Orders made that day', paid: 'Orders paid that day', unpaid: 'Unpaid now', outstanding: 'Outstanding now', payments: 'Payments taken that day', none: 'No cash or card payments on this day.', empty: 'No counter sales on this day.', unpaidHead: 'Made that day, still unpaid now', noUnpaid: 'None of that day’s orders are unpaid now.', loading: 'Loading the cash-up…' }
  return (
    <section className="qsc-cashup" aria-label={isToday ? 'Today’s cash-up' : 'Cash-up'}>
      <div className="qsc-orders-head">
        <div>
          <span className="eyebrow">{isToday ? 'Counter · Today' : 'Counter · Earlier day'}</span>
          <h2>{isToday ? words.title : <>Cash-up <span className="qsc-cashup-date">{formatBusinessDate(shownDate)}</span></>}</h2>
          {isToday && shownDate ? <span className="qsc-cashup-datenote">{formatBusinessDate(shownDate)}</span> : null}
        </div>
        <button className="button ghost qsc-refresh" type="button" disabled={busy} onClick={onRefresh}>{busy ? 'Refreshing…' : 'Refresh'}</button>
      </div>
      <CashupDateBar selectedDate={selectedDate} todayDate={todayDate} onSelectDate={onSelectDate}/>
      {status === 'loading' && !view ? <p className="qsc-orders-note" role="status">{words.loading}</p> : null}
      {status === 'signed-out' ? (
        <CounterSignIn onSignIn={onSignIn} error={signInError} busy={signInBusy} heading="Sign in to see the cash-up" intro="Your staff session has ended. Your sale in progress is kept."/>
      ) : null}
      {status === 'future' ? <p className="qsc-orders-note qsc-future" role="status">That day has not happened yet, so there is nothing to show. Choose today or an earlier day.</p> : null}
      {status === 'denied' || status === 'unavailable' || status === 'error' ? (
        <div className="qsc-problem" role="alert">
          <strong>{status === 'denied' ? 'No counter access' : status === 'unavailable' ? 'Counter unavailable' : 'Could not load the cash-up'}</strong>
          <span>{cashup.message}</span>
          {status === 'error' ? <button className="button dark" type="button" onClick={onRefresh}>Try again</button> : null}
        </div>
      ) : null}
      {status === 'empty' ? <p className="qsc-orders-note" role="status">{words.empty}</p> : null}
      {view && status !== 'empty' ? (
        <>
          {!view.consistent ? <p className="qsc-not-ready" role="alert">The totals do not match the listed payments. Refresh before relying on them.</p> : null}
          <div className="qsc-takings" aria-label="Taken today">
            <div className="qsc-take qsc-take-cash"><span>Cash</span><strong>{view.cash.amount}</strong><small>{view.cash.count} {view.cash.count === 1 ? 'payment' : 'payments'}</small></div>
            <div className="qsc-take qsc-take-card"><span>Card</span><strong>{view.card.amount}</strong><small>{view.card.count} {view.card.count === 1 ? 'payment' : 'payments'}</small></div>
            <div className="qsc-take qsc-take-total"><span>Total taken</span><strong>{view.total.amount}</strong><small>{view.total.count} {view.total.count === 1 ? 'payment' : 'payments'}</small></div>
          </div>
          <dl className="qsc-cashup-facts">
            <div><dt>{words.orders}</dt><dd>{view.ordersToday}</dd></div>
            <div><dt>{words.paid}</dt><dd>{view.paidOrders}</dd></div>
            <div className="qsc-cashup-unpaid"><dt>{words.unpaid}</dt><dd>{view.unpaid.count}</dd></div>
            <div className="qsc-cashup-unpaid"><dt>{words.outstanding}</dt><dd>{view.unpaid.amount}</dd></div>
          </dl>
          {view.other.count > 0 ? <p className="qsc-preview-note qsc-other" role="status">Other payments not included above: {view.other.count} · {view.other.amount}</p> : null}
          {!isToday ? <p className="qsc-preview-note qsc-basis" role="note">Takings are the payments completed on this day. Unpaid shows this day’s orders that are still unpaid now; it is not a record of what was unpaid when the day ended.</p> : null}

          <h3 className="qsc-cashup-heading">{words.payments}</h3>
          {view.payments.length === 0 ? <p className="qsc-orders-note" role="status">{words.none}</p> : (
            <ul className="qsc-order-list">
              {view.payments.map((payment) => (
                <li key={payment.paymentId || payment.orderNumber} className="qsc-order-item" data-payment-order={payment.orderNumber}>
                  <button type="button" className="qsc-order" aria-label={'Open order ' + payment.orderNumber} onClick={() => onOpenOrder?.(payment.orderId)}>
                    <div className="qsc-order-head"><strong>{payment.orderNumber}</strong><span className="qsc-order-time">{payment.time}</span></div>
                    <div className="qsc-order-body">
                      <div className="qsc-order-what"><span>{payment.customer}</span>{payment.orderedEarlier ? <small>Ordered {payment.orderedOn}</small> : null}</div>
                      <div className="qsc-order-money"><strong>{payment.amount}</strong><span className={'qsc-state qsc-state-' + payment.method}>{payment.methodLabel}</span></div>
                    </div>
                  </button>
                </li>
              ))}
            </ul>
          )}

          <h3 className="qsc-cashup-heading">{words.unpaidHead} <small>not money received</small></h3>
          {view.unpaid.orders.length === 0 ? <p className="qsc-orders-note" role="status">{words.noUnpaid}</p> : (
            <ul className="qsc-order-list">
              {view.unpaid.orders.map((order) => (
                <li key={order.orderId || order.orderNumber} className="qsc-order-item" data-unpaid-order={order.orderNumber}>
                  <button type="button" className="qsc-order" aria-label={'Open order ' + order.orderNumber} onClick={() => onOpenOrder?.(order.orderId)}>
                    <div className="qsc-order-head"><strong>{order.orderNumber}</strong><span className="qsc-order-time">{order.time}</span></div>
                    <div className="qsc-order-body">
                      <div className="qsc-order-what">{order.items.map((item, index) => <span key={index}>{item.name}{item.detail ? <small> · {item.detail}</small> : null}</span>)}<small>{order.customer}</small></div>
                      <div className="qsc-order-money"><strong>{order.outstanding}</strong><span className="qsc-state qsc-state-unpaid">Unpaid</span></div>
                    </div>
                  </button>
                </li>
              ))}
            </ul>
          )}
        </>
      ) : null}
    </section>
  )
}

// CAFE-GUEST-01T - every counter order that still owes money, whichever day it was made, oldest first, with its age in Cafe days.
// Read-only: a row opens the existing order detail, where the existing Cash / Card payment is recorded; the order leaves this list only
// when the server stops returning it. No reminder, collection or edit action exists here.
// CAFE-GUEST-01W - the audited cancellations, read-only: which orders were cancelled, by whom, when and why. Only the server decides who may see it;
// the rows open the existing order detail. Nothing here edits, restores or exports.
function CancelledPanel({ cancelled, entries, onRefresh, onOpenOrder, onSignIn, signInError, signInBusy }) {
  const status = cancelled?.status || 'loading'
  const view = status === 'ready' || status === 'empty' ? describeCounterCancelled(cancelled.summary, entries) : null
  const busy = status === 'loading' || cancelled?.refreshing
  return (
    <section className="qsc-cancelled-list" aria-label="Cancelled orders">
      <div className="qsc-orders-head">
        <div>
          <span className="eyebrow">Counter · admin and owner</span>
          <h2>Cancelled orders</h2>
        </div>
        <button className="button ghost qsc-refresh" type="button" disabled={busy} onClick={onRefresh}>{busy ? 'Refreshing…' : 'Refresh'}</button>
      </div>
      {status === 'loading' && !view ? <p className="qsc-orders-note" role="status">Loading cancelled orders…</p> : null}
      {status === 'signed-out' ? (
        <CounterSignIn onSignIn={onSignIn} error={signInError} busy={signInBusy} heading="Sign in to see cancelled orders" intro="Your staff session has ended. Your sale in progress is kept."/>
      ) : null}
      {status === 'denied' || status === 'unavailable' || status === 'error' ? (
        <div className="qsc-problem" role="alert">
          <strong>{status === 'denied' ? 'Not available' : status === 'unavailable' ? 'Counter unavailable' : 'Could not load cancelled orders'}</strong>
          <span>{cancelled.message}</span>
          {status === 'error' ? <button className="button dark" type="button" onClick={onRefresh}>Try again</button> : null}
        </div>
      ) : null}
      {status === 'empty' ? <p className="qsc-orders-note" role="status">No orders have been cancelled.</p> : null}
      {view && status === 'ready' ? (
        <>
          <p className="qsc-unpaid-summary" role="status">
            {view.truncated ? <><strong>Latest {view.shown}</strong> of <strong>{view.count}</strong> cancelled orders</> : <strong>{view.count} {view.count === 1 ? 'order' : 'orders'} cancelled</strong>}
          </p>
          <ul className="qsc-order-list">
            {view.orders.map((order) => (
              <li key={order.orderId || order.orderNumber} className="qsc-order-item" data-cancelled-order={order.orderNumber}>
                <button type="button" className="qsc-order" aria-label={'Open order ' + order.orderNumber} onClick={() => onOpenOrder?.(order.orderId, 'cancelled')}>
                  <div className="qsc-order-head">
                    <strong>{order.orderNumber}</strong>
                    <span className="qsc-age">{order.cancelledDate} {order.cancelledTime}</span>
                  </div>
                  <div className="qsc-order-body">
                    <div className="qsc-order-what">
                      {order.items.length ? order.items.map((item, index) => <span key={index}>{item.name}{item.detail ? <small> · {item.detail}</small> : null}</span>) : <span>No items</span>}
                      <small>{order.customer}{order.contact ? ' · ' + order.contact : ''}</small>
                      <small className="qsc-cancel-why">“{order.reason}” · {order.cancelledBy ? 'by ' + order.cancelledBy : 'by a staff member'}</small>
                    </div>
                    <div className="qsc-order-money">
                      <strong>{order.total}</strong>
                      <span className="qsc-state qsc-state-cancelled">Cancelled</span>
                      <small>{order.wasLabel}</small>
                    </div>
                  </div>
                </button>
              </li>
            ))}
          </ul>
        </>
      ) : null}
    </section>
  )
}

function UnpaidPanel({ unpaid, entries, onRefresh, onOpenOrder, onSignIn, signInError, signInBusy }) {
  const status = unpaid?.status || 'loading'
  const view = status === 'ready' || status === 'empty' ? describeCounterUnpaid(unpaid.summary, entries) : null
  const busy = status === 'loading' || unpaid?.refreshing
  return (
    <section className="qsc-unpaid" aria-label="Unpaid orders">
      <div className="qsc-orders-head">
        <div>
          <span className="eyebrow">Counter · all days</span>
          <h2>Unpaid orders</h2>
        </div>
        <button className="button ghost qsc-refresh" type="button" disabled={busy} onClick={onRefresh}>{busy ? 'Refreshing…' : 'Refresh'}</button>
      </div>
      {status === 'loading' && !view ? <p className="qsc-orders-note" role="status">Loading unpaid orders…</p> : null}
      {status === 'signed-out' ? (
        <CounterSignIn onSignIn={onSignIn} error={signInError} busy={signInBusy} heading="Sign in to see unpaid orders" intro="Your staff session has ended. Your sale in progress is kept."/>
      ) : null}
      {status === 'denied' || status === 'unavailable' || status === 'error' ? (
        <div className="qsc-problem" role="alert">
          <strong>{status === 'denied' ? 'No counter access' : status === 'unavailable' ? 'Counter unavailable' : 'Could not load unpaid orders'}</strong>
          <span>{unpaid.message}</span>
          {status === 'error' ? <button className="button dark" type="button" onClick={onRefresh}>Try again</button> : null}
        </div>
      ) : null}
      {status === 'empty' ? <p className="qsc-orders-note" role="status">No unpaid counter orders. Everything is settled.</p> : null}
      {view && status === 'ready' ? (
        <>
          <p className="qsc-unpaid-summary" role="status"><strong>{view.count} {view.count === 1 ? 'order' : 'orders'}</strong> outstanding · <strong>{view.outstandingTotal}</strong></p>
          <ul className="qsc-order-list">
            {view.orders.map((order) => (
              <li key={order.orderId || order.orderNumber} className="qsc-order-item" data-unpaid-order={order.orderNumber}>
                <button type="button" className="qsc-order" aria-label={'Open order ' + order.orderNumber} onClick={() => onOpenOrder?.(order.orderId, 'unpaid')}>
                  <div className="qsc-order-head">
                    <strong>{order.orderNumber}</strong>
                    <span className={'qsc-age' + (order.ageDays > 0 ? ' qsc-age-older' : '')}>{order.ageLabel}</span>
                  </div>
                  <div className="qsc-order-body">
                    <div className="qsc-order-what">
                      {order.items.length ? order.items.map((item, index) => <span key={index}>{item.name}{item.detail ? <small> · {item.detail}</small> : null}</span>) : <span>No items</span>}
                      <small>{order.customer}{order.contact ? ' · ' + order.contact : ''}</small>
                      <small>{order.createdDate} {order.createdTime}</small>
                    </div>
                    <div className="qsc-order-money">
                      <strong>{order.outstanding}</strong>
                      <span className="qsc-state qsc-state-unpaid">Unpaid</span>
                      {order.amountPaid ? <small>{order.amountPaid} received</small> : null}
                    </div>
                  </div>
                  <small className="qsc-order-status">{order.statusLabel}</small>
                </button>
              </li>
            ))}
          </ul>
        </>
      ) : null}
    </section>
  )
}

export default function CounterView({
  state,
  selectedId = null,
  draft = null,
  customer = EMPTY_COUNTER_CUSTOMER,
  sale = initialSale(),
  onSelect,
  onChange,
  onCustomerChange,
  onReview,
  onBackToEdit,
  onSubmit,
  onNewSale,
  onRetry,
  onSignIn,
  signInError = '',
  signInBusy = false,
  onSignOut,
  view = 'sale',
  onView,
  orders = { status: 'loading' },
  onRefreshOrders,
  orderDetail = { status: 'loading' },
  payment = initialPayment(),
  onOpenOrder,
  onBackToOrders,
  onChoosePayment,
  onCancelPayment,
  onConfirmPayment,
  onResetPayment,
  onReloadOrder,
  onOpenReceipt,
  onCloseReceipt,
  onPrintReceipt,
  cashup = { status: 'loading' },
  onRefreshCashup,
  onSelectCashupDate,
  cancelled,
  onRefreshCancelled,
  cancelCheck,
  cancel,
  onStartCancel,
  onCancelReason,
  onAbortCancel,
  onConfirmCancel,
  onResetCancel,
  unpaid = { status: 'loading' },
  onRefreshUnpaid,
  orderOrigin = 'orders'
}) {
  const status = state?.status || 'loading'
  const signedIn = status !== 'signed-out'

  let body
  if (status === 'signed-out') {
    body = <CounterSignIn onSignIn={onSignIn} error={signInError} busy={signInBusy}/>
  } else if (status === 'loading') {
    body = <Notice icon="clock" title="Loading the counter…">Fetching today’s counter products.</Notice>
  } else if (status === 'denied') {
    body = <Notice tone="error" icon="xCircle" title="No counter access">{state.message}</Notice>
  } else if (status === 'unavailable') {
    body = <Notice tone="error" icon="alertCircle" title="Counter unavailable">{state.message}</Notice>
  } else if (status === 'error') {
    body = (
      <Notice tone="error" icon="alertCircle" title="Could not load the counter" action={<button className="button dark" type="button" onClick={onRetry}>Try again</button>}>
        {state.message}
      </Notice>
    )
  } else if (status === 'empty') {
    body = (
      <Notice icon="store" title="No counter products yet" action={<button className="button ghost" type="button" onClick={onRetry}>Refresh</button>}>
        Nothing is switched on for the counter. Products are turned on in Admin.
      </Notice>
    )
  } else {
    const entries = state.entries || []
    const selected = entries.find((entry) => entry.product.id === selectedId) || null
    const writable = selected ? resolveCounterSubmission(selected).status === COUNTER_SUBMISSION.WRITABLE : false
    const inSale = sale.phase !== SALE_PHASES.EDITING && sale.attempt !== null
    const saleBody = (
      <div className="qsc-layout">
        <ProductList sections={groupCounterEntries(entries)} selectedId={selected?.product.id || null} onSelect={onSelect} locked={isSaleLocked(sale)}/>
        <section className="qsc-work" aria-label="Configure">
          {inSale ? (
            <SalePanel sale={sale} onBackToEdit={onBackToEdit} onSubmit={onSubmit} onNewSale={onNewSale} onSignIn={onSignIn} signInError={signInError} signInBusy={signInBusy}/>
          ) : selected ? (
            <>
              <div className="qsc-config">
                <div className="qsc-config-head">
                  <div><span className="eyebrow">{selected.group}</span><h2>{selected.product.name}</h2></div>
                  <ActionBadge action={selected.action}/>
                </div>
                <ProductForm key={selected.product.id} entry={selected} draft={draft} onChange={onChange}/>
                {writable ? <CustomerFields customer={customer} onChange={onCustomerChange}/> : null}
              </div>
              <Preview entry={selected} draft={draft} customer={customer} onReview={onReview}/>
            </>
          ) : (
            <div className="qsc-pick" role="status">
              <Icon name="arrowLeft" size={22}/>
              <div><strong>Choose a product</strong><span>Pick what the customer needs to see its options and a preview.</span></div>
            </div>
          )}
        </section>
      </div>
    )
    const saleWaiting = sale.phase === SALE_PHASES.UNKNOWN
    body = (
      <>
        {view === 'receipt' ? null : <ViewTabs view={view === 'order' ? orderOrigin : view} onView={onView} saleWaiting={saleWaiting} showCancelled={isCancelledListAvailable(cancelled)}/>}
        {view === 'receipt' ? (
          <ReceiptScreen detail={orderDetail} entries={entries} onBack={onCloseReceipt} onPrint={onPrintReceipt}/>
        ) : view === 'order' ? (
          <OrderDetailPanel detail={orderDetail} entries={entries} payment={payment} cancelCheck={cancelCheck} cancel={cancel} onStartCancel={onStartCancel} onCancelReason={onCancelReason} onAbortCancel={onAbortCancel} onConfirmCancel={onConfirmCancel} onResetCancel={onResetCancel} backLabel={orderOrigin === 'cashup' ? '← Cash-up' : orderOrigin === 'unpaid' ? '← Unpaid' : orderOrigin === 'cancelled' ? '← Cancelled' : undefined} onBack={onBackToOrders} onChoose={onChoosePayment} onCancel={onCancelPayment} onConfirm={onConfirmPayment} onReset={onResetPayment} onReload={onReloadOrder} onOpenReceipt={onOpenReceipt} onSignIn={onSignIn} signInError={signInError} signInBusy={signInBusy}/>
        ) : view === 'cancelled' ? (
          <CancelledPanel cancelled={cancelled} entries={entries} onRefresh={onRefreshCancelled} onOpenOrder={onOpenOrder} onSignIn={onSignIn} signInError={signInError} signInBusy={signInBusy}/>
        ) : view === 'unpaid' ? (
          <UnpaidPanel unpaid={unpaid} entries={entries} onRefresh={onRefreshUnpaid} onOpenOrder={onOpenOrder} onSignIn={onSignIn} signInError={signInError} signInBusy={signInBusy}/>
        ) : view === 'cashup' ? (
          <CashupPanel cashup={cashup} entries={entries} onRefresh={onRefreshCashup} onSelectDate={onSelectCashupDate} onOpenOrder={(orderId) => onOpenOrder?.(orderId, 'cashup')} onSignIn={onSignIn} signInError={signInError} signInBusy={signInBusy}/>
        ) : view === 'orders' ? (
          <OrdersPanel orders={orders} entries={entries} saleWaiting={saleWaiting} onRefresh={onRefreshOrders} onOpenOrder={onOpenOrder} onSignIn={onSignIn} signInError={signInError} signInBusy={signInBusy}/>
        ) : saleBody}
      </>
    )
  }

  return (
    <div className="qsc-app">
      <TopBar signedIn={signedIn} onSignOut={onSignOut}/>
      <main className="qsc-main">{body}</main>
    </div>
  )
}
