// QS checkout hardening — the PayFast init/redirect decision, pulled out as a
// pure function the same way lib/navigation.js pulls page-routing decisions
// out of App.jsx: this repo's test suite is plain Node --test with no DOM/
// rendering harness, so "repeated click cannot initiate twice" and "the
// button shows the right state" are proven here, as data-in/data-out, rather
// than by simulating real clicks against a component tree.
//
// Every caller (OrderBasket.jsx's startCombinedPayment, GuidedOrder.jsx's
// startPayment, PaymentReturn.jsx's payAgain) follows the same shape:
//   1. canStartPayfastRedirect(state) - checked FIRST, synchronously, before
//      any state is set or any async call is made. This is the actual
//      double-click guard: React re-rendering the disabled button is not
//      synchronous, so a second click that lands before that render commits
//      must still be rejected by a plain boolean check, not by the DOM
//      attribute alone.
//   2. call beginQuickSolutionPayment(...) (unchanged, this file never wraps
//      or replaces it)
//   3. resolvePayfastInitOutcome(result) - the response is turned into
//      exactly one of three outcomes; the caller's own state machine is
//      built entirely from this value, so every caller behaves identically
//      given the same server response.

// Which local payment-state values are safe to start a NEW PayFast
// initiation from. 'starting' (the init call is in flight) and
// 'redirecting' (payment_url exists, window.location.assign is about to be
// or already was called) both refuse a second start - the loader must stay
// visible and the button disabled through the actual navigation, per the
// external-payment UX rule this hardening slice adds. 'paid' also refuses,
// since there is nothing left to pay. Every other value (undefined, 'idle',
// 'error') is safe to start from.
const BLOCKED_STATES = new Set(['starting', 'redirecting', 'paid'])

export function canStartPayfastRedirect(state) {
  return !BLOCKED_STATES.has(state)
}

// Turns beginQuickSolutionPayment's raw response into exactly one outcome.
// Never throws - a missing payment_url is reported as an 'error' outcome,
// not an exception, so every caller's catch block only has to handle a
// genuine network/RPC failure, not a malformed-but-200 response too.
export function resolvePayfastInitOutcome(result) {
  if (result?.alreadyPaid || result?.paymentStatus === 'paid') {
    return { type: 'paid' }
  }
  if (!result?.payment_url) {
    return { type: 'error', message: 'PayFast did not return a payment link.' }
  }
  return { type: 'redirect', url: result.payment_url }
}
