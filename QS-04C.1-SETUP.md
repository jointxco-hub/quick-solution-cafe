# QS-04C.1 — Orders-first admin + auto-preview polish

This is a follow-up to QS-04C.

## What changes

### Admin
- Orders become the default admin workspace.
- Product editing moves behind a dedicated **Products** tab, reducing the very long single-page admin.
- **Quick Points** and **Settings** are visible as future sections but intentionally disabled for now.
- Selecting an unsent order automatically builds its OPPS preview once.
- Sent orders use the stored pre-send preview payload, so the admin can show what OPPS received without rebuilding a preview after handoff.
- Staff-facing language is simplified:
  - `sent` → **Sent to OPPS**
  - `blocked` → **Needs attention**
  - `unpaid/pending` → **Payment pending**
  - mapping/version IDs move into collapsed **Technical details**.
- The main status area now surfaces file count and fulfilment instead of internal mapping terminology.

### Storefront
- The visual story rail is shortened and made more scan-friendly:
  - **Print it**
  - **Brand it**
  - **Collect local**
- Copy is reduced so the images/illustrations carry more of the section.

## Backend
Staging already has:

- `20260913182227_qs_04c_1_handoff_queue_payload`
- `20260913182534_qs_04c_1_sent_preview_stability`

The first enriches the authenticated handoff queue with stored `previewPayload` and `sentAt`. The second protects sent jobs from having their canonical preview overwritten by a later preview call, and repairs the existing sent test order's stored blocker state. No pricing rules are changed.

Do **not** run the SQL manually against Staging again.

## Apply
Copy this patch over the existing QS-04C files, then run:

```powershell
npm run dev
```

Open:

```text
http://localhost:5173/#admin
```

(or whichever Vite port is shown in the terminal).

Expected behavior:
1. Admin opens on **Orders**.
2. The first selected sent order immediately shows its stored canonical OPPS payload.
3. Selecting an unsent order automatically performs its first preview/check.
4. **Products** switches to the existing catalogue editor.
5. Storefront visual copy is shorter and lighter.

After acceptance:

```powershell
git add .
git commit -m "QS-04C.1 polish admin handoff UX"
git push
```
