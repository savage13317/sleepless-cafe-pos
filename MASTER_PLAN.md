# MASTER PLAN — Sleepless Cafe 4-Role POS & Ordering System

**Status:** Plan approved for execution · **Deploy target Phase A:** GitHub Pages · **Deploy target Phase B:** Vercel (operational)
**Spec source:** `SYSTEM ARCHITECTURE & DEVELOPMENT SPECIFICATION.md` · **Governance:** `AGENTS.md` · **Design source of truth:** `Sleepless.html`

---

## 0. Executive Summary

One repository, four static HTML entry points, one Supabase project as the entire backend. No Node/Express runtime is deployed — the "backend" is Supabase (PostgreSQL + SQL functions + Storage + Realtime + RLS), and the client-side API layer must still return the SOP JSON envelope so every call site is uniform.

```
Customer ──creates──▶ orders(pending_payment) ──cashier confirms──▶ paid ──kitchen serves──▶ served
                          │                                            │
                          └── 30 min TTL ──▶ ROW DELETED               └── fulfillment_time_seconds
Owner reads everything (analytics + menu builder) ── protected by Supabase Auth + RLS
```

### The two-tier record — this is the core invariant

- **Unpaid is disposable.** An order exists only as a live claim. If the customer has not presented the code to the cashier within 30 minutes, the row is **physically deleted** from `orders`, and its `order_items` children go with it via `ON DELETE CASCADE`. There is no `expired` tombstone, no archived junk, no hidden rows. The database forgets the customer entirely.
- **Paid is permanent.** The instant the cashier confirms, the order enters the pipeline (`paid → preparing → served`) and is **never deleted and never aged out**. It is the permanent sales record that every analytics query reads. `served` is terminal-but-retained, not archived-and-removed.

So the `orders` table has exactly one meaning at all times: **live unpaid claims (≤30 min old) + the complete history of paid sales.**

Order lifecycle (the single state machine every page must agree on):

```mermaid
stateDiagram-v2
    [*] --> pending_payment: create_order() returns 5-digit code
    pending_payment --> paid: confirm_payment() [cashier]
    paid --> preparing: optional manual hold
    paid --> served: mark_served() [kitchen]
    preparing --> served: mark_served()
    pending_payment --> X: purge_expired_orders() — DELETE row (30 min TTL)
    pending_payment --> X: void_order() [cashier void, same path]
    served --> [*]: retained forever in the sales record

    note right of paid
      no edge leaves paid to a deleted state.
      purge_expired_orders() matches status = 'pending_payment'
      only, so paid / preparing / served are unreachable
      from any DELETE in the codebase.
    end note
```

**Hard rules:**
1. State transitions happen **only** inside Supabase SQL functions. No page writes `status` directly.
2. **Only `pending_payment` rows are ever deleted.** `purge_expired_orders()` is the single DELETE path in the codebase; its predicate can never match a `paid`/`preparing`/`served` row.
3. The `status` enum is therefore only `pending_payment · paid · preparing · served`. There is **no `expired` and no `cancelled` status** — expiry and cashier-void both delete, so a status value that describes a deleted row cannot exist.

---

## 1. Governance Reconciliation (read before dispatching sub-agents)

| SOP item | Resolution for this project |
|---|---|
| `backend-lead` owns Express/Node routes | **No Node runtime.** `backend-lead` owns `sql/**` (schema, functions, RLS, Realtime config) + `assets/api.js` (the client transport that wraps Supabase and returns the JSON envelope). |
| JSON standard `{success, data, error}` | Enforced in `assets/api.js` only. Every page consumes `res.data` and branches on `res.error`. No page may `catch` and render raw text. |
| Sequential handoffs | Backend (Phase 1) must pass its verification gate before any frontend phase starts. |
| Security boundaries | Publishable key only in the browser. Service-role key never in the repo, never in a page. Owner privileges come from Supabase Auth + RLS, not from a client-side "admin flag". |
| Static hosting | GitHub Pages cannot do env vars or rewrites → separate `.html` entry points, no path routing. |
| Design reuse | `Sleepless.html` is **reference only** — palette and type are extracted into `assets/tokens.css` in Phase 0. No POS page links to it, and it links to nothing in the POS set. Its dangling `staff.html` link at `:237` is out of scope and left untouched. |

**Deliberate deviations from the spec (with rationale — flag for owner approval):**

1. **Code generation moves server-side.** Spec says the customer page generates the 5-digit code. Client-generated codes cannot be collision-checked atomically across tables. `create_order()` in SQL generates and returns the code in one insert. Customer page displays it; it never invents it.
2. **Auto-expiration is two-pronged.** GitHub Pages has no cron. `purge_expired_orders()` is (a) called lazily by the cashier/kitchen list queries (cheap, self-healing), and (b) scheduled by a Supabase Cron → Edge Function in Phase B. Server-side truth either way.
3. **Tailwind CDN is Phase-A-only.** `cdn.tailwindcss.com` is a dev tool. Phase B on Vercel swaps to a compiled CSS build so production ships one cached stylesheet.
4. **`expired` and `cancelled` statuses are dropped from the spec's enum.** The spec listed both as statuses; under the owner's rule an expired order leaves no row to hold a status. Expiry is a `DELETE`, not an `UPDATE`. Consequence to be aware of: abandoned orders leave **zero trace**, so the owner cannot measure an abandonment rate and the peak-hour heatmap is a heatmap of *paid* orders, not of orders-placed. Accepted as-is; if abandonment ever matters, it needs a separate audit table, which is a Phase-B decision, not a change to this rule.

---

## 2. Repository Layout (target state)

```
Ordering System/
├── AGENTS.md                      (exists — governance)
├── SYSTEM ARCHITECTURE & DEVELOPMENT SPECIFICATION.md   (exists — spec)
├── MASTER_PLAN.md                 (this file — the build contract)
├── README.md                      (Phase 0)
├── .gitignore                     (Phase 0)
│
├── index.html                     (Phase 0 — GitHub Pages root: customer entry only)
├── menu.html                      (Phase 2 — Customer)
├── cashier.html                   (Phase 3 — Cashier)
├── kitchen.html                   (Phase 4 — Kitchen / KDS)
├── owner.html                     (Phase 5 — Owner dashboard, 4 tabs)
│
├── Sleepless.html                 (exists — DESIGN REFERENCE ONLY. Not part of the POS set,
│                                   not linked by or to any POS page, never edited.)
│
├── assets/
│   ├── tokens.css                 (brand palette extracted from Sleepless.html — single source)
│   ├── app.css                    (glass panels, scrollbars, print, KDS high-contrast theme)
│   ├── config.js                  (module: URL/keys resolution — see §4)
│   ├── api.js                     (module: JSON envelope transport + error fallbacks)
│   ├── realtime.js                (module: WS subscribe + polling fallback)
│   └── ui.js                      (module: shared tab/nav/search components)
│
├── sql/
│   ├── 01_schema.sql              (tables, FKs, CHECKs)
│   ├── 02_functions.sql           (the entire state machine)
│   ├── 03_rls.sql                 (policies)
│   ├── 04_realtime.sql            (whitelist events)
│   └── 05_seed.sql                (starter categories + menu items so dev isn't empty)
│
├── tools/
│   ├── inject-config.mjs          (Phase B: env → assets/config.generated.js)
│   └── vercel.json                (headers, cache rules)
│
└── tests/
    └── api.spec.md                (Phase 6 QA: expected JSON for every call)
```

**File-count budget per sub-agent dispatch: 1–3 files.** Never hand a specialist a multi-file refactor.

---

## 3. Phase Schedule & Task Items

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

**Progress (2026-10-19 → 2026-10-24):** Phases 0–4 complete and applied live; Phase 4 gate met (commit `19fef79` — dot reads WS live, paid card appears with no reload, `mark_served` wrote `served_at` + `fulfillment_time_seconds`). **Phase 5 complete and gate met** (owner dashboard boots, anonymous blocked, menu builder produced a real renderable item with a Storage image; `sql/06_storage.sql` added; `delete_category`/`update_menu_item` param-ambiguity fixed live). **Phase 6 complete and gate met** (commit `16f399b` — 14/14 envelope probes, link + static-console sweeps clean, one comment defect fixed). **Phase 7 complete and gate met** (Gate A green except the manual phone run — see the `phase-7` commits in §7).
**Gate A audit added 2026-10-24:** the audit re-ran the gates on the **public host** with `localStorage` cleared
and no query params, and found three defects that the localhost verification had masked — a `REPLACE_ME`
committed config default (site unusable for a first-time visitor), a `/favicon.ico` 404 on every page load, and
a build-status strip still saying "pending" on a finished site. All three fixed in `b62fd2f`
(`fix(phase-7): make GitHub Pages usable for a first-time visitor`, pushed).
**Customer-reported UI defects fixed 2026-10-24 (`2342c83`, pushed `d9ccdca..2342c83`):** a dogfooding
visitor found the cart could not be undone (plain rows, `setQty` clamped at 1) and a size tap gave no
visible feedback (identical chips, state on a node `paint()` replaces). Cart lines now carry `+`/`−`/`Remove`
and the selected size is a filled chip plus check icon plus `aria-label`.
**Checkout restructured 2026-10-24 (`eab2481`, pushed `b92c7a4..eab2481`):** the same dogfooding visitor
then asked for the name above the cart and for one action button. `menu.html` now paints three sibling
blocks in order — menu, Full Name card, cart — `Proceed to Checkout` is itself the place-order action
(no second button, no armed flag, no `change` listener), and a blank name is refused client-side with a
visible line above the still-present field before any request is sent.
**Cart columns, name guard and footer credit fixed 2026-10-24 (`1696a96`, pushed `d80b3e6..1696a96`):** the
same visitor then reported four polish defects — cart amounts and `+`/`−` at a different x on every line
(`justify-between` spreads leftover space between items; a plain `auto` grid still sizes per row, so the amount
track needs `minmax(6.5rem, auto)` plus `justify-self: end`), the name field accepting `12312312`, the success
instruction left-aligned in the card, and no footer credit. All four fixed in `menu.html` + `assets/app.css`;
the server-side name CHECK was deliberately left as the looser backstop.
**R10 UX pass 2026-10-20 (`7916a0d` backend + `ce3b24e` frontend, still Phase 7 polish):** five more reported
defects, all fixed. The cart quantity moved BETWEEN the `+` and `−` (a dedicated centre track in the `.cart-line`
grid, so the steppers align on every line); the double-order glitch was a real race — `checkout()` cleared the cart
only after `await createOrder`, so a double tap fired two identical `create_order` calls and recorded two claims
— now closed by a synchronous `placing` flag plus a synchronous cart snapshot that is restored on a failed RPC;
the unpaid board is ordered by the **server** (`list_active_pending` sorts `lower(customer_name) ASC, created_at
DESC`, the client re-sort was removed) and capped to a `.board-scroll` viewport of about ten rows with the rest
reached by scrolling; and a looked-up claim now renders as a cart-like editable card — `claim_view` /
`set_claim_item_qty` / `add_claim_item` in `sql/02_functions.sql` (19 fns) plus `order_items_staff_write` and an
extended `orders_staff_update` fence in `sql/03_rls.sql` (11 policy pairs) — so a cashier can change a quantity,
drop a line, or add an item before Confirm Payment, with prices always derived from `menu_items` and an empty
claim refused as `LAST_LINE_ONLY` because an empty claim is a void. **Next up: Phase 8 (Vercel go-live),
parked until the phone run and a Vercel account/domain exist.** **Phase-8 prep done 2026-10-21** (compiled CSS committed + all five pages swapped; cron artifacts authored; `tools/inject-config.mjs` exercised 4/4 locally) - the Phase 8 gate is still open: the manual phone run, a Vercel account/domain, and live cron application remain. **Staff identity + login door built AND applied LIVE 2026-10-21 (human-authorized)** (`sql/07_staff_roster.sql`, the 17 fences folded into `sql/02_functions.sql`, `login.html`, the `assets/api.js` roster exports, `owner.html` Tab 5, `login.html` added to the Tailwind scan → `assets/tailwind.compiled.css` 12,252 B). The roster, the fences and 3 auth identities are LIVE (QA probes green both ways); the apply record is HANDOFF §11. **UI/UX sweep 2026-10-21 (ten human-reported items, HANDOFF §12):** all ten are file-complete and localhost-proven — login card no longer spills full-width, cashier shows the staff name plus a real Log out button and a 3 h idle teardown, the cart stepper is `− qty +`, the KDS dropped peso and went big-name/qty with a tiny code, `assets/realtime.js` now polls ALONGSIDE the socket as a backstop for a silently-dead ws, and the owner Sales tab gained a Focus dropdown (day / month / year) with a grain-following CSV. Two SQL fixes went LIVE the same day: `items_count` now counts CUPS (`SUM(quantity)`, four sites) and a new owner-gated `sales_report` answers one level finer than the grain handed in. **Nothing from the sweep is committed yet — the working tree is DIRTY and the ship needs the human's approval.**

Phases 2–5 are **strictly ordered** (customer before cashier before kitchen before owner) because each page depends on the previous page's DB side effects being real.

---

## 4. Configuration & Secrets Strategy

`assets/config.js` resolves in this priority order, so the same file works on both hosts:

1. `window.SL_CONFIG` (injected by `tools/inject-config.mjs` at Vercel build time)
2. `localStorage` override (`sl_config`) — Phase A bootstrap path, dev convenience
3. Committed defaults — **publishable key only**

```js
// assets/config.js  — committed, contains no secret
const _LS = (() => { try { return JSON.parse(localStorage.getItem('sl_config') || '{}'); } catch { return {}; } })();
export const CONFIG = {
  sbUrl: (window.SL_CONFIG?.sbUrl) || _LS?.sbUrl || 'https://epldhypmhpxkebtiidsc.supabase.co',
  sbKey: (window.SL_CONFIG?.sbKey) || _LS?.sbKey || 'sb_publishable_krQEeT-v7feHLYl01f8zsw_to9JjsAD',
  ownerEmails: ((window.SL_CONFIG?.ownerEmails || _LS?.ownerEmails || '').split(',')).filter(Boolean),
  ttlMinutes: 30,
};
```

**DEVIATION (2026-10-24, `b62fd2f`) — supersedes the `REPLACE_ME` example that was written here in Phase 0.**
The committed defaults are now the **real** project URL and publishable key. A Supabase publishable (client)
key is public by design — it is the value that ships in a browser — so committing it is not a secret leak; the
service-role key stays out of the repo and out of the browser entirely. Consequence: a first-time visitor to
GitHub Pages needs **no query params at all**, which is what made Gate A usable. The `?sburl=&sbkey=` bootstrap
still exists in `menu.html`/`cashier.html`/`kitchen.html`/`owner.html` and still writes `sl_config`, but it is now
an **optional override** (dev/testing, or a future project swap), not a requirement. Phase B replaces it with
`tools/inject-config.mjs` + env vars.

- **Phase A (GH Pages):** nothing required — the committed defaults boot the site. `?sburl=&sbkey=` remains
  available as an override; `?owneremails=` is still needed for the owner allowlist (no owner email is committed).
- **Phase B (Vercel):** `SL_SB_URL`, `SL_SB_KEY`, `SL_OWNER_EMAILS` are Vercel env vars; `inject-config.mjs` runs as the build command and writes `assets/config.generated.js`. Service-role key stays **out** of the browser entirely.
### 4a. Platform facts verified live (Phases 1–3) — read before touching transport or auth

- **RPC transport:** this project's API gateway exposes SQL functions **only** under `POST /rest/v1/rpc/<fn>`. Bare `/rest/v1/<fn>` resolves against tables/views and answers `PGRST205 "Could not find the table 'public.<fn>'"` even when PostgREST's schema cache reports the RPC as loaded. `api.js` `callSql()` therefore targets `/rest/v1/rpc/…`; table reads (`getRows`) keep the bare form. Do not "fix" this by reloading the schema cache — the path form is the cause.
- **Phase-A staff account:** the free project's built-in email sender is exhausted (`over_email_send_rate_limit`), so `POST /auth/v1/signup` only succeeds with **"Confirm email" toggled OFF** on the dashboard `Authentication → Sign In / Providers` page (autoconfirm). That toggle is currently OFF. The dev staff identity is `staff-probe@sleepless-cafe.test`; `cashier.html` persists `{email,password}` in `localStorage.sl_auth` — client-side password storage is an accepted **Phase-A tradeoff**, removed in Phase B.
- **`assets/ui.js` is not created** (deviation): each page ships its own inline UI, which keeps every sub-agent dispatch inside the 1–3 file budget in §3.

**Owner auth (Phase 5):** Supabase Auth PKCE (`signInWithPassword`/magic-redirect) → id_token handed to `api.js` → RLS grants owner writes only when a valid owner session is present. `CONFIG.ownerEmails` is an allowlist check, not the security boundary — RLS is.

---

## 5. Supabase Backend Contract (`sql/02_functions.sql`)

Every function below is the single entry point for a state transition; pages call them through `api.js`.

| Function | Called by | Effect |
|---|---|---|
| `create_order(name, items jsonb) → {code, order_id, total}` | menu | Inserts `orders` + `order_items`, generates unique 5-digit code (retry loop on UNIQUE violation), sets `expires_at = NOW()+30min` |
| `get_order_by_code(code) → order + items` | cashier | Exact lookup on `pending_payment` only. `null` means "wrong code **or** expired" — deliberately indistinguishable, because an expired row no longer exists to distinguish it from |
| `list_active_pending() → rows` | cashier | Calls `purge_expired_orders()` first, then returns `status='pending_payment'` |
| `purge_expired_orders() → int` | cashier, kitchen | **`DELETE`** where `status='pending_payment' AND expires_at < NOW()`. The only DELETE path in the codebase. Returns rows removed |
| `confirm_payment(code) → order` | cashier | Atomic guard: `UPDATE ... WHERE status='pending_payment' AND expires_at >= NOW()`. 0 rows updated → "this order's time is up, please place a new one" |
| `kitchen_queue() → rows` | kitchen | `status='paid'` ordered by `paid_at` asc |
| `mark_served(id) → {fulfillment_time_seconds}` | kitchen | `paid → served`, `served_at = NOW()`, computes delta |
| `void_order(id)` | owner (Tab 1 live-claims panel — see deviation 7) | Owner-initiated delete of an unpaid order — routes through the same DELETE path as the TTL. Fenced to `pending_payment`; no cashier button exists |
| `sales_summary(from, to, grain) → metrics` | owner tab 1 | Revenue, completed count, AOV |
| `turnover_stats(from, to) → metrics` | owner tab 2 | Avg fulfillment seconds, p95, peak-hour histogram |
| `create_category / reorder_categories / delete_category` | owner tab 4 | Menu grouping control |
| `create_menu_item / update_menu_item` | owner tab 3 | Uses Storage public URL for `image_url` |
| `staff_session() → {email, display_name, role, active, last_seen_at}` | login.html, cashier, kitchen, owner | The identity lookup every station page calls FIRST: reads the caller's claims email, finds the `staff_roster` row, refreshes `last_seen_at`. No session → `STAFF_SESSION_REQUIRED`; signed-in-but-unregistered → `STAFF_NOT_REGISTERED` |
| `roster_list() → rows` | owner Tab 5 | Owner-gated (`NOT_OWNER`). Every roster row ordered role then display_name |
| `roster_add(email, display_name, role, created_password)` | owner Tab 5 | Owner-gated. Inserts a row with `added_by` = the caller's own roster id; echoes the proposed password ONCE so the owner can copy it to the new employee — nothing is stored |
| `roster_suspend(id)` / `roster_reactivate(id)` | owner Tab 5 | Owner-gated `UPDATE active`. Suspend is the default lever: a suspended row stops answering `staff_session` |
| `roster_move_station(id, role)` | owner Tab 5 | Owner-gated `UPDATE role` (cashier ↔ kitchen, owner ↔ staff). Refuses demoting the last active owner — `LAST_OWNER_ONLY` |
| `roster_reset_password(id)` | owner Tab 5 | Owner-gated. Generates a memorable temp password and returns it ONCE; **applying** it to the GoTrue identity is the deferred service-role bundle (§9 item 12) |
| `make_memorable_password() → text` | login path, owner Tab 5 | The shared generator: word-word-Number, CSPRNG-backed, 20 cafe words. Tab 5 proposes the new employee's password before signup |

**RLS contract (`sql/03_rls.sql`)**
- `menu_items` + `categories`: public read, anonymous.
- `orders` / `order_items`: anonymous **insert** allowed (customer has no session), **update only via function**, read allowed to authenticated staff/owner.
- Menu/category writes: owner session required.
- `sql/04_realtime.sql`: whitelist **`INSERT` + `DELETE`** events on `orders`. `INSERT` feeds the cashier its new claims; **`DELETE` is what removes a row from the cashier table the instant it expires** — without it the cashier shows ghost rows for orders that no longer exist. Kitchen subscribes to `INSERT`/`UPDATE` only, since a paid order is never deleted.
- `sql/01_schema.sql` must carry `ON DELETE CASCADE` on the `order_items → orders` FK, so deleting an order cannot orphan its items. Verify this explicitly in the Phase 1 gate.
- Because paid rows are permanent, `orders` grows forever. Index `created_at`, `paid_at`, `served_at`, and `status` in `sql/01_schema.sql` so the owner's date-range queries stay cheap at 100k+ orders.

**Realtime transport (`assets/realtime.js`):** `supabase-js@2` via jsDelivr ESM in `<script type="module">`; WS subscribe on `orders`. If WS fails (network disconnect on a café tablet), fall back to 3s polling on `kitchen_queue()` — the UI must look identical either way.

Verified live (Phase 4, 2026-10-19): pinned to the only published release **2.118.0** (no 4.x exists on the CDN); `orders` added to the `supabase_realtime` publication (`alter publication supabase_realtime add table orders;`); the board dot reads **WS live** and a paid card appears with no reload.

---

## 6. UI Contract (all four pages inherit from `Sleepless.html`)

Reuse, do not reinvent: `brand.dark #140c08`, `brand.card #221610`, `brand.accent #d48d37`, `brand.accentLight #eec278`, `brand.cream #f8f1e5`, `brand.muted #a38f83`, `brand.border #3d271d`; Inter + Playfair Display; FontAwesome 6; glassmorphism panels; ₱ currency formatting.

**No cross-page navigation.** The four interfaces are independent sites. No POS page links to another POS page, and none links to `Sleepless.html`. Customers reach the system through `index.html` → `menu.html`; staff reach their page by direct URL/bookmark only, which keeps `cashier.html`/`kitchen.html`/`owner.html` unlisted and unguessable from the public customer page.

| Page | Layout target | Specific requirements |
|---|---|---|
| `menu.html` | Mobile-first, 390px primary | Category tabs top; picture cards (image, name, desc, **size chips where the selected one is visibly marked — filled chip + check icon + `aria-label`, never color alone**, ₱price, `+`/`−` stepper for the NEXT add, Add to Cart); cart drawer with itemized totals — **every cart line carries its own `+` / `−` / `Remove` controls and `−` at ×1 deletes the line**; the **Full Name field sits ABOVE the cart** (its own block, repainted independently of the menu) and **`Proceed to Checkout` is the single place-order action — it reads that field, refuses a blank name with a visible line above the field, and only then sends**; success screen shows code + name + 30-min instruction verbatim from spec — **the instruction paragraph is centered (`mx-auto` + `text-center`)**; **cart rows are a grid (`.cart-line`), not flex, with the amount flush at one x (`minmax(6.5rem, auto)` + `justify-self: end`) and the two stepper columns straight underneath**; the name guard is **letters-only (`/^\p{L}\p{L} '\-]*$/u`) with a two-letter minimum**, so digits and symbols never reach the counter; footer carries `© 2026 Sleepless Cafe · All rights reserved · Powered by CapFam, Ltd.` |
| `cashier.html` | Desktop/tablet, `max-w-7xl` | Big code-input field (typed or scanned), instant lookup; live unpaid table columns exactly: Code · Customer Name · Time Created · Time Remaining · No. of Items/Drinks · Total Amount; Confirm Payment button. Rows **vanish** at 30 min (Realtime `DELETE` or a re-purged poll — identical result). Under 2 min remaining the row turns red and reads **LAST CALL**, since the next click may already be past the deadline |
| `kitchen.html` | KDS: high contrast, large text, tap targets ≥ 48px | Cards sorted by `paid_at`; shows name + code + paid time + **live elapsed counter**; itemized list with sizes; Mark as Served button; card leaves view |
| `owner.html` | Tabbed admin | Tab1 Sales (daily/monthly/yearly + revenue/orders/AOV + export CSV) · Tab2 Turnover (avg fulfillment, peak-hour heatmap) · Tab3 Menu builder (image upload → Storage, dynamic size/price pairs) · Tab4 Category create/reorder/delete |

Shared error UX: network down, DB timeout, invalid code, expired order, duplicate name — each gets a distinct copy string, never a stack trace.

---

## 7. Deployment Gates

### Gate A — GitHub Pages (development)

**Status 2026-10-24: 13/14 ticked (staff-roster item ticked at the 2026-10-21 live apply — see HANDOFF §11).** The open item is the manual phone dogfood, which needs a real phone (a human). **Sweep 2026-10-21 adds two localhost-only items below (15/16 ticked); both are marked localhost-only, so the 13/14 public-host count above stands unchanged until the human authorizes the push and the public proof runs.** Everything else, including the fresh-visitor run on the public host with no query params
and `localStorage` cleared, is green — see HANDOFF §4 D2 for the audit and the 7/7 post-fix walkthrough.

- [x] Repo public, Pages enabled from `/` on `main` — `https://savage13317.github.io/sleepless-cafe-pos/` serves `index.html` (200, 11,072 B — post-fix size, was 10,735 B) from `main`
- [x] `index.html` is the customer entry only; no POS page links to another POS page or to `Sleepless.html` — link sweep in the phase-6 pass: the only cross-page link is `index.html:160 → menu.html`
- [x] Staff URLs (`cashier`/`kitchen`/`owner`) unlisted — direct link/bookmark only, `noindex` on all three — `grep noindex` hits `cashier.html:2`, `kitchen.html:2`, `owner.html:2`
- [x] `assets/tokens.css` is the only place **brand** colors are defined — audited 2026-10-24: no brand hex is re-declared in any page or in `assets/app.css`. Every hex hit is a documented non-brand exception (`app.css:14/56/72` gradient endpoints `#351f14`/`#b06f23`, each carrying a `/* not a brand token */` comment; `:93` LAST-CALL red `#ffd7d0`; `:95/97` `#c0392b`; `:108` `#ffffff` "max contrast, not brand cream"; `:129` `#ccc`; `menu.html:87/88` inline-SVG logo shape fills; `api.js:40` `#000000` neutral fallback). One unavoidable documented exception: `assets/favicon.svg` mirrors `#140c08`/`#d48d37`/`#f8f1e5` because a favicon is fetched as a standalone document and cannot read `var()` — stated in that file.
- [x] Supabase project created, `sql/01–05` applied, seed menu present — 12 seed items / 4 categories live
- [x] Config resolves `window.SL_CONFIG` → `localStorage.sl_config` → **committed public defaults** — `assets/config.js` now commits the real project URL + publishable key (`b62fd2f`), so a first-time visitor needs **no query params**; the `?sburl=&sbkey=` bootstrap (`menu.html:103–114`) survives as an optional override. Nothing secret is committed: the publishable key is public by design, the service-role key is absent from the repo and from the browser, and no owner email is committed. `.gitignore` covers `assets/config.generated.js` and `.env*` (staff credentials: the `?email=&password=` URL hack the station pages used is **superseded** by `login.html` — typed credentials + `sl_auth` handoff — this item stays ticked for config resolution only)
- [x] No dead request on load — audited 2026-10-24: with no icon declared, every page load requested `/favicon.ico` and GitHub Pages answered **404** (`grep favicon|rel="icon"` → 0 hits repo-wide). Added `assets/favicon.svg` (self-contained, 1,237 B, serves 200) and an identical `<link rel="icon" href="assets/favicon.svg" type="image/svg+xml">` on all five pages at lines 26–28
- [x] Public pages are honest — the build-status strip in `index.html` said `pending` on all five phases on a finished public site; now `live` ×5 with a note that the staff pages are reached by direct URL, not linked from the root
- [ ] End-to-end dogfood **on a phone**: place order → cashier confirms → kitchen serves → owner analytics shows it — **manual, needs a real phone**; the desktop-equivalent run on the public URL passed (HANDOFF §7)
- [x] TTL proven by deletion, not hiding: probe order `code='90001'` with `expires_at` 30 min in the past; the sweep deleted it — `SELECT` for that code → **no row**, `order_items` for that `order_id` → **0**. (Sweep ran with an owner JWT: `orders_staff_delete` is authenticated-only, so an anon sweep cannot delete — that is the RLS boundary, not a TTL bug.)
- [x] Permanence proven — 10 consecutive authenticated `list_active_pending` calls left all 4 served orders plus the live pending order intact, `order_items` unchanged (5), analytics unchanged
- [x] `Sleepless.html` untouched (governance: do not refactor unrelated files)
- [x] Staff roster live (applied 2026-10-21): sql/07 applied + 3 auth identities created + station blocking proven both ways (login.html door, WRONG_STATION/NOT_OWNER probes) — probes green at the RPC layer (cashier→`kitchen_queue` / kitchen→`list_active_pending` = `WRONG_STATION`, cashier→`create_menu_item` = `NOT_OWNER`, anon→`STAFF_NOT_REGISTERED`); the browser door PROVEN on the public host after the `da26aa4` push (login.html → cashier / kitchen / owner routings, Tab 5 renders 3 rows, stranger refused with honest copy)
- [x] Kitchen board self-heals without F5 — `assets/realtime.js` starts the 3 s poll ALONGSIDE the WebSocket (`startPolling(poll)` right after `mode = 'poll'` in `startWatching`), so a silently-dead socket (a throttled/backgrounded tab never fires `close`) can no longer freeze the KDS; a paid order appeared on the board with no reload — **verified on localhost only** (public-host proof pending the authorized push)
- [x] Owner Sales tab can focus one day / month / year (`<select data-sales-focus>`, options generated in UTC so an empty period is still selectable) and the CSV follows the selected grain — monthly exports per-day totals, yearly per-month totals, daily exports per-sale rows with `items` and `turnaround_seconds` — three downloaded CSVs verified — **verified on localhost only** (public-host proof pending the authorized push)

### Gate B — Vercel (production / operational)
- [ ] Gate A fully green
- [ ] `tools/inject-config.mjs` + env vars replace the query-param hack (exercised 4/4 locally 2026-10-21; not yet deployed  —  no Vercel project)
- [x] Tailwind CDN replaced by compiled CSS (no dev-only CDN in prod)  —  done 2026-10-21 repo-side: assets/tailwind.compiled.css committed, all five pages load it after app.css (CDN cascade order), 0 console messages on the local sweep; min-h-[48px] latent fix landed
- [ ] `noindex` guard removed from public customer page, retained on `owner.html`/`cashier.html`/`kitchen.html`
- [ ] Custom domain + HTTPS; `vercel.json` cache headers (HTML `max-age=0`, assets `max-age=31536000`)
- [ ] Supabase Cron → `purge_expired_orders()` scheduled (server-side TTL, not client-only)
- [ ] RLS re-audited: anonymous cannot read other customers' orders or write menu changes
- [ ] Storage bucket size limit + image re-encode on upload (café menu photos are large)
- [ ] Lighthouse mobile ≥ 90 on `menu.html`; KDS readable at 2m on a wall-mounted tablet
- [ ] One full service (5+ orders) run with real staff, then freeze

---

## 8. Hardware / Context Budget (RTX 3060 12GB · 32GB RAM, local runtimes)

- One sub-agent per phase, one phase per dispatch, 1–3 files each. No "rewrite the app" prompts.
- Specialists read only the files named in their phase + `MASTER_PLAN.md` §6. They do not re-read `Sleepless.html` in full (it is ~1000 lines) — the tokens are already extracted into `assets/tokens.css` in Phase 0.
- Supabase SQL is authored as files first, pasted into the Dashboard second. No headless browser automation on this box.
- Phase 6 QA is manual-checklist driven (`tests/api.spec.md`), not a CI farm.

---

## 9. Locked Decisions (owner confirmed 2026-10-18 — no further questions before Phase 0)

1. **Code alphabet:** **digits only, randomly generated**, 5 digits (`00000–99999`). `create_order()` draws with a CSPRNG (`crypto.randombytes`-equivalent in SQL) and retries on `UNIQUE` violation. Leading zeros allowed and must be preserved — the code is `VARCHAR(5)`, never cast to integer, and the cashier input field is a string. Spoken aloud by the cashier, so no letters.
2. **Owner authentication:** Supabase Auth password login with allowlisted emails. `CONFIG.ownerEmails` is an allowlist check only — **RLS is the security boundary**.
3. **Currency:** ₱ PHP, 2 decimals, thousands separator. One formatter in `assets/api.js` (`fmtPeso`), used by all four pages.
4. **Supabase project:** new, from scratch. `sql/01–05` applied in order, and **`sql/05_seed.sql` is required** so the dev build has a menu to render before the owner builds one.
5. **No links to existing HTML.** `Sleepless.html` is palette/type reference only. The four interfaces are independent sites; `staff.html` is not created and the dangling link at `Sleepless.html:237` is left as-is (out of scope, do not edit that file).
6. **Unpaid = deleted, paid = permanent.** An order unpaid past its 30-minute TTL is `DELETE`d from `orders` (children cascade). Once `confirm_payment()` succeeds the order is permanent and is never deleted or aged out. `status` enum narrows to `pending_payment · paid · preparing · served`; `expired` and `cancelled` do not exist as states. `purge_expired_orders()` is the only DELETE in the codebase.

7. **`void_order()` is owner-only, and now wired (resolved 2026-10-19: option A).** The function table above attributes `void_order` to the cashier, but `cashier.html` deliberately ships no void control (see the comment at `cashier.html:88`): a cashier tapping void would be a one-keystroke loss of a live claim, so cashier-side removal stays the TTL's job and voiding is an owner-dashboard decision. **Resolution:** `owner.html` Tab 1 (Sales) now renders the live unpaid claims from `list_active_pending()` and offers a per-row **Void claim** button with a two-step confirm (first tap arms the row, the button re-renders as "Confirm void", second tap executes; an arm older than 12 s is dropped). `void_order` remains fenced to `pending_payment` server-side, so a paid order cannot be reached from the dashboard. `api.js` keeps the `voidOrder` export and it is now actually called.

8. **Claim window is 30 minutes, and the DB owns it (owner decision 2026-10-20).** The window moved from 60 to 30 minutes. The single authority is the column default `sql/01_schema.sql:74` `expires_at timestamptz NOT NULL DEFAULT now() + interval '30 minutes'`; `assets/config.js` `ttlMinutes: 30` (line 31) is the client mirror and the two must always be changed as a pair, because RLS forbids the customer reading its own order back (`orders` has no anon SELECT policy, `get_order_by_code` is staff-only) so the copy on the success screen can only come from config. `menu.html` renders it through a `ttlMinutes()` helper, never a literal; `index.html` is a static landing page with no config bootstrap, so its two "30 minutes" strings are literals and are the documented drift risk. `cashier.html`/`kitchen.html`/`owner.html` need no edit - the countdown is server-derived (`seconds_remaining`), and the cashier LAST CALL threshold (120 s) is TTL-independent.

9. **`delete_category()` refuses, it does not corrupt (resolved 2026-10-20 during the full-system test).** `order_items.menu_item_id` carries no `ON DELETE` clause on purpose, because paid orders are the permanent sales record. Deleting a menu item still referenced by `order_items` would raise a raw FK violation (SQLSTATE 23503) and break the JSON-envelope contract, so the function counts referenced items BEFORE any DELETE and returns `{success:false,error:{code:"MENU_ITEM_IN_USE"}}`; a nested `BEGIN ... EXCEPTION WHEN SQLSTATE '23503' ... END` is the race safety net that rolls the partial DELETE back, so the category row is never dropped on a refusal. Categories whose items were never ordered still delete cleanly, and the fallback path (`UPDATE ... SET category_id`) cannot violate the FK.
10. **Server-side TTL cron (Phase 8)  —  PENDING OWNER APPROVAL, not yet locked.** The artifacts are committed (`functions/purge-expired/index.ts` + `tools/cron/purge-expired.json`, `*/15 * * * *`) and nothing is deployed. Two decisions need a human yes before this can be locked. **(a) Credential provisioning:** the Edge Function mints a REAL staff JWT (password grant) rather than using the service-role key, because `sql/03_rls.sql:141` `orders_staff_delete` is `FOR DELETE TO authenticated USING (status = 'pending_payment')`  —  a service-role sweep is denied by design, so the RLS boundary Gate A proved cannot be bypassed from the server side. That makes `SL_STAFF_EMAIL` / `SL_STAFF_PASSWORD` (plus `SL_SB_URL` / `SL_PUBLISHABLE_KEY`) Edge-Function secrets, and putting a staff password in an Edge-Function env is the credential decision that needs explicit approval; secrets are never committed and never leave Edge-Function env. **(b) Which staff identity the cron uses:** a dedicated cron staff account versus reusing `staff-gate`. Until both are answered the lazy client-side sweep in `list_active_pending` / `kitchen_queue` is the only TTL enforcement, and it stays the self-healing backstop either way.
11. **Staff roster is the server-side identity, and station is BLOCKED in SQL (owner confirmed 2026-10-21 through the interview — LOCKED).** `staff_roster` (`sql/07_staff_roster.sql`) is the identity source: role and station come from a roster row keyed on the caller's claims email, not from a browser allowlist — `CONFIG.ownerEmails` survives only as a harmless leftover. Allowed sets, enforced by the 10 `WRONG_STATION` fences in `sql/02_functions.sql`: **claim edits cashier-only**; **lookup / board / confirm cashier + owner**; **queue / serve kitchen + owner**; **void / menu / roster owner-only** (the 7 `NOT_OWNER` fences). Bootstrap identity `dev@sleepless-cafe.test` (owner) with the cashier and kitchen probes folded into the same file's seed rows. `login.html` is the staff door. **Suspend is the default lever** — no page deletes a roster row, and `added_by` is `ON DELETE RESTRICT`. Passwords are hashed by **GoTrue**; the roster stores none (`pw_note` is free text, never a secret). The memorable temp password (word-word-Number) is shown **ONCE**.
12. **Password change / reset applied to a GoTrue identity — PENDING OWNER APPROVAL, not yet locked.** Employee self-change and owner reset both **apply** a password to an auth identity, which is a **service-role** operation: impossible from SQL and from the publishable-key browser path, so the work is a deferred Edge-Function bundle — same approval class as item 10 (the cron). What is already live in SQL is only the generator (`make_memorable_password`), which Tab 5's add-employee flow calls and `roster_reset_password` returns once.

---

## 10. Definition of Done

The system is "perfect" (the gate for Vercel) when and only when:

1. a real customer on a phone can place an order that a real cashier pays and a real kitchen serves within 30 minutes;
   a real cashier and a real kitchen each sign in through `login.html` and can only run their own station (SQL refuses the other);
2. the order is invisible to every other customer;
3. the owner can see it in analytics and edit the menu that produced it;
4. an unpaid order past 30 minutes is **provably deleted** — `SELECT` on its code returns nothing in the Supabase Dashboard and its `order_items` cascade to zero, so it is absent from the cashier table, the kitchen queue, and every analytics number;
5. a paid order is **provably permanent** — it survives any number of TTL sweeps and remains in the sales record forever.

Everything else is polish.
