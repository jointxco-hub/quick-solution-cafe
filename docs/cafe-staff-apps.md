# Café staff installs and notifications

Admin and Counter have separate manifest IDs, names, icons and launch routes. Browser staff authentication and server capabilities continue to control access. There is no offline order or payment submission and the service worker does not cache responses.

On iPhone/iPad (iOS 16.4+), open `/admin` or `/counter` in Safari, use Share → Add to Home Screen, and launch that Home Screen app before enabling alerts. Android and desktop browsers offer Install app when supported. Each device must explicitly opt in.

The staff header offers Install, Enable alerts, Test alert and Turn alerts off. Notifications cover new submitted orders, payment status becoming paid, and orders becoming ready. Payloads contain generic wording; tapping an order alert opens that order in the corresponding staff app, navigating an existing window before focusing it. A Counter notification for an order unavailable through the Counter read falls back to the same order in Admin, where normal Admin access checks still apply. Test alerts open the app home screen and have no order target. Existing orders are not backfilled. Alerts are queued and dispatched once per minute, with up to five attempts. Expired subscriptions are removed. Membership/module access is checked when subscribing and again when claiming deliveries. Sign-out attempts to revoke both app subscriptions on this browser; an offline logout may not reach the server until connectivity returns.

## Backend deployment

Apply `20261008082604_cafe_staff_push.sql` only to the correct Café/XOS database. It requires the established tenant capability helper, `commerce.service_orders`, Vault, pg_net and pg_cron. The scheduler is inert until configuration exists.

Generate a fresh P-256 VAPID keypair and a cryptographically random dispatcher secret separately for each environment. Keep private values outside git and browser environment variables. Save the JSON in Vault under `qs_staff_push_config`:

- `publicKey`: base64url uncompressed P-256 public key
- `privateKey`: base64url P-256 private key
- `subject`: a valid `https:` or `mailto:` VAPID contact URI
- `dispatchSecret`: random server-only secret
- `url`: that environment's Supabase URL

Deploy `supabase/functions/quick-solution-push/index.ts` with `verify_jwt=false`: the function explicitly verifies staff tokens with Auth, and a constant-time secret comparison authenticates the scheduler. RPCs enforce tenant/capability access. Sender/config RPCs are granted only to service_role. Do not reuse staging signing secrets in production.

Staging deployment: 8 October 2026, Joint X XOS Staging (`tijiamrfnxrbitafiflj`). Production deployment: 10 October 2026, Alethea Ecosystem (`slhcvyeuqsduaglddqdb`), after confirming the active Café tenant and capability helper. Production received pg_net/pg_cron prerequisites, the tested push migration, Edge sender v1 and freshly generated production Vault values. The live `https://cafe.jointx.co.za` bundle points to this production database. Permission checks passed; unsigned staff/dispatcher requests returned 401 and Vault-authenticated dispatch returned 200. Device opt-in remains per origin and app; preview installs do not subscribe the live site.

## Validation

- `npm run build`
- `npm test` (eight existing OPPS cross-worktree checks skip when that separate checkout is absent)
- `supabase/tests/cafe_staff_push.sql`: rollback-only staging test for ACLs, staff roles, trigger events, duplicate suppression, privacy and unsubscribe
- Live Edge HTTP checks: unsigned requests must return 401; authenticated dispatcher with an empty queue returns 200
- Device tests confirmed installs, test delivery on both phones, locked-screen delivery, new-order delivery on both phones and staff navigation. Order-specific tap routing after the follow-up fix still requires a fresh device test: install Admin and Counter, sign in with the corresponding staff access, enable alerts, tap Test alert, close the app, and verify delivery and correct route on tap. Disable alerts and repeat to confirm no notification. Also confirm denied-permission guidance, mobile header wrapping and that existing counter sale/payment/receipt flows still work.

Push delivery is best effort: a process crash after a push service accepts an alert but before the database acknowledgment can cause a retry. The stable event tag replaces the same displayed alert rather than accumulating duplicates.

## Unified Café app transition

Both staff routes now advertise `staff-cafe.webmanifest`, with one stable app identity (`/staff-admin`) and Counter/Orders shortcuts. The existing Admin identity is retained to allow compatible browsers to update it. Legacy manifests remain available so existing separate shortcuts do not break. Existing Counter installations may need a one-time removal and install of the Café app; browser/OS handling must be checked on the real devices. No installed-app detection is assumed for ordinary browser tabs.

App settings contains installation help and notification controls, including the test button. Installed windows do not offer installation. Notification status checks both existing subscription channels so switching workspaces does not ask an opted-in operator to enable again. Existing server capability checks remain in place; unavailable channels are not enabled. Turning alerts off removes both channels for the signed-in user's current endpoint. Notification clicks navigate an existing staff window across workspaces while retaining the order target.

Validation: manifest/worker contract tests and production build. Real iPhone and desktop install/update behavior still requires device review.
