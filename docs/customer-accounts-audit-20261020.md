# Café customer accounts: implementation checkpoint

Read-only audit on 20 October 2026. Production source is `62f48bbe5a4c5c909592eb7df6a0c4bf6f770998`, Vercel production deployment `dpl_3rdWJd2Nm3v6TttXXx49X382gY9A` (READY). No customer, auth, payment or schema records were changed.

## Verified existing behavior

| Capability | Evidence and current limit |
| --- | --- |
| Guest checkout | Existing cart/order RPCs; no customer session attached. |
| Guest tracking | `/track` accepts the secure tracking link or the existing contact lookup. Tracking is not account ownership. |
| PayFast retry | `PaymentReturn.jsx` retrieves a payment token from `paymentSession.js` localStorage in the original browser. This is not cross-device recovery. |
| Staff sign-in | Password and Google flows use the staff session store. Customer sessions must not reuse it. |
| Customer sign-in / My orders | No route or customer API implementation found in the production source. |
| Ownership | Production `commerce.service_orders` has no customer user/owner ID. Both production and staging lack Café customer ownership tables and `qs_customer*` / `qs_my*` RPCs. `created_by` is the counter creator, not a customer owner. |
| Shared receipts | Already released. Customer features must consume the shared receipt/balance service rather than write a second ledger. |

## First staging implementation

1. Verify actual Auth provider, delivery, redirect allowlist and email template configuration before selecting the enabled sign-in methods. Documentation availability is not evidence of configuration. Do not send a test sign-in email to a customer without authorization.
2. Add a customer-only session and `/account` entry point with sign-in/out, expired-session recovery and clear loading/error/empty states. Use the existing Auth project; grant no staff membership or capability.
3. Add server-controlled, tenant-scoped order ownership. Attach newly created orders through authenticated checkout and record an immutable owner identity. Never infer ownership from `created_by`, user-editable metadata, a supplied email/phone/name or order number.
4. For historical guest claims, require verified identity plus a validated order-specific secret or an audited staff-assisted recovery path. Do not bulk-claim all orders with a matching contact. Keep the existing guest flow.
5. Add paginated My orders and a customer-safe order detail response with status, items, settled receipts and authoritative outstanding balance. Do not expose staff notes, supplier costs or private storage paths.
6. Add an authenticated resume-payment endpoint for an owned, payable order, feeding the existing PayFast initiation and shared settlement flow. Do not return to editable basket, recreate the order or mark paid from a browser return URL. Do not rotate the singleton guest payment token for an account payment session; preserve existing guest links and active payment attempts.

## Required acceptance

- Customer A cannot list, open, claim or resume payment for B's order, including another tenant and forged IDs.
- Unverified/expired sessions fail safely; customer sign-out does not clear or revoke the separate staff session.
- Guest checkout and secure tracking continue to work. Signed-in checkout attaches ownership server-side, including retried requests.
- A second browser can sign in and find the original order without original-browser localStorage.
- Paid, cancelled, review-blocked and pending-attempt orders use server-side payment eligibility. Concurrent clicks/callbacks preserve one settlement.
- Customer-visible balance matches Café Admin, OPPS and any linked invoice; receipts are not counted twice.
- Stage sign-in delivery and mobile acceptance before production release. Auth provider configuration and real email delivery are not yet verified by this audit.

## Implementation checkpoint

The branch now implements `/account`, email-link sign-in in a separate customer session, paginated My orders, customer-safe tracking and receipts, explicit guest-order recovery, and payment resumption through the existing PayFast handler. Signed-in checkout carries the customer token and the database transaction links ownership. No membership or staff capability is created. Staging Auth settings report email enabled, Google disabled and signup autoconfirm enabled, so the server requires OTP/magiclink authentication evidence and a current Auth session rather than treating password signup as mailbox verification.

The new migration is `20261020083549_cafe_customer_accounts.sql`. Ownership and short-lived payment-session tables are private (RLS enabled, no anon/authenticated table grants), checked public endpoints use a fixed empty search path, and private helpers are revoked. Account payment tokens supplement the existing guest token; they do not rotate it. The account balance snapshot uses the existing shared receipt and invoice-reconciliation data; mirrors are not added together. This migration does not change the staff payment writer or PayFast edge handler.

Verification completed:

- 76 focused customer-session, navigation, counter and channel checks pass; Vite build and diff check pass.
- Full JS suite: 798 passed, 8 skipped, 5 failed. All five also fail on unchanged production source `62f48bb` (three outdated basket-label tests and two outdated courier-content assertions).
- Final core migration and behavioral SQL ran successfully in a rollback transaction on staging. The checks cover mailbox/session evidence, new ownership, A/B isolation, guest claims including null secrets and invalid tokens, customer gateway token acceptance, retry without a second pending attempt, guest token preservation and expiry. Synthetic identities/orders/attempts were rolled back; no actual gateway request or charge was made.
- The expanded SQL test file additionally covers cross-tenant recovery, direct customer writes and inconsistent/closed payment states. The expanded run returned a connector request-state error, so those extra executed checks are not claimed yet.

Staging activation is blocked: `apply_migration` twice and an atomic SQL fallback returned `McpServerError: Invalid or expired requestState`. Read-back confirms the ownership table and migration history entry are absent. Reads and rollback-only validation work. Reconnect/restore the Supabase write connection, apply the saved migration to staging, rerun the expanded SQL test, compare security advisors, then verify actual email delivery, `/account` redirect allowlisting and browser/mobile acceptance. A redirect/delivery configuration change has not been made or verified. Do not merge to production until these gates pass.

Customer accounts are not live. The preview is for UI review until staging activation succeeds.

## Staging activated, 20 October 2026

Supabase write access recovered on retry. The migration applied successfully to staging as version `20261020083549`; the repository filename now matches the registered version. Expanded behavioral SQL passed, including cross-tenant rejection, direct customer mutation rejection, cancelled-order payment refusal and inconsistent-paid-state review. All synthetic identities, sessions, orders and pending attempts rolled back. Read-back confirms zero persisted customer links and zero account payment sessions. No production changes or real gateway charges were made. This supersedes the earlier deployment blocker and pending expanded SQL notes. Actual email delivery, redirect allowlisting and browser/mobile acceptance still require verification before release.

Security advisor review: the two [RLS-without-policy notices](https://supabase.com/docs/guides/database/database-linter?lint=0008_rls_enabled_no_policy) are intentional for private tables with all anon/authenticated access revoked. The five [authenticated SECURITY DEFINER notices](https://supabase.com/docs/guides/database/database-linter?lint=0029_authenticated_security_definer_function_executable) are intentional checked customer endpoints; verified identity/session, tenant and ownership enforcement passed the behavioral tests. No new account endpoint is anonymous-executable. Unrelated baseline advisor findings were not changed.
