# Production reconciliation (not part of the normal migration replay)

These two files are **not** in `supabase/migrations/` on purpose. Both target production's
current, real, sparse state (see the read-only production lineage audit) and each begins with a
hard preflight that raises if its target objects already exist — deliberately, to prevent a
double-apply. Staging and this repo's own local disposable harness already have every object
these files create (from the ordinary migration history), so if either file sat in
`supabase/migrations/`, `npm run test:sql` and any future `supabase db push` against staging
would pick it up by filename order and fail outright on that same preflight guard. This was
caught by running the full harness with both files present (`[FAIL] migration
20260927140000_qs_production_reconciliation.sql - ... already exists - this migration must not
run`) — confirmed, then fixed by moving them here.

- `20260927140000_qs_production_reconciliation.sql` — brings production's `commerce.*`
  tables/RPC layer up to current main's shape (see its own header for the full rationale).
- `20260927150000_qs_canonical_tracking_subsystem_restoration.sql` — restores the canonical,
  staging-only customer-tracking subsystem (`commerce.qs_issue_tracking_token`,
  `commerce.service_order_tracking_tokens`, `public.get_quick_solution_tracking`) into git.
  Must run **after** the reconciliation migration above (see its own header).
- `20260928090000_qs_upload_authorization_rpcs_restoration.sql` — restores only
  `public.qs_authorize_file_upload` and `public.qs_register_file_upload` (the two RPCs the
  `quick-solution-upload` Edge Function depends on), extracted out of
  `20260913163950_qs_03_1_upload_tokens.sql`. That migration's own ledger row was never applied
  to production, and its committed body is no longer safe to apply as-is there — it also
  replaces `public.create_quick_solution_order` with a body dated before the later
  `quoteRequired`/`PHOTOGRAPHY_SESSION` checkout-protection guard, which production's live
  `create_quick_solution_order` already carries. This file's postflight pins that function's
  hash and would fail loudly if it were ever run somewhere that hash doesn't hold (confirmed:
  staging's own `create_quick_solution_order` hash already differs from production's, exactly
  the same reason the other two files above live here instead of `supabase/migrations/`).

Apply each to production exactly once, using the same hash-verified, one-transaction method
already used for every other production/staging change in this project (read the file's exact
committed content by git SHA, verify its hash, wrap in `begin; ... commit;` with the guard DO
block and a manual `insert into supabase_migrations.schema_migrations`). Once genuinely applied
to production, this directory's job for that file is done — it stays here as a record, but
never gets replayed again anywhere.
