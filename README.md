# Sleepless Cafe — 4-Role POS & Ordering System

One repository, four independent static HTML interfaces, one Supabase project as
the entire backend (PostgreSQL + SQL functions + Storage + Realtime + RLS). No
Node/Express runtime is deployed. Every client API call returns the SOP JSON
envelope `{ "success": true, "data": {}, "error": null }`.

## The interfaces

| Interface | File | Who reaches it | How |
|---|---|---|---|
| Customer launcher (public root) | `index.html` | customers | GitHub Pages root `/` |
| Customer menu & checkout | `menu.html` | customers | from `index.html` |
| Cashier | `cashier.html` | staff | direct URL / bookmark only |
| Kitchen / KDS | `kitchen.html` | staff | direct URL / bookmark only |
| Owner dashboard | `owner.html` | staff | direct URL / bookmark only |

On GitHub Pages the URLs are `https://<you>.github.io/<repo>/index.html`,
`.../menu.html`, `.../cashier.html`, `.../kitchen.html`, `.../owner.html`.
The three staff pages are unlisted and unguessable from the public customer page
(`noindex` on all three; the customer page is intentionally indexable).

## The two-tier record (core invariant)

- **Unpaid is disposable.** An order lives only as a live claim. If the customer
  has not presented its 5-digit code to the cashier within **60 minutes**, the row
  is **physically deleted** from `orders` and its `order_items` children cascade
  away (`ON DELETE CASCADE`). No `expired` tombstone — the database forgets the
  customer entirely.
- **Paid is permanent.** The instant `confirm_payment()` succeeds, the order
  enters the pipeline (`paid → preparing → served`) and is **never deleted and
  never aged out** — it is the permanent sales record every analytics query reads.

So `orders` always means exactly: **live unpaid claims (≤60 min old) + the full
history of paid sales.** `status` enum is only `pending_payment · paid · preparing
· served`; `expired` and `cancelled` do not exist. `purge_expired_orders()` is the
single `DELETE` path in the codebase and can never match a paid row.

## Phase schedule

| # | Phase | Owner | Deliverables | Gate to next phase |
|---|---|---|---|---|
| 0 | Repo + Pages scaffold | `devops-lead` | git init, `.gitignore`, `README.md`, `assets/tokens.css`, `index.html` launcher | Pages live at `/<repo>/`, launcher renders on phone |
| 1 | Supabase backend | `backend-lead` | `sql/01–05`, verified in Supabase Dashboard | Every function returns expected JSON/rows in the Dashboard "Run" test; seed menu visible |
| 2 | Customer page | `frontend-lead` | `menu.html`, `assets/api.js`, `assets/config.js` | Cart → checkout → real order in DB with a real 5-digit code |
| 3 | Cashier page | `frontend-lead` | `cashier.html` | Code lookup + live unpaid table + countdown + Confirm Payment flips status to `paid` |
| 4 | Kitchen KDS | `frontend-lead` | `kitchen.html`, `assets/realtime.js` | Paid order appears without refresh; Mark as Served writes `served_at` + `fulfillment_time_seconds` |
| 5 | Owner dashboard | `frontend-lead` + `backend-lead` | `owner.html`, `sql/02` analytics fns, Storage upload | Auth gate blocks anonymous; menu builder creates a real, renderable item |
| 6 | QA sweep | `qa-engineer` | `tests/api.spec.md`, lint/link checks | Zero console errors, zero dead links, envelope compliance on all 5 pages |
| 7 | Phase A deploy + dogfood | `devops-lead` | GH Pages build, mobile test, 3-order walkthrough | Full loop passes on the public URL: place → pay → serve → analytics |
| 8 | Phase B Vercel go-live | `devops-lead` | `tools/inject-config.mjs`, `vercel.json`, domain, Tailwind build | Phase A gate green + production checklist §7 all ticked |

Phases 2–5 are strictly ordered — each page depends on the previous page's DB side
effects being real.

## Running locally

`index.html` is a static page. Serve the repo root with any static server
(e.g. `python -m http.server 8000` then open `http://localhost:8000/`), or push to
GitHub Pages and open the live URL. On a phone, open the Pages URL directly.

## Configuration & secrets (§4)

`assets/config.js` resolves config in priority order so one file works on both
hosts:

1. `window.SL_CONFIG` — injected at Vercel build time by `tools/inject-config.mjs`
2. `localStorage` override — dev convenience (`?debug=1` page)
3. Committed defaults — **publishable key only**

- **Phase A (GitHub Pages):** the owner pastes the Supabase URL + publishable key
  into `?sburl=&sbkey=` once; the page writes it to `localStorage`. Nothing secret
  is committed.
- **Phase B (Vercel):** `SL_SB_URL`, `SL_SB_KEY`, `SL_OWNER_EMAILS` are Vercel env
  vars; `inject-config.mjs` runs as the build command and writes
  `assets/config.generated.js` (git-ignored).

## Security

- **Publishable key only** may ever appear in the browser or the repo.
- The **service-role key never appears in the repo, in any page, or in the browser.**
- Owner privileges come from **Supabase Auth + RLS**, not a client-side admin flag.
  `CONFIG.ownerEmails` is an allowlist check, not the security boundary — RLS is.
- `.gitignore` excludes `assets/config.generated.js`, `.env*`, `*.local`, `**/.vercel/**`.

## Supabase setup order

Apply the SQL in order: `sql/01_schema.sql` → `sql/02_functions.sql` →
`sql/03_rls.sql` → `sql/04_realtime.sql` → `sql/05_seed.sql`. `sql/05_seed.sql` is
required so the dev build has a menu to render before the owner builds one.

> `Sleepless.html` is design reference only (palette/type source). It is not part
> of the POS set and is not linked by, nor does it link to, any POS page.
