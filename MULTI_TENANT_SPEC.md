# MULTI-TENANT + TIER SPEC — Phase 9 (Sleepless Cafe POS)

**Status: design + files only. Nothing in this phase has been applied to the live project.**
Companion file: `sql/08_multitenant.sql` (schema + RLS + tier layer).
Read `HANDOFF.md` §1 first — the verified platform facts it lists are obeyed throughout, not re-derived.

Runtime facts this phase inherits: PostgreSQL **17.11** (repo targets 15-safe), Supabase project
`epldhypmhpxkebtiidsc`, static host is GitHub Pages (pushed tree, ~1–2 min rebuild), plan is **FREE**.

---

## §1 Multi-tenant database architecture

### 1.1 The store axis

One new table, one new column per existing table:

```
stores  ( id uuid PK · slug text UNIQUE · name · city · timezone · is_open · tier · created_at · updated_at )
   ↑ FK target
menu_items.store_id · categories.store_id · orders.store_id · staff_roster.store_id
```

Every `store_id` is `uuid NOT NULL DEFAULT '<legacy-store-uuid>' REFERENCES stores (id) ON DELETE RESTRICT`.

The **constant default** is the whole reason this phase can be applied without touching
`sql/02_functions.sql`: PostgreSQL fills existing rows with the literal, every current row
lands in the legacy store, and every existing function keeps inserting into the right branch
unchanged. Cross-store *routing* is a later phase; *isolation* is not.

`ON DELETE RESTRICT` (not CASCADE) mirrors `menu_items → categories` in `01_schema.sql`: a
branch that still holds orders cannot be deleted, so history can never be silently orphaned.

`order_items` deliberately gets **no** `store_id` column. An item's branch is its parent claim's
branch; a second column could drift out of agreement with the FK that already ties them
(`order_id → orders`, `ON DELETE CASCADE` — the Phase 1 gate). The policies derive the branch
from the parent instead.

### 1.2 Indexes (the hot paths, widened by one column)

| index | why |
|---|---|
| `orders_store_status_idx (store_id, status)` | every staff read narrows here |
| `orders_store_live_idx (store_id, expires_at) WHERE status='pending_payment'` | the TTL sweep; stays tiny as paid history grows |
| `menu_items_store_idx (store_id, is_available)` | the public menu read |
| `categories_store_idx (store_id, display_order)` | the menu builder |
| `staff_roster_store_idx (store_id, role, active)` | roster list per branch |

### 1.3 RLS contract — the headline change

`sql/03_rls.sql` today grants authenticated callers `USING ( true )`. That is correct for one
cafe and is a **cross-tenant leak** for many: any signed-in member of branch A can read and
mutate branch B. Every policy in `08_multitenant.sql` replaces `true` with:

```sql
jwt_store_id() IS NOT NULL AND store_id = jwt_store_id()
```

`jwt_store_id()` reads **no table**. That is deliberate: a policy expression that called a
helper reading `staff_roster` would recurse into `roster_authenticated_read` over the same
table. The store axis therefore travels **in the token**, and `staff_roster.store_id` stays the
authoritative server-side record that function bodies cross-check (mismatch ⇒ `STORE_MISMATCH`).

Two claim shapes are accepted, both grounded:

| claim | who carries it | how it gets there |
|---|---|---|
| `sid` (top level) | a short-lived customer token minted server-side | Edge Function (§4) |
| `user_metadata.sid` | a Supabase Auth staff identity | signup POST carries `{"data":{"sid":"<uuid>"}}` |

Roles that keep working unchanged: **anon holds no SELECT on `orders`** (a customer still cannot
see paid history or another customer's claim), **anon holds no policy at all on `staff_roster`**
(usernames stay unenumerable), and `DELETE`/`UPDATE` policies still require SELECT rights.

### 1.4 Two gotchas found while grounding this

1. **`code varchar(5)` carries a *global* `UNIQUE`** (`01_schema.sql`). With several branches,
   two stores cannot both hold claim `12345`, and the space is only 100,000. Fix is scoped
   uniqueness — a per-store index plus retiring the column-level constraint:
   ```sql
   -- look the generated name up first (it is not in the DDL):
   --   SELECT c->>'name' FROM orders.constraints AS c WHERE c->> 'type' = 'u';
   ALTER TABLE orders DROP CONSTRAINT orders_code_uniq;   -- confirm the real name before pasting
   CREATE UNIQUE INDEX orders_store_code_idx ON orders (store_id, code);
   ```
   Until that is done, the system still works — it just caps headroom and makes
   `get_order_by_code` ambiguous across branches. `get_order_by_code` and `confirm_payment`
   must both become store-scoped lookups when it is done.
2. **`ENUM` types are not used.** `CREATE TYPE ... ENUM` would match the request's wording, but
   the repo's existing style is `text + CHECK IN (...)` (`categories.name`, `orders.status`), and
   an enum makes later value additions an `ALTER TYPE ADD VALUES` recompile and breaks jsonb
   comparisons. Keeping `text + CHECK` preserves both the existing style and the realtime
   filter strings. Documented, not silently swapped.

---

## §2 Tier-based subscription model

### 2.1 The gating matrix

| capability | Tier 1 Starter | Tier 2 Pro | enforced where |
|---|---|---|---|
| menu / cashier / KDS pages | yes | yes | — |
| owner: availability toggle only | **yes** | yes | `starter_write_gate()` + `update_menu_item` body |
| owner: rename / reprice / image / add item | **no** | yes | `update_menu_item` / `create_menu_item` body |
| menu items per branch | **hard cap 25** | unlimited | policy `cap_allows(store_id)` **and** `create_menu_item` body |
| staff accounts (cashier/kitchen) | **no** | yes | `roster_add` body (`tier_gate`) |
| sales analytics (daily/monthly/yearly) | **no** | yes | `sales_summary` / `sales_report` body (`tier_gate`) |
| turnover metrics | **no** | yes | `turnover_stats` body (`tier_gate`) |
| tier flip by the owner's own browser | **no — never** | n/a | two pinned `stores` UPDATE policies |

### 2.2 Tier is not self-servable

PostgreSQL cannot compare "old tier vs new tier" in one expression, so the pin is **two policies,
one per tier value**: `USING` pins the row being edited, `WITH CHECK` pins the row being produced.
A tier change would have to satisfy `USING (tier='starter')` and `WITH CHECK (tier='pro')` at
once — no policy allows it. So authenticated may edit `name / city / is_open / timezone` forever
and may never change `tier`. The flip lives behind `TO service_role` policies, reachable only
from Edge Function / server tooling (the secret key is never shipped to a browser — `HANDOFF.md` §2).

### 2.3 The cap has two layers, and both are needed

* `cap_allows(store_id)` inside the `menu_items` write policy is the **hard backstop** — it holds
  even for a caller that bypasses the RPC (a hand-built `POST /rest/v1/menu_items`).
* `create_menu_item`'s body restates it so the refusal arrives as `MENU_LIMIT_REACHED` human
  copy. RLS alone cannot produce that copy.

The count lives in a **function** rather than inline in the policy because an unqualified
`store_id` inside a policy's subquery resolves to the *subquery's* alias (same ambiguity class as
the `email` local in `07_staff_roster.sql`) and silently becomes a tautology.

### 2.4 Frontend gating (cosmetic; never the boundary)

* `owner.html` renders the Sales Focus / analytics tabs only when `store.tier = 'pro'`; otherwise
  a locked tab with an upgrade banner. The tab is *hidden*, the RPC is *blocked* — §2.1–2.3.
* `menu.html` shows a "25 items — Starter" counter once the branch is near the cap.
* A Tier-1 owner who hand-builds the analytics POST gets `TIER_REQUIRED`, and the UI must map that
  code to the same upgrade copy it already shows.

---

## §3 Realtime per-store channels + order expiry

### 3.1 Isolation is already enforced — by RLS, not by the filter

Verified fact inherited from `HANDOFF.md` §1: **realtime delivery is RLS-gated**. A KDS page
subscribed to `orders` receives only the rows its role can actually read, so once
`orders_staff_read_store` exists, per-branch isolation needs **no client-side change at all**.

The optional bandwidth filter is a client optimization only, and its exact syntax must be
verified live before it is trusted:

```js
// assets/realtime.js — verify against a live two-store probe; do not assume
client.channel('orders', { filter: 'store_id=eq.<store-uuid>',
                            event: 'eq:orders.INSERT',
                            postgres_changes_options: { wait: true } })
```

`order_items` must **not** be subscribed (CASCADE flood) — unchanged from `04_realtime.sql`.
`orders` is already a member of the `supabase_realtime` publication (applied 2026-10-19); never
re-run the `alter publication` line as a "fix".

### 3.2 Expiry — the mechanism that already exists, per branch

`expires_at timestamptz NOT NULL DEFAULT now() + interval '30 minutes'` plus the partial index
`orders_store_live_idx (store_id, expires_at) WHERE status='pending_payment'` plus a **physical
DELETE** is the whole answer to "hide/purge unpaid orders older than 30 min without DB strain":

* the sweep is one indexed slice per branch, not a scan — `purge_expired_orders_store(uuid)`
  (new, in `08`) and `purge_expired_orders_all()` for the cron artifact;
* the DELETE cascades to `order_items` and is covered by `orders_staff_delete_store`
  (live unpaid claims only — a paid sale stays physically undeletable);
* the cron in `tools/cron/purge-expired.json` (`*/15 * * * *`) stays **unregistered** until a
  human authorizes it;
* **do not** add a `VIEW` that filters `expires_at > now()`. A view's read is subject to the
  *view's* own policies, not the underlying table's — a silent RLS bypass trap. The correct
  place for the freshness filter is the existing `list_active_pending()` body in `02`, which is
  already a plpgsql function running under the caller's role.

---

## §4 Routing & auth architecture

### 4.1 Static-host constraint (grounded, not assumed)

The live host is GitHub Pages, which serves the **pushed tree** — it has no router, so
`domain.com/menu/flagship` is not reachable today. Two shapes:

| shape | works on | how |
|---|---|---|
| `menu.html?store=<slug>` | **GitHub Pages now** | client-side resolution; QR encodes the full URL |
| `domain.com/menu/<slug>` | Vercel (Phase 8, **parked**) | rewrite to `menu.html?store=` |

Phase 9 therefore uses the query-param shape and keeps Phase 8 parked. The QR code per branch
encodes `https://…/menu.html?store=<slug>`.

### 4.2 Customer path (anon)

```
QR → menu.html?store=<slug>
     → resolve_store(slug)            anon-callable; returns {id, slug, name, tier, is_open}
     → store token with { role:'anon', sid:<uuid>, exp }   ← §4.3
     → menu_for_store(id) + categories_for_store(id)        ONE call each, cached per visit
     → create_order(...)                                    anon INSERT, store-scoped
```

* Resolution + caching: `localStorage.sl_store = { slug, id, tier, fetchedAt }`, TTL ~60 s.
  `menu_items` is **not** in the realtime publication, so cache invalidation is TTL-based, not
  event-based. A stale cache shows a stale menu for ≤60 s — acceptable, and stated.
* `resolve_store` answers `STORE_NOT_FOUND` for a closed branch with **no id**, so a closed
  branch cannot be probed for its catalogue.

### 4.3 The store token — the one thing that needs a human decision

Anon requests must now carry `sid`, and an anon request cannot be trusted to assert its own store.
Three options, honestly ranked:

| option | cost | verdict |
|---|---|---|
| **A. Edge Function mints a 5-min HS256 JWT** `{role:'anon', sid, exp}` | needs the project JWT signing secret in Edge-Function env (`SL_JWT_SECRET`) | **target**; free plan supports Edge Functions; the secret never enters the repo or a browser. Rotating it invalidates every live token. |
| **B. keep `03`'s broad anon read** | zero new secrets | **interim** — safe while there is exactly one branch (there is no other catalogue to leak); flip to A before branch #2 is opened to the public |
| **C. a real Auth identity per walk-in customer** | a password grant per visitor | rejected — creates accounts for customers |

Phase 9a/9b can ship with **B**; §1's anon store-scoped policies are marked **Phase 9c** in
`08_multitenant.sql` for exactly this reason — applying them before A exists makes every visitor
read an empty catalogue.

### 4.4 Staff path (authenticated)

```
login.html → Supabase password grant → JWT (user_metadata.sid)
           → staff_session() returns { email, display_name, role, store_id, tier }
           → role routes to cashier.html / kitchen.html / owner.html
           → store_id routes to that branch's dashboard
```

* Identity stays in `staff_roster` (GoTrue owns identities) — **no `users` table is created**.
  `staff_roster` is the identity source; `analytics_logs` stays commented-out in `08` because
  current analytics derive from `orders`.
* **Existing staff identities carry no `sid`** (the Phase 5/7 signups posted `{"data":{}}`).
  Roadmap Phase 9b re-issues them with `data:{sid}`. Until then the store-scoped authenticated
  policies deny the current staff — which is why §6 orders the policy swap *after* the re-issue.
* One identity = one branch. A multi-store owner gets one identity per branch (or a minted
  token per branch via service role) — no "switch store" button, because a JWT is a snapshot.

---

## §5 Feature gating + the `sql/02_functions.sql` delta

### 5.1 The key finding: **no signature change is required**

All 19 functions in `02_functions.sql` scope to a branch by reading `jwt_store_id()` **inside the
body**, not by taking a new parameter. That matters concretely: a signature-changing
`CREATE OR REPLACE FUNCTION` needs a preceding `DROP FUNCTION` (`42P13` cannot change the name of
an input parameter), and avoiding that dance keeps the RPC surface stable — the URLs in
`assets/api.js` do not change, and `PGRST205` routing surprises cannot appear.

The only new names are the two purge variants in `08` (`purge_expired_orders_store`,
`purge_expired_orders_all`), which are fresh names, not replacements.

### 5.2 Function delta (body edits only)

| function | change | why |
|---|---|---|
| `create_order` | `sid := jwt_store_id()`; write `store_id := sid`; validate every `menu_item_id` belongs to that store | the default would plant a second branch's order in the legacy store |
| `add_claim_item` | assert `menu_item.store_id = order.store_id` | **cross-store item injection** — a claim in branch A must not carry branch B's item |
| `get_order_by_code` | add `AND store_id = sid` | required once `code` becomes per-store unique |
| `confirm_payment` | same store-scoped lookup | ditto |
| `create_category` | `store_id := sid`; set `updated_at` | ditto |
| `reorder_categories` / `delete_category` | store-scoped WHERE | ditto |
| `create_menu_item` | `store_id := sid`; assert `category.store_id = sid`; `cap_allows` ⇒ `MENU_LIMIT_REACHED` | the cap's human copy |
| `update_menu_item` | `starter_write_gate(...)` ⇒ `TIER_REQUIRED`; set `updated_at` | Tier-1 owner = toggles only |
| `sales_summary` / `sales_report` / `turnover_stats` | `tier_gate(store, 'pro')` ⇒ `TIER_REQUIRED`; store-scoped WHERE | Tier 2 analytics |
| `list_active_pending` | add `expires_at > now()` | freshness filter (§3.2) |
| `claim_view` `kitchen_queue` `mark_served` `set_preparing` `void_order` `set_claim_item_qty` | **no change** | RLS already denies cross-store rows; the body never needs to know the branch |
| `staff_session` (07) | return `store_id` + `tier` | the frontend needs both to route and gate |
| `roster_add` (07) | `tier_gate(store,'pro')` for cashier/kitchen; `store_id := sid`; cross-check `roster.store_id = jwt_store_id()` | Tier-1 blocks staff accounts |

Every refusal keeps the repo's JSON envelope `{success, data, error}` with a machine code
(`TIER_REQUIRED`, `MENU_LIMIT_REACHED`, `STORE_MISMATCH`, `STORE_NOT_FOUND`) plus human copy —
the frontend maps codes, never copies.

---

## §6 Step-by-step roadmap (safe order — nothing breaks until it is provably replaced)

**Stop point honored:** 9a–9d are code/files + gated DB steps; the cron registration and the
Vercel move stay **parked** and are listed as gated, not performed.

| phase | action | gate before proceeding |
|---|---|---|
| **9a** | apply the **schema block only** (stores + seed + `store_id` columns + indexes + `stores` RLS). Existing policies are untouched, so the live app is unchanged | probe: existing `list_active_pending` and `menu` reads still return the same rows; `SELECT COUNT(1) FROM orders WHERE store_id = <legacy>` equals the old total |
| **9b** | re-issue staff identities with `data:{sid}` (signup with the same email/password, or admin API with service role — human-authorized, secret never in the repo) | `staff_session()` returns the expected `store_id` |
| **9c** | swap the policies: drop `03`'s `USING (true)` set, install `08`'s store-scoped set; **and** ship the customer store token (option A) — these two go together or the app breaks | REST probes §5.3 below, all four |
| **9d** | apply the function delta (§5.1 — body edits, no `DROP FUNCTION`); add `08`'s purge variants | call-test each RPC over `/rest/v1/rpc/<fn>`; confirm no `PGRST205` |
| **9e** | frontend: `?store=<slug>` resolution + per-visit menu cache; `staff_session()` drives role **and** store routing; tier-locked tabs + upgrade banners | browser pass on the pushed tree (Pages serves the pushed tree, ~1–2 min rebuild) |
| **9f** | *(gated, not done)* register the cron against `purge_expired_orders_all`; move to Vercel for path-style routing | human approval; both are already parked artifacts |

### Verification checklist (probes, not Editor results)

The SQL Editor runs as root and **bypasses RLS** — never use an Editor result as evidence.
Probe over REST with `curl.exe` (it prints bodies; `Invoke-WebRequest` hides them), writing any
JSON body to a file and using `--data-binary "@file.json"`.

1. **anon cross-store** — publishable key + token for store A, `GET /rest/v1/menu_items`:
   expect store A's available items only; expect **zero rows** with a bare publishable key.
2. **authenticated cross-store** — store A's staff token, `GET /rest/v1/orders`:
   expect store A's claims; then `POST /rest/v1/rpc/mark_served` with a store B order id ⇒
   denied (empty/`0` rows), not a silent success.
3. **tier gate** — Tier-1 owner token, `POST /rest/v1/rpc/sales_report`:
   expect `{success:false, error.code:"TIER_REQUIRED"}`; then a hand-built
   `POST /rest/v1/menu_items` past item 25 ⇒ refused by the policy, not the function.
4. **tier flip** — Tier-1 owner token, `PATCH /rest/v1/stores` with `{"tier":"pro"}` ⇒ refused.
5. **realtime** — two branches, one KDS page each: each page receives only its own
   `orders.INSERT`, and the page still does **not** reload (the Phase 6 no-reload proof must
   survive the policy swap).
6. **cap headroom** — confirm the `code` constraint name before dropping it (§1.4).

### What this phase does NOT do

* applies nothing to the live DB, registers no cron, moves no host;
* creates no `users` table and no `analytics_logs` (both documented as optional);
* does not use `ENUM` types (§1.4) and does not add a `VIEW` for freshness (§3.2);
* does not touch `assets/api.js`, `assets/config.js`, or the four pages — those are Phase 9e;
* does not put any secret (service-role key, JWT signing secret, staff passwords) in the repo,
  a browser, or a model prompt.
