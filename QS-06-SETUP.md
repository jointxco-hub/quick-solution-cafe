# QS-06 — Verified Easy Locate ↔ Quick Point linking

QS-06 replaces manual Easy Locate IDs with a verified search-and-link workflow.

## Architecture

- **Easy Locate** stays the source of truth for public business identity/discovery.
- **Quick Solution XOS** stays the source of truth for collection/drop-off, services, fees, status and fulfilment ordering.
- The browser cannot manufacture a verified link.
- A Quick Solution Edge Function searches Easy Locate's safe public business RPCs and re-checks the selected business by slug before writing the XOS link.
- XOS stores only a safe public snapshot plus the external ID/slug/canonical URL and verification time.
- One Easy Locate business can only be linked to one Quick Solution fulfilment point at a time.

## Already live on XOS Staging

Migrations:
- `20260913185224_qs_06_easy_locate_verified_links`
- `20260913185354_qs_06_verified_link_guard`

Edge Function:
- `quick-solution-easy-locate` version 1, active
- custom staff authentication inside the function (`verify_jwt=false` deliberately; the function validates the supplied staff session before doing anything)

Do not manually re-run these migrations on Staging.

## One-time connector secret setup

The XOS Edge Function needs Easy Locate's **public frontend publishable/anon key** so it can call Easy Locate's public RPCs. Do not use an Easy Locate service-role key.

A PowerShell helper is included. From the Quick Solution project root run:

```powershell
powershell -ExecutionPolicy Bypass -File .\scripts\configure-easy-locate-connector.ps1
```

By default it looks for the sibling project:

```text
..\Easy Locate\.env.local
```

It reads `VITE_SUPABASE_PUBLISHABLE_KEY` or `VITE_SUPABASE_ANON_KEY` locally and writes it straight to XOS Staging Edge Function secrets without printing the key.

If Easy Locate lives somewhere else:

```powershell
powershell -ExecutionPolicy Bypass -File .\scripts\configure-easy-locate-connector.ps1 -EasyLocatePath "C:\path\to\Easy Locate"
```

## UX acceptance

1. Run the connector setup command above.
2. Start Quick Solution with `npm run dev`.
3. Open `#admin` → **Quick Points**.
4. The Easy Locate section should no longer show the one-time setup warning.
5. Click **Find business** and search a real public Easy Locate business.
6. Click **Verify & link**.
7. The linked card should show the business name, area/category, verification time, **View listing**, **Change link**, and **Unlink**.
8. Reload the page and confirm the link persists.

No test/fake Quick Point or Easy Locate business was persisted during backend acceptance.

## Commit

```powershell
git add .
git commit -m "QS-06 verify Easy Locate Quick Point links"
git push
```
