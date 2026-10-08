# Café staff installs and notifications

Admin and Counter have separate manifest IDs, names, icons and launch routes. Browser staff authentication and server capabilities continue to control access. There is no offline order or payment submission and the service worker does not cache responses.

On iPhone/iPad (iOS 16.4+), open `/admin` or `/counter` in Safari, use Share → Add to Home Screen, and launch that Home Screen app before enabling alerts. Android and desktop browsers offer Install app when supported. Each device must explicitly opt in.

The staff header offers Install, Enable alerts, Test alert and Turn alerts off. Notifications cover new submitted orders, payment status becoming paid, and orders becoming ready. Payloads contain generic wording; tapping one opens the corresponding staff app. Existing orders are not backfilled. Alerts are queued and dispatched once per minute, with up to five attempts. Expired subscriptions are removed. Membership/module access is checked when subscribing and again when claiming deliveries. Sign-out attempts to revoke both app subscriptions on this browser; an offline logout may not reach the server until connectivity returns.

## Backend deployment

Apply `20261008082604_cafe_staff_push.sql` only to the correct Café/XOS database. It requires the established tenant capability helper, `commerce.service_orders`, Vault, pg_net and pg_cron. The scheduler is inert until configuration exists.

Generate a fresh P-256 VAPID keypair and a cryptographically random dispatcher secret separately for each environment. Keep private values outside git and browser environment variables. Save the JSON in Vault under `qs_staff_push_config`:

- `publicKey`: base64url uncompressed P-256 public key
- `privateKey`: base64url P-256 private key
- `subject`: a valid `https:` or `mailto:` VAPID contact URI
- `dispatchSecret`: random server-only secret
- `url`: that environment's Supabase URL

Deploy `supabase/functions/quick-solution-push/index.ts` with `verify_jwt=false`: the function explicitly verifies staff tokens with Auth, and a constant-time secret comparison authenticates the scheduler. RPCs enforce tenant/capability access. Sender/config RPCs are granted only to service_role. Do not reuse staging signing secrets in production.

Backend migration, Vault setup and Edge Function were deployed only to Joint X XOS Staging (`tijiamrfnxrbitafiflj`) on 8 October 2026. No production database or production secrets were modified. Frontend deployment remains subject to Vercel project access.

## Validation

- `npm run build`
- `npm test` (eight existing OPPS cross-worktree checks skip when that separate checkout is absent)
- `supabase/tests/cafe_staff_push.sql`: rollback-only staging test for ACLs, staff roles, trigger events, duplicate suppression, privacy and unsubscribe
- Live Edge HTTP checks: unsigned requests must return 401; authenticated dispatcher with an empty queue returns 200
- Device check still required: install Admin and Counter, sign in with the corresponding staff access, enable alerts, tap Test alert, close the app, and verify delivery and correct route on tap. Disable alerts and repeat to confirm no notification. Also confirm denied-permission guidance, mobile header wrapping and that existing counter sale/payment/receipt flows still work.

Push delivery is best effort: a process crash after a push service accepts an alert but before the database acknowledgment can cause a retry. The stable event tag replaces the same displayed alert rather than accumulating duplicates.
