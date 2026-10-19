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

## Phase A — GitHub Pages (Gate A)

### 1. Ship it

1. Create the **public** repo `sleepless-cafe-pos`; `index.html` sits at the repo root.
2. Supabase Dashboard → SQL: paste `sql/01_schema.sql` → `sql/02_functions.sql` → `sql/03_rls.sql` → `sql/04_realtime.sql` → `sql/05_seed.sql`, one file at a time, in that order.
3. Settings → Pages → Deploy from a branch → `main` / `/`; HTTPS on.
4. Commit in conventional order, then push (no `gh pages` flag needed — Pages serves plain URLs):

```text
git add .gitignore README.md MASTER_PLAN.md AGENTS.md assets/ sql/ index.html
git commit -m "chore: phase 0-1 repo scaffold, brand tokens and supabase sql backend"
git add menu.html cashier.html kitchen.html owner.html
git commit -m "feat: phase 2-5 customer, cashier, kitchen KDS and owner surfaces"
git add tests/api.spec.md
git commit -m "docs: phase 6 qa api contract"
git add README.md
git commit -m "docs: phase 7 gate A deploy and dogfood checklist"
git push origin main
```

Live URLs: `https://<you>.github.io/sleepless-cafe-pos/index.html`, `/menu.html`,
`/cashier.html`, `/kitchen.html`, `/owner.html`.

### 2. Config injection (Phase A only)

Open each page once with the query params; the page writes them to `localStorage`, so later visits need none.

- `index.html` — no params (static launcher).
- `menu.html` — `?sburl=<supabase-url>&sbkey=<publishable-key>`
- `cashier.html` / `kitchen.html` / `owner.html` — same, plus `?email=&password=` once (stored in `sl_auth`).

The password is never rendered on screen and never committed; only the publishable key may ever appear in the browser.

### 3. Supabase Dashboard prerequisites

- [ ] Public Storage bucket `menu-images` exists — the owner menu-builder uploads there and `menu_items.image_url` stores the public URL.
- [ ] At least one Auth user created (password provider on); its email is listed in `CONFIG.ownerEmails`.
- [ ] An anonymous (publishable-key-only) call of an owner RPC returns `OWNER_SESSION_REQUIRED`, not rows.

### 4. Mobile dogfood — 3-order walkthrough (phone)

- [ ] Open the Pages URL on the phone; `index.html` → `menu.html` renders the seeded menu.
- [ ] Place order 1: add items → checkout → Full Name.
- [ ] Success screen shows the 5-digit code with leading zeros kept (e.g. `04271`).
- [ ] On `cashier.html`, type the code → exact lookup finds the row.
- [ ] Confirm Payment flips the row to `paid`.
- [ ] On `kitchen.html`, the card appears **without refreshing** (WS live dot green).
- [ ] Elapsed counter ticks up on the card.
- [ ] Mark as Served → card leaves the view.
- [ ] Owner Sales tab counts it; CSV export downloads it.
- [ ] Turnover tab shows the hour in the peak-hour histogram.
- [ ] Place a throwaway order 4, then void it from Owner Tab 1: tap **Void claim** (arms the row), then **Confirm void** → the row and its items are gone. Fast DELETE proof, no 60-min wait.
- [ ] Repeat for orders 2 and 3; leave order 3 unpaid to feed the TTL proof below.

### 5. Gate A checklist

- [ ] Repo public, Pages enabled from `/` on `main`
- [ ] `index.html` is the customer entry only; no POS page links to another POS page or to `Sleepless.html`
- [ ] Staff URLs (`cashier`/`kitchen`/`owner`) unlisted — direct link/bookmark only, `noindex` on all three
- [ ] `assets/tokens.css` is the only place brand colors are defined
- [ ] Supabase project created, `sql/01–05` applied, seed menu present
- [ ] Config injected via query param → localStorage, nothing secret committed
- [ ] End-to-end dogfood on a phone: place order → cashier confirms → kitchen serves → owner analytics shows it
- [ ] TTL proven by deletion, not hiding: place an unpaid order, wait past 60 min, then `SELECT` its code in the Supabase Dashboard → **no row**, and `order_items` count for that `order_id` → **0**
- [ ] Permanence proven: a `paid` order survives 10 consecutive sweep calls and still appears in analytics
- [ ] `Sleepless.html` untouched (governance: do not refactor unrelated files)

Hard proofs, run in the Dashboard SQL editor after the 60-min wait (order 3 above):

```sql
SELECT code, status FROM orders WHERE code = '04271';
SELECT COUNT(*) FROM order_items WHERE order_id = '<uuid>';
```

Expected: first returns **no row**, second returns **0**. A `paid` order re-run through the same two queries must still return its row and its item count.

### 6. Stop before Phase B

Phase 8 (Vercel) starts only once every Gate A box above is ticked; `tools/` does not exist yet.

> `Sleepless.html` is design reference only (palette/type source). It is not part
> of the POS set and is not linked by, nor does it link to, any POS page.
