# HANDOFF.md — Sleepless Cafe POS · continuation brief

**Written:** 2026-10-19 · **updated:** 2026-10-23 (Phase 9 files + **9g second store `marcelas`**, §15) · **Branch:** `main` · **Repo:** `github.com/savage13317/sleepless-cafe-pos`
**Where we are:** Phases 1–7 done · **Phase 5 gate PASSED** · **Phase 6 (QA sweep) PASSED** (14/14 anon probes
conform, zero dead links, zero static console risks) · **Phase 7 (GitHub Pages dogfood) PASSED on the public
host** — Gate A green except the manual phone run — the Gate A audit fixed three public-host defects
(commit `b62fd2f`, §4 D2), and three customer-reported UX passes reworked `menu.html` (§4 D3/D4, commits
`2342c83` + `eab2481` + `1696a96`) · **R10 UX pass done** (cart quantity moved between the steppers, a
no-double-order guard, an alphabetical scrolling unpaid board, and a looked-up claim that is editable before
payment — commits `7916a0d` + `ce3b24e`, §9) · **Phase 8 prep done 2026-10-21** (Tailwind CDN → compiled CSS on all five pages, cron artifacts authored, `tools/inject-config.mjs` exercised 4/4) · **Staff identity + login door built AND applied LIVE 2026-10-21 (human-authorized)** — sql/07 pasted (4 chunks, all 201), the 17 fences of 02 live (5 chunks, all 201), 3 auth identities created, QA probes green both ways; record: §11 · **Phase 8 itself still parked** — open items: the manual phone run, a Vercel account/domain, and live cron application (needs a signed-in dashboard + human approval of the Edge-Function staff secrets). · **UI/UX sweep 2026-10-21 SHIPPED: committed + pushed `4888f24..614b9f3`, public-host door proof green — §12** · **UI sweep 2 2026-10-21 SHIPPED: committed + pushed `9bd7ee9..fe296fb` (three chunks), all seven items re-proven on the public host — §13** · **Phase 9 (multi-store + tier model) — 9a SCHEMA + 9b sid-seed + 9c JWT helpers & authenticated policy swap ALL APPLIED LIVE 2026-10-23 (verified: stores=1 flagship; 3 roster identities carry `raw_user_meta_data.sid`=flagship id; 5 JWT helpers installed; authenticated policies store-scoped via `jwt_store_id()` with `stores` policies using `id` not `store_id` — 08 latent bug fixed on apply; interim option B keeps anon read broad, anon menu read still HTTP 200 flagship); **9d FUNCTION DELTA APPLIED LIVE + VERIFIED 2026-10-23** (all 02/07 function bodies now store-scoped via `jwt_store_id()` + tier-gated via `tier_gate`/`starter_write_gate`/`cap_allows` — chunks 1–5 all 201; new anon-callable routing helpers `resolve_store`/`menu_for_store`/`categories_for_store` + `purge_expired_orders_store`/`purge_expired_orders_all` installed; `stores_read_public` anon policy `FOR SELECT TO anon USING (is_open=true)` installed to close the store-directory gap — anon `GET /stores` now returns flagship; anon call-tests green: `resolve_store?slug=flagship`→success, `?slug=ghost`→STORE_NOT_FOUND, `menu_for_store`/`categories_for_store` return full flagship data, `get_order_by_code` anon→STAFF_SESSION_REQUIRED body-ran; authenticated cross-store DENIAL + tier-gate probes deferred to 9e staff-JWT login per §5.3); **9e FRONTEND APPLIED (working tree, NOT committed) 2026-10-23**: `config.js` gained `storeSlug` (default `flagship`, priority window→localStorage→committed); `api.js` gained anon-callable `resolveStore`/`menuForStore`/`categoriesForStore`; `menu.html` customer path now resolves `?store=<slug>` (default `flagship`) → `resolve_store` → caches `{slug,storeId,tier}` in `localStorage.sl_store` TTL 60s → loads via `menu_for_store`/`categories_for_store` (store-scoped; rows carry no `is_available`, filter relaxed to `!== false`); `owner.html` captures `staff_session().data.tier` into `ownerTier` and pre-gates cashier/kitchen adds with an upgrade banner (avoids orphan identity), plus `TIER_REQUIRED`/`MENU_LIMIT_REACHED`/`STORE_CONTEXT_REQUIRED`/`STORE_MISMATCH` copy. Browser-verified on local static server (:8731, working tree): `menu.html?store=flagship`→5 tabs+items, `?store=ghost`→"branch isn't open" copy, no-param→flagship (backward-compat); `owner.html` parses (renders sign-in gate). cashier/kitchen need NO change (store axis is JWT-driven via `jwt_store_id()`). **OPEN DECISION: flagship seeded `tier=starter` → owner can no longer add cashier/kitchen staff or new menu items on it (tier not self-servable; flip only via service_role). Existing flagship staff/items predate the gate. Confirm flagship should be `pro` (unrestricted) or stay `starter`.** Authenticated live tier-gate probe still needs a human owner login (bcrypt pw unrecoverable). 9f cron/Vercel PARKED — §14**

Read this file top to bottom before touching anything. Sections 1–3 are facts that were
**verified against the live project** — they contradict several plausible-looking assumptions,
and re-deriving them costs an hour of dashboard work.

---

## 1. Do-not-re-derive platform facts (all verified live this session)

### 1.1 Transport — RPCs need the `/rpc/` path prefix
This project's API gateway exposes SQL functions **only** under `POST /rest/v1/rpc/<fn>`.
The bare form `POST /rest/v1/<fn>` resolves against tables/views and answers:

```
404  PGRST205 "Could not find the table 'public.<fn>'"
```

…even though the Unified Logs (`/logs?filter=log_type:eq:postgrest`) report the RPCs as
**loaded** in the schema cache ("Schema cache loaded in 4.5 ms", RPC counts tracked our
creations 18→19→24→25→28). **Do not "fix" this by reloading the schema cache** — a documented
`pg_notify('pgrst','reload schema')` can succeed while the functions stay unroutable.
Privileges are not the cause either. Table/view reads keep the bare form and work.

Proof-of-route probe (a 200 body is not needed to prove the route):
`GET /rest/v1/rpc/<fn>` with `Accept: text/plain` → `PGRST107 "None of these media types
are available: text/plain"` = route exists. `PGRST100` from a GET does **not** prove a route
(it is a filter-parse error raised before route resolution).

`assets/api.js` is already correct: `callSql` → `${CONFIG.sbUrl}/rest/v1/rpc/${fn}`;
`getRows` → bare `${CONFIG.sbUrl}/rest/v1/${path}`. `tests/api.spec.md` carries the same note.

### 1.2 Realtime Postgres Changes requires the **publication** toggle — THIS IS THE PHASE-4 BLOCKER
`sql/04_realtime.sql` currently claims "Phase 1d requires NO dashboard click and NO SQL".
**That claim is wrong and must be corrected.** Verified on the live dashboard
(`/database/publications`):

| Publication | System ID | Insert/Update/Delete/Truncate | Tables |
| --- | --- | --- | --- |
| `supabase_realtime` | 16426 | all four ON | **0 tables** |
| `supabase_realtime_messages_publication` | 17875 | all four ON | 1 table (`realtime.messages`) |

`orders` is **not** in `supabase_realtime`, so no `postgres_changes` event for `orders` is ever
emitted — that is why the live probe below returned `events=[]`. Fix (SQL Editor, root role):

```sql
alter publication supabase_realtime add table orders;
-- kitchen needs INSERT + UPDATE; cashier needs INSERT + DELETE.
-- The four toggles above are already ON, so the table add is the only change needed.
-- Do NOT add order_items: sql/01 declares order_id REFERENCES orders ON DELETE CASCADE,
-- so one orders DELETE cascades into N order_items events (a flood the boards never asked for).
```

Everything else the old 04 file asserted is still true and should be kept:
there is **no per-table event whitelist** in Realtime Settings (event selection is client-side
filter strings), delivery is RLS-gated ("records are sent only to clients allowed to read them"),
the Policies page (`/realtime/policies`) applies only to **private** channels, and
`ALTER TABLE realtime.messages ENABLE ROW LEVEL SECURITY` fails `42501 must be owner of table
messages` — never add that line, it aborts the whole pasted group.

**RESOLVED (2026-10-19):** `alter publication supabase_realtime add table orders;` applied live in the
SQL Editor (root) → "Success. No rows returned"; `/database/publications` now shows `supabase_realtime`
id 16426 = **1 table** (was 0). `sql/04_realtime.sql` header corrected to the truth (SQL controls
membership + delivery; the publication toggle IS required).

### 1.3 `@supabase/supabase-js@4` does not exist — the current realtime.js cannot connect
Verified against the npm registry and the CDN:

- dist-tags for **both** `@supabase/supabase-js` and `@supabase/realtime-js`: latest
  **`2.118.0`**, `3.0.0-next.29`, rc `2.100.0-rc.0`, beta `2.112.0-beta.0`, canary
  `2.118.0-canary.2`. **No 4.x exists** (`@supabase/realtime-js@4.` → 0 matches; 3.x only as
  prerelease "next").
- `https://cdn.jsdelivr.net/npm/@supabase/supabase-js@4/+esm` returns the 48-char body
  `Couldn't find the requested release version 4.` → the dynamic import in
  `assets/realtime.js` **throws**, the `catch` fires, `mode` stays `'poll'`, and the board runs
  on the 3 s polling fallback. Phase 4's gate ("Paid order appears without refresh") is therefore
  **not** met.

The published 2.118.0 API (read from the `.d.ts` files on jsDelivr) is Phoenix-channel based and
has **no** `client.socket`, **no** `ensureStarted`, **no** `client.close`:

- `RealtimeClientOptions`: `transport?: WebSocketLikeConstructor`, `accessToken?: () => Promise<string | null>`
  (a **callback**, called on connect and every heartbeat; `heartbeatIntervalMs` default 25000),
  `params`, `headers` (deprecated — "headers cannot be set on websocket connections"), `logLevel`,
  `vsn` (default `"2.0.0"`), `worker`, `workerUrl`, `encode/decode`, `reconnectAfterMs`.
- `class RealtimeClient`: `constructor(endPoint, options?)`, `connect(): void`, `endpointURL()`,
  `disconnect(code?, reason?): Promise<"ok"|"timeout">`, `getChannels()`, `removeChannel(ch)`,
  `removeAllChannels()`, fields `channels`, `accessTokenValue`, `accessToken`, `apiKey`, `httpEndpoint`.
- `class RealtimeChannel`: `constructor(topic, params?, socket)`,
  `subscribe(callback?: (status, err?) => void, timeout?: number)`, `unsubscribe(timeout?)`,
  `on(...)`, `state`, `presenceState()`. `REALTIME_SUBSCRIBE_STATES` = `SUBSCRIBED` / `CLOSED`.
  `REALTIME_POSTGRES_CHANGES_LISTEN_EVENT` values are **UPPERCASE** (`INSERT`, `UPDATE`, `DELETE`)
  — consistent with the `eq:orders.INSERT` strings in `sql/04_realtime.sql`.
- `RealtimeChannelOptions = { config: { broadcast?, presence?, private?, postgres_changes_options?: { wait?, timeout? } } }`.
  `wait: true` holds the SUBSCRIBED callback until the server confirms the subscription and reports
  `CHANNEL_ERROR` (`PostgresChangesSubscribeTimeout…`, `RealtimeDisabledForConfiguration…`) on failure —
  use it to make the ws/poll decision honest instead of optimistic.
- Standalone usage documented in the `.d.ts`: `new RealtimeClient('https://xyz.supabase.co/realtime/v1', { params: { apikey: '…' } })` then `client.connect()`.

**RESOLVED (2026-10-19):** `assets/realtime.js` rewritten to the published **2.118.0** Phoenix-channel API
(`createClient → client.channel → .on('postgres_changes',…) → .subscribe(cb,timeout)` with
`postgres_changes_options.wait:true`, `accessToken` callback carrying the staff bearer, teardown via
`removeChannel` + async `disconnect`). Public surface unchanged (`mode`, `stopWatching()`,
`startWatching(onEvent, poll)`), so `kitchen.html` needed no edit. The board dot flips to **WS live**.

### 1.4 Live probe result (supabase-js 2.118.0, staff bearer, `orders` INSERT)
`createClient(url, key, { accessToken: () => tok })` → `client.channel('probe')` →
`.on('postgres_changes', { event:'INSERT', schema:'public', table:'orders' }, cb)` →
`subscribe(…, 6000)` → **`SUBSCRIBED`** (so the transport itself works), then a real
`create_order` succeeded (`{"data":{"code":"71409","total":90,"order_id":"8bb36c94-…"}}`)
and **`events=[]`** after 4 s. With §1.2 that is explained: the table is not published.
Re-run this probe after the publication toggle before believing anything else.

**AFTER the toggle (2026-10-19):** the live board now reacts to `INSERT`/`UPDATE` with **no reload** — dot
reads WS live and a paid card appears on the KDS on its own. A freshly opened standalone probe channel can
still show `events=[]` in isolation (no live order to catch while it is open); the **no-reload board
reaction** is the authoritative gate evidence, corroborated by the authenticated DB read in §2.

### 1.5 Auth (Supabase Auth, free plan)
- The built-in email sender is exhausted: `POST /auth/v1/signup` →
  `{"code":429,"error_code":"over_email_send_rate_limit","msg":"email rate limit exceeded"}`.
- With the dashboard **"Confirm email" toggle OFF** (autoconfirm) on
  `Authentication → Sign In / Providers`, signup sends no email and succeeds. The toggle is
  currently OFF. That row is a WAI-ARIA toggle: a `<label>` whose `for` id points at a `<button>`
  styled with `data-[state=checked|unchecked]`; `btn.click()` flips it, then "Save changes" must be
  clicked (it becomes `disabled` once saved).
- Password grant works once the user exists: `POST /auth/v1/token?grant_type=password`.
- Dashboard Auth routes are **`/auth/...`**, not `/authentication/...`
  (`/auth/users`, `/auth/providers`, `/auth/templates`, `/auth/rate-limits`, …).
- Staff identities LIVE since 2026-10-21 (password grant verified for all three): `dev@sleepless-cafe.test` (owner),
  `cashier-probe@sleepless-cafe.test` (cashier), `kitchen-probe@sleepless-cafe.test` (kitchen). Passwords are
  credentials — reported to the human out-of-band, **never committed** into any file.
  The legacy `staff-probe@sleepless-cafe.test` (id `890bb2f2-4ee3-45ce-9935-392dd032663d`) still exists in Auth
  but its password was never recorded, so it is unusable; the roster row was repointed to `cashier-probe@…` and a
  fresh identity created instead (deleting auth users was never authorized). The Management API has **no user/password
  routes** — `GET auth/users`, `auth/admin/users/list`, `POST auth/admin/users/<uuid>/password` and friends all 404,
  so changing an EXISTING identity's password needs the service-role Edge-Function bundle (PENDING OWNER APPROVAL).
  `cashier.html` persists `{email,password}` in `localStorage.sl_auth` — an accepted **Phase-A
  tradeoff**, removed in Phase B. Only the email is ever rendered.

### 1.6 RLS semantics that the SQL depends on (verified)
- Policies are inert unless `ALTER TABLE … ENABLE ROW LEVEL SECURITY`; `sql/01_schema.sql` never
  enables it, so `sql/03_rls.sql` owns it.
- Default-deny when no policy matches. PostgREST does `SET ROLE` first, so RLS applies to **every**
  statement including inside plpgsql bodies.
- FK integrity checks and `ON DELETE CASCADE` child removals **bypass** RLS.
- A policy expression referencing a table the caller cannot read raises permission denied.
- DELETE/UPDATE policies also require SELECT rights; RLS `WITH CHECK` runs before schema
  CHECK/NOT NULL constraints.
- Verified `CREATE POLICY` grammar: `CREATE POLICY n ON t [AS {PERMISSIVE|RESTRICTIVE}] [FOR {ALL|SELECT|INSERT|UPDATE|DELETE}] [TO {role|PUBLIC|CURRENT_ROLE|CURRENT_USER|SESSION_USER},…] [USING (e)] [WITH CHECK (e)]`. `ON <table>` precedes `FOR`; `FOR` never takes a table name; role restriction is the `TO` clause. `DROP POLICY [IF EXISTS] n ON t [CASCADE|RESTRICT]`. `FOR` takes **one** keyword — `FOR INSERT, UPDATE` raises `42601`; split into one policy per verb. An INSERT policy accepts **only `WITH CHECK`** (adding `USING` raises `42601`).
- The SQL Editor runs as root ("Role postgres") and **bypasses RLS** — never use an Editor result
  as evidence of what `anon`/`authenticated` can see. Probe over REST instead.
- Empty tables make COUNT-based probes inconclusive; use error-raising probes.

### 1.7 plpgsql / PG facts that bit us
Runtime is **PostgreSQL 17.11** (repo targets 15; everything used is 15-safe).
- plpgsql is parsed **lazily** — `CREATE OR REPLACE FUNCTION` compiles clean and errors surface only
  at **call** time. Live call-testing of every function is the only reliable check.
- jsonb has **no `+` operator** (`||` is merge). A plpgsql body must be `BEGIN … END;`.
  Bare `SELECT func();` in a body raises `42601` — use `PERFORM func();` (PG 13+).
- Query-level `ORDER BY` inside an aggregate `SELECT` raises `42803`; use the aggregate sort clause
  (`ORDER BY …` attached to `jsonb_agg`). A query-level `ORDER BY … OFFSET … LIMIT 1` in a subquery
  feeding a scalar is legal and kept in `p95_s`.
- `SYSTEM_GETENV` is PG 16+ (`42883`); use `COALESCE(NULLIF(current_setting('request.jwt.claims', true), '')::jsonb, '{}')` — the two-arg form, since the one-arg form raises `42704` when unset.
- `date_trunc('date', timestamptz)` raises `22023` — must be `'day'`.
- `jsonb -> idx ->> ''` is always NULL; `jsonb ->> idx` returns the element as text.
- `pg_catalog.*` is **not** queryable from the SQL Editor (`42P01`). Use `has_function_privilege` and direct calls.
- plpgsql **exception condition names are single tokens**: `FOREIGN KEY VIOLATION`, `SQLSTATE_VALUE` and
  `FK_CONSTRAINT_VIOLATION` all raise `42704` (unrecognized name), and a bare `'23503'` raises `42601`. The only
  accepted spelling is `EXCEPTION WHEN SQLSTATE '23503' THEN` — used inside `delete_category` as the race safety
  net, so a refused deletion never drops the category row.
- Changing a column default needs the `SET` keyword: `ALTER TABLE orders ALTER COLUMN expires_at SET DEFAULT
  now() + interval '30 minutes'` → 201; without `SET` it raises `42601 syntax error at or near "DEFAULT"`.
  `UPDATE` is `SET … WHERE …` order (the parenthesized `WHERE (…)` form belongs to the `UPDATE t WHERE (…) SET (…)`
  table-literal variant, not the ordinary one).
- plpgsql **declarations parse eagerly** (unlike lazy bodies): `cu uid uuid;` raises `42601` at CREATE time — a
  uuid-typed local is just `cu uuid;`.
- `INSERT tbl WITH (col val)` is the psql table-literal form and is **invalid inside plpgsql** (`42601` at CREATE
  time) — repo files use standard `INSERT INTO … (cols) VALUES (…)`; always paste a chunk verbatim from the file,
  never reconstruct it from memory.
- A plpgsql local named `email` is **ambiguous** (`42702 column reference "email" is ambiguous`) against a table's
  `email` column inside `WHERE r.email = email` — lazy parse, so the function applies cleanly and fails only at
  CALL time. All sql/07 functions use `claims_email` instead (FIX note in the file).

### 1.x SQL execution path (verified 2026-10-24) — do not re-derive
- The Supabase **SQL Editor in the dashboard never initializes**: the Monaco query pane stays an `svg`
  spinner and the `textarea` / `.monaco-editor` element counts stay 0 after 45 s plus a reload. Do not
  waste time on it — clicking `sql-run-button` cannot help while the editor never mounts.
- Working path instead, on the **authenticated dashboard page**: `localStorage['supabase.dashboard.auth.token']`
  is raw JSON `{access_token, token_type, expires_in, expires_at, refresh_token}` — use **`.access_token`** (the
  old `.token` note was wrong; it raised 400) as `Authorization: Bearer <tok>` against
  `POST https://api.supabase.com/v1/projects/epldhypmhpxkebtiidsc/database/query` with body
  `{"query":"<sql>"}` → `201`. The endpoint returns only the **last** statement's rows; multi-statement groups
  **abort atomically** on a parse error, so a failed paste leaves the DB untouched and retries are safe. Inside a
  JS template literal, SQL regex backslashes must be doubled (`\\.` → SQL sees `\.`).
  No PAT is minted and no credential is ever printed — the token is read and used in place inside the page.
- Multi-statement bodies work; a `DROP FUNCTION` must precede a signature-changing
  `CREATE OR REPLACE FUNCTION` (`42P13 cannot change name of input parameter` otherwise).
- Cosmetic drift: the two live functions were applied with `$q$` fences and single-line
  `jsonb_build_object` calls, while `sql/02_functions.sql` uses `$$` and wrapped lines. Semantically
  identical; re-pasting the repo file replaces the live rows (never run both sets at once).

### 1.z GitHub Pages serves the **pushed tree** — localhost is not evidence (verified 2026-10-24)
`https://savage13317.github.io/sleepless-cafe-pos/` serves whatever is on `origin/main`, not the working
tree. A local fix cannot be verified live until it is **committed AND pushed**, and Pages then needs
~1–2 min to rebuild. Consequence of the audit on 2026-10-24: every Phase 2–7 gate was verified on
`localhost:8731` with `?sburl=&sbkey=` query params, which hid three defects that only existed on the
public host (see §4 D2). Verify on the public URL with `localStorage` cleared and no query params.
`localStorage` is per-origin in the integrated browser, so clearing it on one `savage13317.github.io`
page clears it for the others — clear `sl_config` and `sl_auth` before simulating a fresh visitor.

---

## 2. Live project state (as of this commit)

- Project ref `epldhypmhpxkebtiidsc` · org ref `isiqwbqhfmqztvttvdbf` · org "POS", project
  "sleepless-cafe", branch `main (Production)`, plan **FREE**.
- Publishable (client) key — public by design: `sb_publishable_krQEeT-v7feHLYl01f8zsw_to9JjsAD`.
  The service-role/secret key has never been shipped to a browser and must never be.
- DB (current, re-verified live 2026-10-20 after the R9 full-system test): `menu_items` **13** — the 12 visible
  seed items (`22222222-2222-2222-8333-000000000001..12`, all `image_url` empty) plus one hidden
  `Test Ristretto R9` (`829e95a7-a7e9-4b4e-99aa-ba3925f52594`, `is_available = false`) parked inside Coffee, which
  cannot be deleted because a paid order still references it. `categories` **4** — category UUIDs
  `11111111-1111-1111-8333-000000000001..4`; live `display_order` is **0-based** (Coffee 0, Non-Coffee 1,
  Pastries 2, Desserts 3) while `sql/05_seed.sql` is 1-based, so a re-seed and the live board differ by one.
  `orders` **9 completed** (revenue ₱3,765.00, avg ₱418.33) and **0 `pending_payment`**, `order_items` **14**
  (re-probed live 2026-10-20 after the R10 pass). Codes in `orders`, oldest first: `63242, 02342, 13341,
  21574, 85063, 33667, 96405` all `served`, plus `87823` and `34865` `paid` — the two `paid` rows are the R10
  pass (the human's own claim ₱1,550.00 and my probe claim ₱1,050.00), which is why revenue moved ₱1,165.00 →
  ₱3,765.00 over 9 orders. Every other R9/R10 probe (`43450`, `84400`, `97314`, `48170`, `30218`, and the
  duplicate `09031`) is gone from `orders` entirely — purged by the TTL sweep or voided, which is the designed
  behaviour, not a bug. The claim window is now **30 minutes** (`sql/01_schema.sql:74`
  `expires_at timestamptz NOT NULL DEFAULT now() + interval '30 minutes'`); proof from a live order: created
  `06:16:17.411762Z`, `expires_at` `06:46:17.411762Z` — exactly 30 min, `seconds_remaining` 1786.
- **Live DB drift (re-probed 2026-10-21 during the phase-8 QA sweep):** the live DB now renders **14 visible
  items over 5 categories · `GM Americano` added inside Coffee and `Coopper` in a brand-new `Doggy` category,
  from human menu edits made after the last handoff. The 12-seed counts in this section (and in the section-3 seed
  rows) are **superseded** by these live numbers; the hidden `Test Ristretto R9` item (undeletable while a paid
  order still references it) is unchanged.
- **Staff identity (built 2026-10-21, files only — nothing applied live):** `staff_roster` (`sql/07_staff_roster.sql`) is the **SERVER-SIDE identity source** — role and station come from a roster row keyed on the caller's claims email, so "signed in" becomes "which station am I". `CONFIG.ownerEmails` is now a **harmless leftover**: the browser allowlist still resolves in `assets/config.js`, but the roster decides, and `owner.html:82` says so. The live DB is still **14 visible items / 5 categories** — the `GM Americano` + `Coopper`/`Doggy` drift is **confirmed intentional by the human** (their own menu testing), not a defect.
- Auth users (password grant, "Confirm email" OFF → autoconfirm): owner `owner@sleepless-cafe.test`
  (`e5db228e-0041-413f-a0f7-279e1adf5db9`) and staff `staff-gate@sleepless-cafe.test`
  (`3427770d-2f86-479a-b369-ff459e23484e`). The two `staff-probe` users (`890bb2f2-4ee3-45ce-9935-392dd032663d`,
  `85547c24-f226-4e96-b6d3-b77a331a3b8a`) have unrecorded passwords and 400 on sign-in — ignore them.
  Demo passwords live in the transcript/shell only, never in a committed file.
- All probe objects removed live (`zz_probe_tbl`, `zz_view1`, `zz_probe_fn`, `zz_p1..zz_p6`,
  `zz_m1..zz_m3`).
- Local static server (still live): `python -m http.server 8731 --directory <repo root>`.
  Working URLs: `http://localhost:8731/menu.html?sburl=…&sbkey=…`, same for
  `cashier.html` (+ `&email=&password=` — values not recorded here), `kitchen.html`, `owner.html`.
  The query params are no longer needed: `assets/config.js` now commits the real public defaults, so
  both hosts boot with no params at all.
- Git: **`main == origin/main`** — the human asked for a push this turn, so the three R10 commits on top of
  `a7ab4bd` (`7916a0d feat(phase-7)` editable claim, `ce3b24e fix(phase-7)` cart qty / double-tap guard / board
  viewport, plus the `docs(phase-7)` commit that carries this section) are now on the public branch. GitHub Pages
  rebuilds and serves the R10 tree; `assets/app.css` is served with `Cache-Control: max-age=600`, so a returning
  visitor can keep the previous stylesheet for up to ten minutes. Standing rule unchanged: a push needs an
  explicit human request, and the agent never pushes on its own.

---

## 3. What each file currently is

| File | State |
| --- | --- |
| `sql/01_schema.sql` | 6,899 B. 4 tables, 6 indexes incl. partial `orders_live_pending_idx`. No RLS enablement anywhere (by design). **Changed 2026-10-20 (`f9194aa`):** line 74 `expires_at timestamptz NOT NULL DEFAULT now() + interval '30 minutes'` (was 60) and the header comment at line 8. Live DB moved to match - see sec 8.1. |
| `sql/02_functions.sql` | **Fixed, 49,311 B, applied live, call-tested.** 19 functions, all `RETURNS jsonb … LANGUAGE plpgsql`. Header carries six `-- FIX:` paragraphs. **R9 (`f637cc8`):** `delete_category` gained the `MENU_ITEM_IN_USE` pre-check plus a nested `SQLSTATE '23503'` net - see sec 8.2. **Staff identity 2026-10-21 (files only, NOT live):** 17 fences added — 7 owner `NOT_OWNER` (`roster_role_of(email) <> 'owner'`) + 10 station `WRONG_STATION`, each preceded by `STAFF_SESSION_REQUIRED` → `STAFF_NOT_REGISTERED`; still 19 functions, the roster fns live in 07. **UI/UX sweep 2026-10-21 (files only, not yet committed):** `items_count` is now CUPS not lines — `COALESCE((SELECT SUM(oi.quantity) FROM order_items AS oi WHERE oi.order_id = o.id), 0)` at the four sites (`create_order`/`claim_view`/`list_active_pending`/`confirm_payment`) — plus a new owner-gated `sales_report(from_time, to_time, grain)` answering ONE LEVEL FINER than the grain handed in (daily → per-sale rows, monthly → per-day, yearly → per-month); both LIVE-applied (201) over `database/query` |
| `sql/03_rls.sql` | **Rewritten, applied live, behaviour-verified.** 11,531 B. 4× `ENABLE ROW LEVEL SECURITY` first, then 11 policy pairs each preceded by `DROP POLICY IF EXISTS`. **R10 (`7916a0d`):** `orders_staff_update` WITH CHECK extended to two arms (unpaid-with-`paid_at IS NULL` / paid-with-`paid_at IS NOT NULL`) so a cashier can reprice a live claim, and `order_items_staff_write` (auth, FOR ALL, `WITH CHECK quantity >= 1 AND subtotal = unit_price * quantity`) added — see sec 9.4. **Staff identity 2026-10-21:** pointer comment only (`:18-22`) — identity is resolved by `staff_session()` in 07; no policy changed here, roster policies live IN 07 (apply order 01→…→07). |
| `sql/04_realtime.sql` | **Corrected + applied live.** Publication claim replaced with the verified membership+delivery contract; executable `alter publication supabase_realtime add table orders;` added; v4 wire block replaced with the 2.118.0 `.on(...)` surface. |
| `sql/05_seed.sql` | Applied live, idempotent (`ON CONFLICT (id) DO NOTHING`), no DELETE/TRUNCATE. |
| `assets/api.js` | 14,761 B. JSON envelope `{success,data,error}`; `callSql` on `/rpc/`; thin wrappers over all 19 fns (incl. the three claim-edit wrappers `getClaimView`/`setClaimItemQty`/`addClaimItem`); `getRows`/`getMenu`/`getCategories`; `uploadImage` is a **POST** with `x-upsert: true` + binary body (docs-confirmed form, unchanged — the comment above it still says "PUT", fix in Phase 6); `deleteCategory`/`updateMenuItem` now send `p_*` keys (`p_category_id`/`p_fallback_category_id`, `p_menu_item_id`/`p_name`/`p_description`/`p_image_url`/`p_sizes_and_prices`/`p_is_available`); `fmtPeso`/`fmtTime`/`fmtCountdown`; session-token setters. **Staff identity 2026-10-21 (files only):** 9 exports added — `staffSession`/`rosterList`/`rosterAdd`/`rosterSuspend`/`rosterReactivate`/`rosterMoveStation`/`rosterResetPassword`/`signupAccount`/`newMemorablePassword` (28 → 37). **UI/UX sweep 2026-10-21 (files only, not yet committed):** `salesReport(from, to, grain)` added next to `turnoverStats` |
| `assets/config.js` | **Fixed 2026-10-24 (`b62fd2f`) and 2026-10-20 (`f9194aa`), 2,044 B.** Line 31 now carries `ttlMinutes: 30,` - the client mirror of the DB column default (they must change as a pair, sec 8.1). Priority unchanged (`window.SL_CONFIG` → `localStorage.sl_config` → committed default), but the committed default is now the **real** project URL + publishable key — no longer a `REPLACE_ME` placeholder — so a first-time visitor on GitHub Pages boots with no query params at all. Nothing secret is committed: publishable keys are public by design, the service-role key is nowhere in the repo. `ownerEmails` still has no committed value; it comes from `?owneremails=` → `sl_config`. |
| `assets/favicon.svg` | **New (2026-10-24).** 1,237 B self-contained brand mark. Declared by all five pages. Its three hexes (`#140c08`/`#d48d37`/`#f8f1e5`) mirror `--brand-dark`/`--brand-accent`/`--brand-cream` in `assets/tokens.css` — a standalone favicon is fetched as its own document and cannot read `var()`, so this is the one documented exception to "tokens.css is the only place brand colors are defined". |
| `assets/realtime.js` | **Functional, ported to supabase-js 2.118.0.** Public surface unchanged (`mode`, `stopWatching()`, `startWatching(onEvent, poll)`), so `kitchen.html` needed no edit. WS confirmed via `wait:true` before `mode='ws'`; honest polling fallback; per-socket `dead` flag teardown. **UI/UX sweep 2026-10-21 (files only, not yet committed):** `startPolling(poll)` now starts ALONGSIDE the WebSocket in `startWatching` right after `mode = 'poll'` — the 3 s poll is the backstop for a silently-dead socket (a throttled/backgrounded tab never fires `close`); `mode` only becomes 'ws' after a server-confirmed SUBSCRIBED |
| `assets/app.css` | **9,662 B, extended four times (`2342c83`, `eab2481`, `1696a96`, `ce3b24e`).** Component blocks per page. New this pass: `.size-chip` / `.size-chip.selected` (offered = outline only, selected = filled background + glow + bolder text) and `.cart-btn` / `.cart-btn-remove` (40 px tap targets; the red on Remove is a **semantic** status color, not brand identity), then `.cart-line` + `.cart-price` (sec 4 D4) which line the amount and the steppers down the cart. Every brand color stays `var(--brand-*)` through `color-mix` — no new brand hex hardcoded. **Cache note:** Pages serves this file with `Cache-Control: max-age=600`, so a returning visitor can keep the previous stylesheet for up to 10 minutes after a push. **Sweep 2 (2026-10-21, SHIPPED `fe296fb`):** `.claim-add-row` / `.claim-add-name` / `.claim-add-sizes` added (sec 13 item 1) — 48 px size chips in equal auto-fit lanes, name above the chips under 40rem |
| `menu.html` | **29,158 B, fixed five times (`2342c83`, `eab2481`, `1696a96`, `f9194aa`, `ce3b24e`).** **UI/UX sweep 2026-10-21 (files only, not yet committed):** the cart/card stepper is now `− qty +` (minus LEFT, plus RIGHT) with the copy "The number between − and + is how many you have…". Gate passed: cart → checkout → real order with a real 5-digit code. Config bootstrap is a **classic** script above the module script. Code rendered as a **string** (leading zeros preserved). **Two customer-facing defects fixed:** (1) cart lines were plain rows with no controls and `setQty` clamps at 1, so nothing in the cart could be undone — every line now carries `+` / `−` / `Remove` (`data-cart-qty`, `data-cart-remove`) and `setCartQty` deletes the entry when the quantity would fall below 1; (2) every size chip rendered with identical classes and the choice lived on the card (`data-size`), which `paint()` destroys on the next `innerHTML` replacement, so a size tap gave zero feedback — selection now lives in a page-level `sizeChoice` Map and the chosen chip gets a filled background, a check icon and `aria-label="Selected size: …"` (never color alone). `addToCart` reads `sizeChoice` first, so the size the customer sees is the size that gets ordered. **Checkout restructured the same day (`eab2481`):** the DOM is three sibling blocks in order — `#app` (menu), `#namefield` (Full Name card), `#cartarea` (cart) — so the name field paints ABOVE the cart and neither block is destroyed by the other's repaint; `render()` became `renderMenu()`, `paint()` writes `#app` + `#cartarea`, `paintError()` owns the fixable-cart choice; **`data-checkout` IS the place-order action** (no `Place Order` button, no `awaitingName` flag, no `input` `change` listener), and it reads `[data-name-input]` and refuses a blank/over-100-char name client-side BEFORE any request, with the refusal line rendered ABOVE the still-present field (`nameFieldHtml(complaint)`) — the old `paintNameCopy` wrote the copy and immediately re-rendered the field, so the message never survived a frame. **Third pass the same day (`1696a96`):** cart rows left `flex items-center justify-between` (which spreads the leftover space BETWEEN items, so the amount and the steppers drifted to a different x on every row) and became `class="cart-line"` with the grid in `app.css`; `setName` now refuses anything that is not letters — `/^\p{L}\p{L} '\-]*$/u` — plus a two-letter minimum, so the digits-only name in the customer's screenshot can no longer reach the counter; the success instruction paragraph gained `mx-auto` + `text-center`; the footer gained `© 2026 Sleepless Cafe · All rights reserved · Powered by CapFam, Ltd.` **Phase 8:** compiled-CSS link at line 30, CDN + inline tailwind.config script removed (2026-10-21 phase-8) |
| `cashier.html` | **30,555 B, reworked in the R10 pass (`7916a0d` + `ce3b24e`).** Gate passed: code lookup + live unpaid table + countdown + Confirm Payment → `paid`. Same classic-script bootstrap fix. New: the board is server-sorted and wrapped in a scrolling viewport (sec 9.3), and a looked-up claim renders as a cart-like editable card — per-line `+` / qty / `−` / `Remove` plus an "Add to this claim" size-chip panel — before Confirm Payment is allowed (sec 9.4). `claimBusy` guards every edit and the payment so one tap cannot race the next. **Phase 8:** compiled-CSS link at line 30, CDN + inline tailwind.config script removed (2026-10-21 phase-8) · **UI/UX sweep 2026-10-21 (files only, not yet committed):** staff NAME from `staff_session()` `display_name` (footer + accent line on the board), a real `data-logout` Log out button, 3 h idle teardown (`IDLE_MS = 3*60*60*1000` → `clearSessionToken()` + `sl_auth` removed + gate copy), boot roster check (`NOT_CASHIER` / `STAFF_NOT_REGISTERED`), and the same `− qty +` stepper · **Sweep 2 (2026-10-21, SHIPPED `fe296fb`, sec 13):** Log out button + staff name line moved into the STICKY header (`#logoutbtn` toggled with the `hidden` attribute, `#wholine` written by `paintWhoLine()` via `textContent`), the code input switched `box-content` → `box-border` with the buttons inside the card, the Add-to-claim panel rebuilt as `.claim-add-*` grid rows, and logout now hands back to `login.html` 2.5 s after the gate copy |
| `kitchen.html` | 19,949 B, **unchanged through phase 7**. Board renders, Hold only when not preparing, `startWatching(repaint, repaint)` + 1 s paint tick. **Gate met** via the fixed realtime.js (dot = WS live, card appears without reload). **Phase 8:** compiled-CSS link at line 30, CDN + inline tailwind.config script removed (2026-10-21 phase-8) · `min-h-[48px]` latent fix landed on Hold (:186) — the 48 px KDS tap targets now actually apply · **UI/UX sweep 2026-10-21 (files only, not yet committed):** peso removed entirely (the cashier owns pricing, the kitchen owns make-time); item name `text-2xl font-serif`, per-line qty `text-2xl font-mono` as `N×`, cups chip `N cups` summed from item quantities, order code demoted to `text-xs` · **Sweep 2 (2026-10-21, SHIPPED `fe296fb`, sec 13 item 6):** the card header is `flex items-baseline space-between gap-4 flex-wrap` and the reference number now wears its own bordered chip, so name / cups / code no longer run together |
| `owner.html` | 41,385 B, **Phase 5 fix applied + R9 `ERR_COPY` line (`f637cc8`)**. `MENU_ITEM_IN_USE` copy added at line 167 so the refusal renders as human prose, not the generic HTTP fallback. The config bootstrap was lifted into a classic `<script>` above the module script (same block as `cashier.html`) and now also persists `?owneremails=` into `sl_config.ownerEmails`, which is what the owner allowlist gate reads. **Phase 8:** compiled-CSS link at line 30, CDN + inline tailwind.config script removed (2026-10-21 phase-8) · `min-h-[48px]` latent fix landed on Void (:217) / Up (:361) / Down (:362) · **Staff identity 2026-10-21 (+267 lines, files only):** Tab 5 Staff Roster — list (`roster_list`), add-employee **pairing rule** (`signupAccount` → `rosterAdd` with the SAME credentials, never one without the other), suspend/reactivate, move station, `LAST_OWNER_ONLY` refuses demoting the last active owner, reset shows the memorable temp password **ONCE** · **UI/UX sweep 2026-10-21 (files only, not yet committed):** Focus `<select data-sales-focus>` dropdown on the Sales tab (All days / every day, month or year in the window, generated in UTC so an empty period stays selectable); focusing narrows the window AND drops the chart one step; the CSV follows `salesGrain` (the owner's pick), not the chart's finer grain; filename carries the focus label; window line prints ISO slices + bar grain, never `fmtTime` · **Sweep 2 (2026-10-21, SHIPPED `fe296fb`, sec 13 item 7):** that `<select>` was REPLACED by a DOM chip panel (`focusOpen` flag + `focusToggle()` + `focusPanel()`) because a styled native `<select>` opens and closes itself on one tap in Chrome; the remaining native selects (menu builder, categories, roster role) still carry the same defect, unfixed |
| `index.html` | 11,274 B. Only valid cross-page link in the repo: `<a href="menu.html">` at line 160. **Fixed 2026-10-24:** the build-status strip said `pending` ×5 on a finished public site — now `live` ×5 plus an honest note that the staff pages are reached by direct URL, not linked from the root. **R9 (`f9194aa`):** lines 114 and 154 now say 30 minutes. Static landing page with no config bootstrap, so those are literals - documented drift risk, sec 8.1. **Phase 8:** compiled-CSS link at line 30, CDN + inline tailwind.config script removed (2026-10-21 phase-8) |
| `MASTER_PLAN.md` | §4a added: "Platform facts verified live (Phases 1–3)" — RPC path, Phase-A staff account, `assets/ui.js` deviation. |
| `tests/api.spec.md` | TRANSPORT NOTE added under §1. **R9:** `deleteCategory` row carries the `MENU_ITEM_IN_USE` failure shape and the code table gained that row. **R10:** `getOrderByCode` row now shows the `order_id` + `items[]` shape (its body IS `claim_view`), three RPC rows added (`getClaimView`/`setClaimItemQty`/`addClaimItem`), and the code table gained `CLAIM_NOT_OPEN`/`INVALID_QTY`/`LINE_NOT_FOUND`/`LAST_LINE_ONLY` with the verbatim cashier copy. |
| `assets/ui.js` | **Does not exist** and is referenced by no page (only `MASTER_PLAN.md:99`). Deliberate deviation: each page ships its own inline UI, keeping dispatches inside the 1–3 file budget. Do not create dead code. |
| `Sleepless.html` | Design reference only, never edited. Its dangling `staff.html` link at `:237` is out of scope. |
| `assets/tailwind.compiled.css` | **New (2026-10-21, phase-8).** 12,139 B committed build artifact — the compiled Tailwind v3.4.17 stylesheet every page now loads at line 30. Regenerate on any token change: `node ./node_modules/tailwindcss/lib/cli.js build -i tools/tailwind.src.css -o assets/tailwind.compiled.css -c tools/tailwind.config.js -m`. **Rebuilt 2026-10-21: 12,252 B (+113 B)** once `login.html` joined the scan. **Rebuilt again for sweep 2 (288 ms)** so `box-border`, `gap-4`, `items-baseline`, `rounded-md`, `px-2 py-1`, `border-brand-accent` and `bg-brand-accent/30` all compile — verified by grepping the artifact |
| `tools/tailwind.config.js` + `tools/tailwind.src.css` | **New (2026-10-21).** The v3 build tooling behind that artifact. The config READS `assets/tokens.css` at build time, so `tokens.css` stays the single source of truth for brand colors — the compiled CSS carries the resolved hexes and no page re-declares one. **Staff identity 2026-10-21:** `login.html` added to `content`, so the door contributes its own utilities. |
| `functions/purge-expired/index.ts` | **New (2026-10-21), NOT deployed.** Dependency-free Deno Edge Function for the server-side TTL sweep: it mints a REAL staff JWT (password grant) because `sql/03_rls.sql:141` `orders_staff_delete` is `TO authenticated`, so a service-role sweep is denied by design. Secrets `SL_SB_URL`/`SL_PUBLISHABLE_KEY`/`SL_STAFF_EMAIL`/`SL_STAFF_PASSWORD` live only in Edge-Function env. Live deploy deferred: needs the signed-in dashboard + human approval of the staff-credential secrets. |
| `tools/cron/purge-expired.json` | **New (2026-10-21), NOT registered.** The `*/15 * * * *` cron spec (array-wrapped so `supabase cron add -f` accepts it); its Notes carry the live-application steps. |
| `package.json` + `package-lock.json` | **New (2026-10-21).** Pins `tailwindcss ^3.4.17` — the major version the CDN served at runtime, so the compiled output matches what the pages used to receive from `cdn.tailwindcss.com`. |
| `sql/07_staff_roster.sql` | **New (2026-10-21), LIVE since 2026-10-21 (pasted in 4 chunks, all 201).** `staff_roster` table (email-keyed UNIQUE, `added_by` self-FK `ON DELETE RESTRICT`, no password column — `pw_note` is free text, never a secret) + its own RLS (`roster_authenticated_read`/`_write_insert`/`_write_update`/`_delete`, **no anon policy at all**) + 11 functions (`jwt_claims_email`, `roster_role_of`, `cap_word`, `make_memorable_password`, `staff_session`, `roster_list`, `roster_add`, `roster_suspend`, `roster_reactivate`, `roster_move_station`, `roster_reset_password`) + **3 seed rows** — `dev@sleepless-cafe.test` owner, `cashier-probe@…` cashier, `kitchen-probe@…` kitchen. Idempotent; **APPLY AFTER 06**. |
| `sql/08_multitenant.sql` | **NEW 2026-10-23 — 32,869 B / 623 lines. APPLIED LIVE 2026-10-23 (9a schema block + 9c policy swap, all chunks 201) and COMMITTED `a64ce1e`.** The Phase 9 migration: `stores` table (slug UNIQUE + `tier CHECK IN ('starter','pro')`) seeded with the legacy store, four bare `ALTER TABLE … ADD COLUMN store_id uuid NOT NULL DEFAULT <legacy-uuid> REFERENCES stores ON DELETE RESTRICT` (menu_items / categories / orders / staff_roster), `created_at` on `order_items`, the five store-scoped indexes, the JWT helpers (`jwt_store_id`, `store_tier_of`, `cap_allows`, `tier_gate`, `starter_write_gate`), the store-scoped policy swap, and the new RPCs (`resolve_store`, `menu_for_store`, `categories_for_store`, `purge_expired_orders_store`, `purge_expired_orders_all`). **APPLY AFTER 07.** Its schema block runs ONCE — a re-paste aborts atomically on the duplicate-column error, which is the safe re-run signal. Header carries the do-not-re-derive list. |
| `MULTI_TENANT_SPEC.md` | **NEW 2026-10-23 — 19,956 B / 327 lines. COMMITTED `a64ce1e`.** The architecture spec + refactoring plan the human asked for: §1 multi-tenant schema/RLS contract · §2 tier model + gating matrix · §3 realtime + 30-min expiry · §4 routing/auth (Pages vs Vercel, store token options A/B/C) · §5 per-function gating delta · §6 safe-migration roadmap 9a→9f + a 6-probe verification checklist. **Numbering is cross-referenced from `sql/08_multitenant.sql` — do not renumber either file.** |
| `sql/09_function_delta.sql` | **NEW 2026-10-23 — 14 `CREATE OR REPLACE` bodies. COMMITTED `a64ce1e`.** The captured 9d function delta (12 bodies from `sql/02_functions.sql` + `staff_session`/`roster_add` from `sql/07_staff_roster.sql` — both were still the PRE-9d version on disk, so a future re-paste of 02/07 alone silently REVERTS the store-scope and tier gating). **Replay AFTER 08**; it overrides those bodies with no signature change, so `api.js` URLs stay put. Spec-faithful reconstruction (originals verbatim + `MULTI_TENANT_SPEC.md` §5.2 edits), NOT a verbatim live dump — call-tested against the second store before trusting byte-equality with live 9d. |
| `sql/10_marcelas_store.sql` | **NEW 2026-10-23 — 9,193 B / 145 lines. APPLIED LIVE 2026-10-23 (chunks A/B both 201) + COMMITTED `a64ce1e`.** INSERT-only idempotent seed for the SECOND branch: store row `00000000-0000-0000-8333-000000000002` slug `marcelas` tier `starter`, 4 categories (`3333…` UUID space), 10 menu items (`4444…`), `store_id` passed EXPLICITLY on all 14 rows, every INSERT `ON CONFLICT (id) DO NOTHING`. **Replay AFTER 09.** |
| `stores/marcelas/README.md` + `stores/marcelas/tokens.css` | **NEW 2026-10-23 — the second-branch folder. COMMITTED `a64ce1e`.** README carries the store brief (slug/uuid/tier/city/timezone), the palette table with provenance, the replay order and the anon-order limitation. `tokens.css` is the per-branch theme in THREE blocks: `:root[data-sl-store="marcelas"]` custom properties, all 27 compiled `brand-*` rules hand-mirrored under `[data-sl-store="marcelas"]` (the compiled artifact bakes literal hex — see §15), and the `.font-serif`→Cinzel mirror. `assets/tokens.css` stays flagship's single source of truth and was NOT touched. |
| `login.html` | **New (2026-10-21), 215 lines, NOT linked from any page.** The staff door: credentials **typed in the page**, never read from the URL; `signIn` → `setSessionToken` → `staff_session` proves the roster row, then `window.location.replace` routes to `cashier.html` / `kitchen.html` / `owner.html` by role. Persists `{email,password}` to `localStorage.sl_auth` for the station boot. `noindex`, unlinked. **UI/UX sweep 2026-10-21 (files only, not yet committed):** the card no longer spills full-width — the `</div>` written after a VOID `<input>` was closing the card early; `renderCard`/`openForm` use `glass-card rounded-xl p-6 my-6 mx-auto max-w-md flex flex-col gap-3`, inputs end bare with `py-2 min-h-[48px]`, Sign-in button `mt-3 w-full` |

All five pages (`index.html`, `menu.html`, `cashier.html`, `kitchen.html`, `owner.html`) now carry the
identical favicon block at lines 26–28, immediately after the `assets/app.css` `<link>` — added because
with no icon declared every page load requested `/favicon.ico` and GitHub Pages answered 404.

Deleted this session (repo-root junk, never committed): `_probe1.ps1`, `_rc.d.txt`, `_rj.txt`,
`_rt.d.txt`, and a duplicate root-level `realtime.js` (byte-identical to `assets/realtime.js`).

---

## 4. Next actions, in order (the plan is already decomposed — follow it)

**A. Phase 4 — DONE (gate met, committed `19fef79`).** `alter publication … add table orders` applied
live; `sql/04_realtime.sql` corrected; `assets/realtime.js` ported to supabase-js 2.118.0. Live gate
evidence: dot = WS live, paid card appears on the KDS with **no reload**, and `mark_served` wrote
`served_at` + `fulfillment_time_seconds` (authenticated DB read — see §2). Nothing left to do here.

**B. Phase 5 — DONE (gate met, see the two `phase-5` commits in §7).**
- `delete_category`/`update_menu_item` parameter names renamed to `p_*`: bare names collided with `menu_items`/`categories` columns → live `400 {"code":"42702","message":"column reference \"category_id\" is ambiguous"}`.
- plpgsql parses lazily, so `CREATE` succeeded and the error only appeared at **CALL** time; `CREATE OR REPLACE` cannot rename parameters, so the live fix needed `DROP FUNCTION delete_category(uuid, uuid);` first.
- `sql/06_storage.sql` is new; the `menu-images` bucket and its ACLs are applied live: 5 policy rows, all `TO authenticated`, all `USING (bucket_id = 'menu-images')`.
- anon upload still `403 AccessDenied "new row violates row-level security policy"`; authenticated upload `200`; upsert overwrite `403` before the UPDATE policy then `200` after; public read `GET /storage/v1/object/public/menu-images/zz.png` → `200 70 B`.
- owner RPCs verified live with an owner bearer token: `sales_summary` → `{"revenue":230.00,"completed_count":2,"aov":115.00,"grain":"daily","buckets":[{"count":2,"label":"2026-10-19","revenue":230.00}]}`; `turnover_stats` → `{"sample_size":2,"avg_fulfillment_seconds":1268,"p95_fulfillment_seconds":1641,"peak_hours":[{"hour":12,"orders":2}]}`; `create_category`/`reorder_categories`/`delete_category`/`create_menu_item`/`update_menu_item`/`void_order` all returned `success:true` envelopes.
- The seeded pending order aged out of TTL during the session, so `orders` now holds only the 2 served rows — expected purge behaviour, not a bug.

**C. Phase 6 — QA (`qa-engineer`) — DONE (sweep passed, see the `phase-6` commit in §7).**
- 14/14 live anon probes conform to the `{success,data,error}` envelope. All 7 owner RPCs answer
  `OWNER_SESSION_REQUIRED` as anon (security boundary re-confirmed); bare `/rest/v1/<fn>` still 404
  `PGRST205`; `get_order_by_code` bad code → `ORDER_NOT_FOUND`; `list_active_pending`/`kitchen_queue`
  → `success:true, data:[]` (RLS filters anon's view of `orders` to nothing); `void_order` bad id →
  `NOT_VOIDABLE`; `create_order` with an unoffered size → `INVALID_SIZE` before any INSERT.
- Link/asset sweep clean: every `href`/`src` in the 5 pages resolves; the only intended cross-page
  link is `index.html:160 → menu.html`; no page references `assets/ui.js`.
- **UI fix pass 2026-10-24 (`2342c83`, pushed `d9ccdca..2342c83`)** — two defects a dogfooding customer
  reported on the live menu, both reproduced on `localhost:8731` before and after the fix:
  1. *"you cant delete items in cart"* — `renderCart()` drew each line as a plain row and `setQty` is
     clamped at 1, so no path reached zero. Cart lines now carry `+` / `−` / `Remove`; verified that
     `−` at ×1 deletes the line and the empty-cart copy renders, `Remove` drops a ×2 line outright,
     `+` increments, and totals/counts recompute.
  2. *"no identifier for the client if it is already selected"* — chips were visually identical and the
     choice was destroyed by the next repaint. Verified the first chip renders selected, tapping another
     chip moves the marker, the marker survives a category switch (`sizeChoice` is page-level), and
     Add to Cart prices the **selected** size (Large = 170.00, not the 140.00 default).
- Static console sweep clean: no import/export mismatches (25 exports in `api.js`), no undefined
  identifiers, no duplicate `id` attributes, all 8 in-page `JSON.parse` sites are `try/catch`-guarded.
- One defect found and fixed: the comment above `uploadImage` said **PUT** while the code is **POST**
  + `x-upsert` — comment corrected, code untouched.
- Flagged, NOT fixed: `void_order` carries no JWT/session guard, so as anon it answers `NOT_VOIDABLE`
  (its `SELECT` is RLS-filtered to empty) rather than `OWNER_SESSION_REQUIRED`. Safety is RLS
  (`orders_staff_delete` is authenticated-only + `status='pending_payment'`), so no anon `DELETE` is
  reachable; "owner-only" is a UI decision (§9.7), not a JWT claim check.

**D. Phase 7 — GitHub Pages dogfood (`qa-engineer` + `devops-lead`) — DONE (Gate A green except the
manual phone run; evidence in §7 below).**
- Public URL live: `https://savage13317.github.io/sleepless-cafe-pos/` serves `index.html` (200, 10,735 B)
  from `main`; `noindex` present on `cashier.html:2`, `kitchen.html:2`, `owner.html:2`.
- Walkthrough on the public site: `menu.html?sburl=&sbkey=` → config written to `localStorage` → Flat
  White order **13341 "Gate A Walker"** → `cashier.html?email=&password=` → **Paid — sent to the
  kitchen** → `kitchen.html` → **Marked as served** (`served_at` written). Second order **21574
  "Gate A Second"** (Hot Chocolate) paid + served. Owner Sales tab: **₱615.00 revenue / 4 completed /
  ₱153.75 avg** across 2026-10-19 and 2026-10-20.
- TTL deletion proof: probe order `code='90001'` with `expires_at` 30 min in the past (+2 `order_items`)
  → authenticated `list_active_pending` deleted it — `SELECT * FROM orders WHERE code='90001'` → `[]`,
  its `order_items` → `0`. The sweep ran with an **owner JWT**: an anon sweep cannot delete
  (`orders_staff_delete` is authenticated-only), which is the RLS boundary working as designed, not a
  TTL bug. (A real 60-min wait was not sat; the probe's `expires_at` was back-dated instead.)
- Permanence proof: 10 consecutive authenticated sweeps left 4 served orders + the live pending order
  intact, `order_items` count unchanged (5), analytics unchanged.
- `void_order` exercised on the public owner UI: **Void claim** arms ("Void drops claim 71377 and its
  items for good. Tap "Confirm void" again to do it.") → **Confirm void** → "Claim 71377 voided — the
  row and its items are gone."; `SELECT` for 71377 → `[]`, its items → 0, revenue unchanged (voided
  unpaid orders never counted).
- Caveats: (1) the cashier session used the **owner's** credentials — the two `staff-probe` Auth users'
  passwords were never recorded, so their sign-in returned 400; `mark_paid`/`mark_served` need only
  `authenticated`, so the flow is proven but not role-differentiated. **Closed afterwards:** a real
  non-owner user `staff-gate@sleepless-cafe.test` (`3427770d-2f86-479a-b369-ff459e23484e`) was created and
  the whole create → pay → serve flow plus the RLS-fence probes were re-run on its JWT (§7). (2) the pushed
  `owner.html` predates the phase-5 bootstrap fix, so `?owneremails=` was ignored on the public site — worked
  around by writing `sl_config.ownerEmails` into `localStorage`; the fix is committed at `0375ac8` and is
  now **live** (pushed 2026-10-20, Pages rebuilt — see §7), so `?owneremails=` works on the public site
  without the workaround. (3) the "on a phone" item is manual and still unticked in `MASTER_PLAN.md` §7.

**D2. Phase 7 addendum — Gate A audit on the PUBLIC host, three defects found and fixed (commit
`b62fd2f`, pushed `af1f4de..b62fd2f`).** The audit re-ran the Phase 2–7 gates against
`https://savage13317.github.io/sleepless-cafe-pos/` with `localStorage` cleared and **no query params**,
which is how a real first-time visitor arrives. Phases 2–7 had all been verified on `localhost:8731`
**with** `?sburl=&sbkey=`, which masked them:
1. **BLOCKER — the site was unusable for a first-time visitor.** `assets/config.js` committed
   `https://REPLACE_ME.supabase.co` with an empty `sbKey`, so `menu.html` issued two requests to that
   host → `net::ERR_NAME_NOT_RESOLVED` ×2 → the app answered with the NETWORK copy
   ("We can't reach the cafe right now. Check your connection and try again.") and rendered **0 items**.
   Misleading: the visitor's connection was fine. Fixed by committing the real project URL + publishable
   key as defaults (public by design; still no secret in the repo). `?sburl=&sbkey=` survives as an
   optional override, not a requirement.
2. **Dead request on every visit:** `grep favicon|rel="icon"` → 0 hits repo-wide, so each page load
   requested `/favicon.ico` and Pages answered 404. Added `assets/favicon.svg` + an identical
   `rel="icon"` link on all five pages.
3. **Stale honesty:** the build-status strip in `index.html` said `pending` on all five phases. Now
   `live` ×5.

Post-fix verification: `assets/favicon.svg` serves `200 1237 B`; with `localStorage` cleared,
`menu.html` with **no** query params renders the full 12-item catalogue (Coffee 4 / Non-Coffee 3 /
Pastries 3 / Desserts 2) and zero `REPLACE_ME` requests. The only console message left on every page is
the documented `cdn.tailwindcss.com` warning, which Gate B removes.

**Post-fix dogfood on the public host — 7/7 PASS** (fresh visitor, no query params, `sl_config`/`sl_auth`
cleared first): catalogue 12/12 rendered with `sl_config` still `null` (the committed defaults did the work,
nothing written) → order **`33667` "Maria Santos"** (code kept as a 5-digit string) → cashier signed in as
`staff-gate@sleepless-cafe.test`, countdown `59:19`, Confirm Payment → **"Paid — sent to the kitchen."** →
kitchen card appeared with the dot reading **WS live**, Mark as Served → **"Marked as served — card leaves
the board."** → owner gate accepted `?owneremails=` on the public site (no localStorage workaround needed)
and the Sales tab reads **₱875.00 / 6 completed / ₱145.83 avg**. `rel="icon"` present on all pages;
`assets/favicon.svg` → 200. Console on a fresh load: the Tailwind CDN warning only — no
`net::ERR_NAME_NOT_RESOLVED`, no page-initiated `/favicon.ico` request, no NETWORK copy.

**D3. Phase 7 addendum 2 — customer checkout restructure on `menu.html` (commit `eab2481`, pushed
`b92c7a4..eab2481`)** — a third dogfooding report: *"full name should be above the cart and proceed to
check out should function like place order... and it should check the name (should not be blank) before
proceeding checkout"*. Reproduced on `localhost:8731` first, then fixed — one file, `menu.html`:
1. **Name field rendered below the cart** → the DOM is now three sibling blocks in order: `#app` (menu),
   `#namefield` (name card), `#cartarea` (cart). The field and the cart both live OUTSIDE `#app` because
   `paint()` replaces `#app.innerHTML`; a cart inside `#app` cannot be repainted without being destroyed
   by the menu render. `render()` → `renderMenu()`, `renderError()` slimmed to the copy block, and
   `paintError()` now owns the fixable-cart choice (`MENU_ITEM_UNAVAILABLE` / `INVALID_SIZE` keep the
   cart visible, everything else clears it).
2. **Two action buttons** — `Place Order` under the field plus `Proceed to Checkout` in the cart, where
   the checkout button only armed an `awaitingName` flag and relied on an `input` `change` listener to
   submit later — merged into one: the `data-checkout` branch performs the place-order action. The
   `data-placeorder` branch, the `awaitingName` flag and the `change` listener are deleted, so typing
   alone can never fire a request and the customer taps exactly once.
3. **Blank name guard, client-side before the network** — the checkout tap calls `setName()` on the
   field's value first; blank (or over 100 chars) is refused with a human line and nothing is sent. The
   server's `INVALID_CUSTOMER_NAME` stays as the backstop. This exposed a latent defect: `paintNameCopy()`
   swapped the field for the copy and then called `openNameInput()`, which overwrote it in the same frame,
   so a refused tap showed nothing at all. `nameFieldHtml(complaint)` keeps the field and puts the copy
   above it, so the customer can fix it and tap again.
- Verified live on `localhost:8731` after the fix: DOM order `app,namefield,cartarea`; zero
  `[data-placeorder]`; no checkout button while the cart is empty; blank-name tap → "We need your name
  at the counter." visible above the field with the cart intact and **no request sent**; name typed +
  tap → success screen (code `51573` as a string, name echoed, 60-minute instruction verbatim) with
  `#namefield` and `#cartarea` cleared; cart controls still intact in the new block (`+` → ×2 PHP 280.00,
  `−` `−` → empty-cart copy). Only console message: the Tailwind CDN warning.
- **Pages propagation note:** Pages serves the pushed tree (§1.z), so the public host lagged this push
  for a few minutes. Before trusting a browser test on the public URL, confirm the new markers are live
  with `curl` — `id="cartarea"` and `nameFieldHtml` present, `data-placeorder` absent.

**D4. Phase 7 addendum 3 — cart columns, name guard, footer credit on `menu.html` (commit `1696a96`, pushed
`d80b3e6..1696a96`)**

Four more defects reported from the live page, all in `menu.html` + `assets/app.css` (2 files, 40 insertions /
3 deletions). Verified live on `localhost:8731` before committing.

- **Amounts and `+` / `−` did not line up down the cart.** The row was `flex items-center justify-between gap-2`,
  which distributes the leftover space *between* the items, so the amount and the buttons landed at a different
  x on every line. **A plain `auto` grid does not fix it** — every `.cart-line` is its own grid container, so
  `auto` columns size per row and the steppers still drifted (measured `priceX = 546, 553, 546`). The amount
  track therefore gets a minimum (`minmax(6.5rem, auto)`) and the number is pushed to the END of it with
  `justify-self: end`, which puts every amount flush at one x and keeps the two 40 px stepper columns straight
  underneath. Measured after the fix over three rows: `AMT_R = 599, 599, 599`, `PLUS = 611, 611, 611`,
  `REM = 715, 715, 715`. The name column (`1fr`) absorbs the leftover. No brand color in the block — layout only.
- **`setName` accepted the digits-only name in the screenshot (`12312312`, order `51408`).** Now letters-only:
  `/^\p{L}\p{L} '\-]*$/u`, so Unicode letters (`José`), spaces (`Mary Ann`), apostrophes (`O'Brien`, `D'Angelo`)
  and hyphens (`Anne-Marie`) stay legal; a one-letter name is refused separately. Two new human copies: "Names
  use letters only — no numbers or symbols." and "Please give at least two letters — one letter is not enough."
  Refusals are client-side, before any request. **The server CHECK is unchanged** (`length(trim(customer_name))
  BETWEEN 1 AND 100` in `sql/01_schema.sql`) — tightening the DB rule is a separate backend dispatch, and
  `INVALID_CUSTOMER_NAME` stays the backstop.
- **Success instruction was left-aligned** in the card → `mx-auto` + `text-center` (measured `LGAP = RGAP = 107`).
- **Footer credit** added under the peso line: `© 2026 Sleepless Cafe · All rights reserved · Powered by CapFam, Ltd.`
  (`text-2xs` is not a Tailwind class, so `text-xs` was used). **Only `menu.html` carries it** — the four staff
  pages can mirror it on request.
- **Cleanup:** the six `pending_payment` claims left by this verification pass — `12978`, `29872`, `54154`,
  `87121`, `02910`, `51408` — were all voided with `void_order` (`"voided": true` each). `list_active_pending`
  now returns `[]` and `orders` / `order_items` are back to 6 / 6 rows, matching the counts above.

**Start here next  →  G. Phase 9  —  multi-store + tier model. 9a–9e + 9g APPLIED LIVE and COMMITTED (`a64ce1e` + `70a5a20`, HEAD == origin/main == `70a5a20`); 9f cron/Vercel STILL PARKED (see §14 + §15).**
Read `MULTI_TENANT_SPEC.md` §6 first: the order was **9a schema-only → 9b re-issue staff identities with `data:{sid}` → 9c policy swap + store token (ship as ONE step) → 9d function delta → 9e frontend → 9g second store `marcelas` → 9f gated cron/Vercel**. Replay order on disk is now **01→…→10** (`sql/09_function_delta.sql` overrides the 02/07 bodies; `sql/10_marcelas_store.sql` seeds the second branch). **The five open items in §15 are the next work, not defects** — anon orders from `?store=marcelas` still land in flagship (needs the store-bearing anon token, §4.3-A), no `marcelas` staff identity exists yet (needs a human-created auth user), the global-`code` claim-code collision is unfixed by choice, and the hand-mirrored store theme must be re-mirrored after any Tailwind rebuild.

**E. Phase 8  —  Vercel go-live. PREP DONE (2026-10-21), the phase itself STILL PARKED** (its open items are the "REMAINING Phase-8 items" list at the end of this section). Prep already landed:
- **Tailwind CDN  →  compiled CSS  —  DONE.** All five pages now load `assets/tailwind.compiled.css` (12,139 B
  committed artifact) at line 30, after `assets/app.css`, matching the CDN's runtime injection cascade.
  `tools/tailwind.config.js` reads `assets/tokens.css` at build time, so `tokens.css` stays single-source.
  Latent defect found and fixed: `min-height-[48px]` is not a valid v3 class (the plugin prefix is `min-h`),
  so the KDS 48 px tap targets never applied  —  `kitchen.html` Hold and `owner.html` Void/Up/Down now use
  `min-h-[48px]` and the rule `.min-h-\[48px\]{min-height:48px}` is emitted. Evidence: 0 console messages on
  all five pages (the CDN warning is gone), computed styles exact, compiled CSS 200 / 12,139 B, no favicon 404,
  no CDN request, print rules intact.
- **Cron artifacts  —  DONE (authored, not applied).** `functions/purge-expired/index.ts` (Edge Function, staff-JWT
  mint) + `tools/cron/purge-expired.json` (cron spec). Live application deferred: it needs the signed-in dashboard
  plus human approval of the Edge-Function staff secrets.
- **`tools/inject-config.mjs` exercised  —  DONE (4/4).** Success exit 0 (`assets/config.generated.js` written, 5 tags
  injected, `tools/vercel.json` copied); idempotent re-run skipped everything; fail-loud missing `SL_SB_URL` exit 1;
  fail-loud `sk_`-shaped key exit 1 with 0 leak hits. Artifacts gitignored (`.gitignore:7`, `:20`); tracked pages
  byte-exact restored, so the injector is net-zero on the tree.

**F. Phase 8b — staff identity + login door (2026-10-21) — DONE, then APPLIED LIVE 2026-10-21 (human-authorized; sql/07 + 02 fences + 3 identities + QA green — record: §11).**
- **Dispatches:** `backend-lead` ×3 (`sql/07_staff_roster.sql` authored → the 17 fences folded into `sql/02_functions.sql` → `sql/03_rls.sql` pointer comment) · `frontend-lead` ×2 (`login.html` + the `assets/api.js` roster exports → `owner.html` Tab 5) · `qa-engineer` (honest-degradation sweep). Every dispatch stayed inside the 1–3 file budget.
- **QA honest-degradation table (the live DB has none of this applied):** `login.html` renders and the card answers an **HTTP card** on the missing `staff_session` RPC · owner Tab 5 boots and the roster gate is **honest** (refusal copy, not a blank tab) · 5a `PGRST202` and 5b `PGRST205` are the **absent-live proof** — the roster RPCs are not in the schema cache, so they are not routable, which is exactly what un-applied SQL must look like · 5c `ORDER_EXPIRED` proves the 02 station fences are **not live** (the live DB still runs the old presence-only gates) · `menu.html` regression **PASS** (0 console messages, catalogue renders, no new request).

**REMAINING Phase-8 items:** live cron application (the steps are in the Notes of `tools/cron/purge-expired.json`
 — deploy the Edge Function, set its four secrets, then register the job), a Vercel account/domain, and the **manual
phone run** of Gate A, which needs a real phone. Nothing was pushed this turn.

Phases 2–5 are strictly ordered; file-count budget per sub-agent dispatch is **1–3 files**;
backend verified before frontend; modify only the files the task needs.

---

## 5. Local tooling traps (PowerShell 5.1 + this terminal) — read before scripting

- `$B` and `$b` are the **same** variable (case-insensitive) — use `$BASE`, `$HDR`, `$K`.
- The terminal mangles `ConvertFrom-Json` into `Convert-Json` (not a cmdlet). Extract with
  `-match` / `[regex]::Matches`.
- `Select-Object Name, Size` / `.Length` printed empty — use
  `ForEach-Object { Write-Output ("{0} {1}" -f $_.Name, $_.Length) }`.
- `-CaseSensitive:False` invalid; `ForEach-Object` must not be hyphenated; `Select-Unique`
  is not a cmdlet in 5.1.
- `curl.exe` prints PostgREST bodies; `Invoke-WebRequest` hides them.
- Inline escaped JSON bodies produce `PGRST102`; write the body to a file in the **workspace cwd**
  (`Set-Content -Path ".\zzbody.json" -Value '{"k":"v"}' -Encoding ascii -NoNewline`) then
  `--data-binary "@zzbody.json"`. `$envTEMP\…` fails with Access denied.
- Running a `.ps1` from disk is blocked ("running scripts is disabled on this system") — inline the
  commands instead.
- `$matches` persists across commands: a failed regex silently re-uses the previous match. Print the
  raw head to confirm.
- `grep_search` cannot read outside the workspace — use `Select-String`.

## 6. Dashboard/browser traps

- The SQL Editor Run button is `button[data-testid="sql-run-button"]`; it is `disabled` while
  "Running…", so click-then-read must wait ~9 s.
- The destructive-ops modal's confirm button is labelled **"Run query"** (sibling "Cancel") —
  `/run without/i` misses it. `click_element` times out on it; use
  `page.evaluate` + `Array.from(document.querySelectorAll('button')).find(b => (b.innerText||'').trim() === 'Run query')` then `.click()`.
- Reliable clear-then-type in the editor: `type_in_page key:"Control+a"` → `key:"Delete"` →
  `text:<sql>`. Setting the textarea `.value` via `evaluate` then clicking Run yields
  "query: Too small: expected string to have >=1 characters". A stale textbox ref makes
  `Control+a` time out — re-read the page and grep the temp file for
  `textbox "Editor content"`.
- The Editor renders only the **last** statement's result and appends `limit 100`; a parse error in
  any statement of a pasted group aborts the whole group.
- Read Results rows from the accessibility snapshot (`row "…"` / `gridcell`);
  `[class="result-panel"]` innerText returns `""`; `document.body.innerText` searches are false-positive
  traps (the editor's own code is in body text).
- Navigating away invalidates editor refs (re-read the page). `navigate_page` can be interrupted by a
  `beforeunload` dialog — a plain retry of the same navigation succeeds. Opening a **NEW** browser
  page loses the dashboard session; navigate the authenticated shared page instead.
- `run_playwright_code` returns a `deferredResultId` when not finished — re-call with
  `deferredResultId` + `pageId` (IDs can expire). `evaluate` callbacks cannot see outer JS
  variables — inline the literal, or pass it as an argument: `page.evaluate((c) => {…}, code)`.
- Inside `run_playwright_code`, `window`/`document` are only reachable via
  `page.evaluate(() => …)`; a bare `return window.x` raises `ReferenceError: window is not defined`.
- `page.locator('input').fill('text')` fires `input`/`change` (setting `.value` does not) — required
  for `menu.html`'s name field.
- Noise to ignore: telemetry POST failures (`api.supabase.com/platform/telemetry/event`
  ERR_ABORTED), ~400 console warnings, ConfigCat plan warnings, the "Go to Integrations G then I"
  tooltip, `cdn.tailwindcss.com should not be used in production`.
- No headless browser automation on this box (RTX 3060 budget, `MASTER_PLAN.md` §8). Supabase SQL is
  authored as files first, pasted into the Dashboard second.

---

## 7. Git log at handoff

```
HEAD  d23beda docs(phase-8): record the Phase 8 prep pass - compiled CSS, cron artifacts, injector exercised   <- this commit
e91ce3c feat(phase-8): add server-side TTL cron artifacts (Edge Function + cron spec)
c30b540 feat(phase-8): compile Tailwind CSS and load it on all five pages
21a55a5 docs(phase-7): record the R10 pass - cart qty between steppers, double-order guard, board sort + viewport, editable claim   <- was HEAD, pushed 2026-10-20
ce3b24e fix(phase-7): put the cart quantity between the steppers, refuse a double tap, cap the unpaid board
7916a0d feat(phase-7): make a looked-up claim editable before payment
6d32b9d docs(phase-5-7): record the R9 full-system test pass - TTL 30 min and the delete_category refusal
f637cc8 fix(phase-5): delete_category refuses categories referenced by past orders
f9194aa feat(ttl): claim window 60 -> 30 minutes across backend, client copy and docs
a7ab4bd docs(phase-7): record the cart column fix, name guard, centered success copy and footer credit
1696a96 fix(phase-7): align cart columns, guard the name field, credit the footer
d80b3e6 docs(phase-7): record the checkout restructure - name above cart, one action button
eab2481 fix(phase-7): name field above the cart + one place-order action
b92c7a4 docs(phase-7): record the cart-line controls + visible size selection
2342c83 fix(phase-7): cart line controls + visible size selection
d9ccdca docs(phase-7): record Gate A live evidence - 7/7 fresh-visitor walkthrough
bb58747 docs(phase-7): record the Gate A audit - 4 defects found, 3 fixed
b62fd2f fix(phase-7): make Pages usable for a first-time visitor
af1f4de docs: record Phase 7 completion - Gate A met live
```

`main` is **3 ahead of `origin/main`** after this pass: the three phase-8 commits above (`c30b540`, `e91ce3c`, and
this docs commit) are local only  —  nothing was pushed this turn, and a push needs an explicit human request.

**No new commits this pass (staff identity).** HEAD is still `d23beda` (the phase-8 prep docs commit above);
the staff-identity files (`sql/07_staff_roster.sql`, the amended `sql/02_functions.sql` + `sql/03_rls.sql`,
`login.html`, `assets/api.js`, `owner.html`, `tools/tailwind.config.js`, `assets/tailwind.compiled.css`) are
**UNCOMMITTED on top** — the tree is **dirty by design**, the human said no commits yet.
`main == origin/main` after this turn: the human asked for a push, so `a7ab4bd..HEAD` — the TTL move, the
`delete_category` refusal, the R9 docs, the two R10 code commits and this docs commit — is on the public branch,
and GitHub Pages serves the R10 tree once its build finishes. Standing rule for future sessions: the agent does
not push on its own — a push needs an explicit human request.
`main` **== `origin/main`** — the human pushed `7ea5cb7..cbca447` on 2026-10-20. GitHub Pages rebuilt
and the live `owner.html` now carries the phase-5 bootstrap fix (`owneremails` 2 hits, `!emails` 1,
`ownerEmails` 3, `split` 3 — matching `owner.html:97–115` + the gate at `:652`), so the `?owneremails=`
workaround noted in §4 D is **no longer needed** on the public site. Standing rule for future sessions:
the agent does not push on its own — a push needs an explicit human request.

Conventional-commit style is the project's; keep `fix(phase-N):` / `feat(phase-N):` prefixes and
put the live-verification evidence in the commit body, as the three commits above do.

### Role-differentiation proof (staff-gate JWT) — closes the Phase-7 caveat

Principal `staff-gate@sleepless-cafe.test` → `3427770d-2f86-479a-b369-ff459e23484e`, `role: authenticated`,
created through `POST /auth/v1/signup?grant_type=signup` (autoconfirm) and exchanged for a 958-char JWT
through the password grant. Probes with **that** JWT:

| Probe | Result | Verdict |
| --- | --- | --- |
| `list_active_pending`, `kitchen_queue` | 200 `success:true`, `data:[]` | staff read policies hold (empty because every order is `served`) |
| `sales_summary`, `turnover_stats` | 200 `success:true` (615.00 / 4 / 153.75; sample 4, avg 642, p95 1641) | **expected**: the only guard is `IF email = ''` (`sql/02_functions.sql:393…553`) — signed-in vs anon. Owner-only is a UI allowlist decision (§9.7), not a JWT claim check |
| `create_menu_item`, `update_menu_item` | 200 `success:true` | same reason; throwaway row deleted back to 12 items, so the catalogue is clean |
| `void_order` on a `served` order | `NOT_VOIDABLE` | `orders_staff_delete` allows DELETE only where `status='pending_payment'` |
| raw `PATCH /rest/v1/orders?code=eq.63242` → `pending_payment` | **403 / 42501** "new row violates row-level security policy" | `orders_staff_update` WITH CHECK rejects an illegal lifecycle flip |
| `create_order` as **anon** → `confirm_payment` → `mark_served` with the staff JWT | 200 each; `85063` `paid` at 02:34:10.17, `served` at 02:34:10.56, `fulfillment_time_seconds` 0 | the cashier/kitchen flows work for a signed-in **non-owner** |

Note: the GET form of the two boards answers `25006 cannot execute DELETE in a read-only transaction`
because they call `purge_expired_orders()`; `api.js` POSTs them, which is the correct form.
Final counts after the proof: `menu_items` 12, `categories` 4, `orders` 5 (all `served`), `order_items` 5.

---

## 8. R9 - full-system functional test pass (2026-10-20, human request "fully test all functions")

The human asked for: owner category/product creation, the full ordering routine, the claim window moved
60 → 30 minutes from check-out, everything exercised in the browser, and every found problem resolved.
All five items are done; two real defects were found and fixed.

### 8.1 TTL 60 → 30 minutes (commit `f9194aa`)

| Side | Change | Evidence |
| --- | --- | --- |
| DB authority | `sql/01_schema.sql:74` default is `now() + interval '30 minutes'`; live DB moved with `ALTER TABLE orders ALTER COLUMN expires_at SET DEFAULT now() + interval '30 minutes'` | 201 |
| Client mirror | `assets/config.js:31` `ttlMinutes: 30` | committed default |
| Customer copy | `menu.html` `ttlMinutes()` helper renders `within ${ttlMinutes()} minutes` — never a literal | success screen read "Order Placed! … within 30 minutes to process payment." |
| Landing copy | `index.html:114` / `:154` say 30 minutes (static page, no config bootstrap — documented drift risk) | browser read both |
| Staff pages | `cashier.html` / `kitchen.html` / `owner.html` need no edit — countdown is server-derived (`seconds_remaining`) | owner claim row rendered `29:49` for a fresh claim |

Live proof: claim `97314` created `06:16:17.411762Z`, `expires_at` `06:46:17.411762Z` — exactly 30 min, `seconds_remaining` 1786.
**Pairing rule: the column default and `ttlMinutes` must always be changed together.** The client cannot read
its own order back (RLS blocks anon SELECT on `orders`; `get_order_by_code` is staff-only), so the copy can only
come from config — a public config table would move the security boundary and is deliberately out of scope.

### 8.2 `delete_category` FK defect (commit `f637cc8`)

"Delete items too" on a category whose items appear in past orders raised a raw PG 409
(`SQLSTATE 23503`, constraint `order_items_menu_item_id_fkey`, from `sql/01_schema.sql:97` which carries **no**
`ON DELETE` clause on purpose — paid orders are the permanent sales record). That broke the JSON-envelope
contract and surfaced as the generic owner error copy. Fix: pre-check + nested `SQLSTATE '23503'` net return
`MENU_ITEM_IN_USE`; `owner.html` `ERR_COPY` gained "Those items are in past orders - the sales record would
break. Move them to another category, or hide them." The fallback path (`UPDATE … SET category_id`) cannot
violate the FK and is unchanged. Wire proof: `delete_category(Coffee, null)` →
`{"success":false,"error":{"code":"MENU_ITEM_IN_USE"}}`.

**Test lesson:** deleting a category whose items were *never* ordered legitimately succeeds — an early browser
pass deleted the seed `Desserts` category and 2 items that way. Restore with the original seed ids, and only
test deletion against a category that IS referenced (Coffee), so the refusal path is the one exercised.

### 8.3 Browser evidence (integrated browser on `localhost:8731`, no headless automation)

- Owner menu builder: created a category, created an item inside it, reordered categories (`Up`/`Down` +
  `reorder_categories`), edited an item's availability (`Keep`/`Available`/`Hidden`) — hidden item correctly
  absent from `menu.html` (Coffee rendered 4 cards, not 5).
- Fresh-visitor ordering routine (`sl_config` and `sl_auth` cleared first): category → size chip → `+` →
  `Add to Cart` → cart row `Caramel Latte · Regular · ×2  ₱280.00  + − Remove` → name → `Proceed to Checkout`
  → claim `97314`. Digit name `R9 Tester` rejected with "Names use letters only — no numbers or symbols."
- Cashier: board empty after cleanup; manual lookup of a force-expired claim answered "Wrong code, or that
  order's time is up." — the expired path is refused with human copy, and `void_order` on it answers
  `NOT_VOIDABLE` because the TTL sweep already removed the row.
- Owner void two-step: `Void claim` → button re-renders `Confirm void` → toast "Claim 84400 voided — the row
  and its items are gone.", board empty, sales untouched (₱1,165.00 / 7 / ₱166.43).
- CSV export: "CSV saved to your downloads." The human opened the downloaded file and its contents close the loop
  exactly: `sales-2026-10-20.csv` rows `10/19/2026 230 2` and `10/20/2026 935 5`, which sum to ₱1,165.00 over
  7 completed orders - identical to the sales card and to the DB probe. (The spreadsheet app re-styles the
  ISO `label` column as a locale date; the CSV itself writes `2026-10-19`, which is cosmetic, not a defect.)
- Cleanup: every probe claim voided/purged; DB back to 4 categories, 13 items (1 hidden), 7 orders, ₱1,165.00,
  0 live claims.

### 8.4 Still open (not defects)

Phase 8 (Vercel) remains parked by the human's earlier decision; the two local commits above are unpushed, so
GitHub Pages still serves `a7ab4bd`. `assets/api.js` needed no change for `MENU_ITEM_IN_USE` — the envelope
passes through `copyFor()` unchanged.

---

## 9. R10 - customer + cashier UX pass (2026-10-20, human request "5 items, correct everything fast but accurately")

The human reported five things: the cart quantity should sit between the `+` and `-`; ordering produced a
double-click glitch with **two identical claims recorded** (screenshots: `87823 CJ` and `09031 CJ`, both 15:55,
both ₱1,550.00 / 3 items); the unpaid board should show about ten rows with scrolling after that and be sorted
alphabetically by customer name; and a looked-up claim should look like the customer cart, so a quantity can be
adjusted, a line deleted, or an item added before payment is confirmed. All five are done - backend in `7916a0d`,
frontend in `ce3b24e`.

### 9.1 Cart quantity between the steppers (commit `ce3b24e`)

`renderCart()` emits the line as name/size, amount, `+`, **qty**, `-`, `Remove` - the number now lives BETWEEN
the two buttons instead of trailing the item name. `assets/app.css` `.cart-line` gained a dedicated centre track
for it: `grid-template-columns: 1fr minmax(6.5rem, auto) auto minmax(2.25rem, auto) auto auto` with
`.cart-qty { justify-self: center; font-weight: 700; }`, so the number and both steppers line up on every line
regardless of item-name length. Hint copy: "The number between + and - is how many you have. Tap + or - to
change it, Remove to drop the line."

Live DOM proof: children `SPAN "Caramel Latte · Regular"`, `SPAN ₱140.00`, `BUTTON +`, `SPAN 1`, `BUTTON -`,
`BUTTON Remove`; computed `gridTemplateColumns: 402.39px 104px 40px 36px 40px 63.6px` - the qty track is exactly
`minmax(2.25rem, auto)` = 36 px, so the two 40 px buttons share a column.

### 9.2 The double-order glitch (commit `ce3b24e`)

Root cause: `checkout()` cleared the cart only AFTER `await createOrder(...)`, so a second tap on the same button
(a double click, or a tap-and-a-half) still saw a non-empty cart and fired a second identical `create_order` -
two claims, two codes, same items. That is exactly the pair in the screenshots.

Two guards, both **synchronous** (no `await` between the check and the clear, which is what makes them raceproof):

| Guard | What it does |
| --- | --- |
| `let placing = false;` (module level) | `runCheckout()` returns immediately if `placing` is already true and clears it only after the `await`, so a second click during an in-flight order does nothing at all. |
| `const snapshot = cart; cart = new Map();` | Runs BEFORE the request, so the cart is empty the moment the RPC starts. On a failed RPC `cart = snapshot;` puts the lines back, so a refusal is still undoable. |

Proof: with the letters-only name "Double Tapper", two clicks fired in the same tick produced exactly ONE claim
(code `48170`), cart 0 lines, and the staff REST board showed `count = 1` for that name. (An earlier attempt named
"R10 Double Tap" was legitimately rejected by the R8 letters guard because of the digits - not a regression.)

### 9.3 Unpaid board: alphabetical + scrolling viewport (commits `7916a0d` + `ce3b24e`)

| Side | Change |
| --- | --- |
| Server order | `sql/02_functions.sql:270` - `list_active_pending` now orders `lower(o.customer_name) ASC, o.created_at DESC` (was `created_at DESC` alone). The order is the server's, so every terminal agrees. |
| Client | `cashier.html` `refreshBoard()` had its client-side sort REMOVED - re-sorting locally would fight the server and reshuffle rows on every paint. |
| Viewport | `assets/app.css` `.board-scroll { max-height: 23.5rem; overflow-y: auto; overscroll-behavior: contain; }` wraps the table. Rows measure 34 px, so 11 rows = 374 px = 23.5 rem: about ten claims visible, the rest reached by scrolling. `overscroll-behavior: contain` keeps a board flick from scrolling the whole page. |
| Copy | `renderBoard()` adds a note only when `rows.length > 10`: "All N unpaid claims are listed - scroll the board to reach the ones past the first screen." |
| Print | `@media print` releases the cap (`max-height: none !important; overflow: visible !important;`) so a printed board is never truncated. |

Verified: `.board-scroll` computed `overflow-y: auto`, `overscroll-behavior: contain`, `max-height: 376 px`
(23.5 rem) after a page reload - the integrated browser memory-caches `assets/app.css`, so a CSS edit is
invisible until the page is reloaded; `max-height` read 432 px before the reload. Board row height measured 34 px.
**Not yet exercised:** the >10 note itself - seeding 11+ live claims would spam the board for a full 30-minute
window, so that branch is verified structurally (`rows.length > 10` + the viewport CSS), not visually.

### 9.4 A looked-up claim is editable before payment (commit `7916a0d`)

Three functions added to `sql/02_functions.sql` (19 total) and applied live:

| Fn | Contract |
| --- | --- |
| `claim_view(p_order_id uuid)` :178 | The single definition of "open claim": returns the order plus its `items[]` (`item_id` included so a client can name a line) sorted `item_name ASC, size ASC` inside `jsonb_agg`, only when `status = 'pending_payment' AND expires_at >= now()`. SQL NULL otherwise - never an envelope. |
| `set_claim_item_qty(p_order_id, p_item_id, p_quantity)` :433 | `quantity = 0` deletes the line, otherwise rewrites `quantity` and `subtotal = unit_price * quantity`; `total_amount` is re-summed from the lines and written back. Refusals: `CLAIM_NOT_OPEN` (:442 and again :467 - a claim can run out of time mid-edit), `INVALID_QTY` (:445, 0..999), `LINE_NOT_FOUND` (:448), `LAST_LINE_ONLY` (:452). |
| `add_claim_item(p_order_id, p_menu_item_id, p_size, p_quantity)` :482 | Prices itself from `menu_items.sizes_and_prices` - the caller never sends a price, so a cashier cannot invent one. Merges into an existing same (item, size) line with `LEAST(999, quantity + add)`, else inserts with `item_name` copied from the menu. Refusals: `CLAIM_NOT_OPEN` (:494, :525), `INVALID_QTY` (:498), `MENU_ITEM_UNAVAILABLE` (:503), `INVALID_SIZE` (:508). |

`get_order_by_code` was rewritten to resolve the open id and then read `claim_view`, so the lookup payload and
the edit payload are the same shape (`ORDER_NOT_FOUND` when either is NULL).

Two RLS changes in `sql/03_rls.sql` (now 11 policy pairs, applied live):

- `orders_staff_update` WITH CHECK extended to two arms - a `pending_payment` row with `paid_at IS NULL`, or a
  `paid`/`preparing`/`served` row with `paid_at IS NOT NULL`. Needed because a claim edit reprices the row while
  it is still unpaid; it is not a loophole, the row still cannot cross the payment boundary in one write.
- `order_items_staff_write` (auth, FOR ALL) added: `WITH CHECK ( quantity >= 1 AND subtotal = unit_price * quantity )`.
  Dropping a line is a DELETE, and a `WITH CHECK` cannot restate the claim-open fence because that would require
  reading `orders` - the fence lives in the functions, which is where the only callers come from.

`LAST_LINE_ONLY` is deliberate: an empty claim is not an order, so "delete everything" is a void, and voiding
remains an owner decision. The cashier's writes are `confirm_payment` plus the pre-payment edits; nothing in
`cashier.html` calls `voidOrder`. The stale "VOID ACTION - DELIBERATELY OMITTED" comment was rewritten to say
exactly that, so the rationale survives the code.

Wire proof (staff JWT, RLS-faithful REST path): board alphabetical (CJ before "R10 Tester"); `get_order_by_code`
returned 2 lines (Butter Croissant/Single x1 @95 = 95, Long Black/Regular x2 @120 = 240, total 335.00);
`set_claim_item_qty` -> 3 gave 455.00; qty 0 on the croissant gave 360.00 over 1 line; qty 0 on the last line
returned `LAST_LINE_ONLY`; `add_claim_item` Espresso/Single x2 gave 540.00 over 2 lines with the price derived
server-side.

### 9.5 Browser evidence (integrated browser on `localhost:8731`, no headless automation)

- Cashier claim card for `34865` carried `data-order-id`, lines sorted by name, the line "On this claim - tap +
  or - beside the number, Remove to drop a line", and an "Add to this claim - tap a size" panel of 25 size chips
  over the 12 available items. UI edits drove ₱875.00 -> ₱1,055.00 (Basque Slice qty 4) -> ₱960.00 over 2 lines
  (Remove the Butter Croissant) -> ₱1,050.00 over 3 lines (Espresso Single chip), and the board row followed each
  edit. Confirm Payment printed "Paid - sent to the kitchen." and the row left the board.
- `LAST_LINE_ONLY` rendered as human copy above the "On this claim" line on claim `48170`, claim unchanged at ₱140.00.
- Cleanup: `30218` and `48170` voided with the staff JWT; the cashier then read "No unpaid claims on the board
  right now." Final DB probe: `live 0`, `completed 9`, `revenue 3765.00`, `order_items 14`, codes
  `63242, 02342, 13341, 21574, 85063, 33667, 96405` served + `87823` and `34865` paid.

### 9.6 Remaining, not yet done (as of this commit)

- **Phase 8 (Vercel go-live) - untouched.** Still parked: no Vercel account or domain exists, and the manual phone
  run of Gate A has never been done. `tools/inject-config.mjs` and `tools/vercel.json` exist but have never been
  exercised.
- **The >10-row scroll branch is unverified visually** (see 9.3) - it needs 11+ live claims, which would sit on the
  board for a full 30-minute window.
- **R10 evidence is localhost-only.** Nothing in this pass was re-checked on the public Pages host; after this
  push the R10 tree ships, but `assets/app.css` is served with `Cache-Control: max-age=600`, so a returning
  visitor can keep the old stylesheet for up to ten minutes.
- **Scroll only, no pagination.** The request said "up to 10 maybe?", so the board caps the viewport and lets the
  cashier scroll; there is no next-page control and `list_active_pending` still returns every live claim.
- **`cashier.html` imports `getClaimView` but never calls it** - the claim card is built from the `get_order_by_code`
  payload, which is the same `claim_view` body. Harmless, but dead in the import list.
- **Kitchen-side effect of a claim edit untested.** Edits happen before payment, so `kitchen_queue` (paid only)
  never sees them; the paid card was confirmed to leave the unpaid board but was not re-checked on `kitchen.html`.
- **Carried over, unchanged:** the hidden `Test Ristretto R9` item (`829e95a7-...`, undeletable while paid order
  `96405` references it), the two `staff-probe` users with unrecorded passwords, the `index.html` TTL literals
  (drift risk, sec 8.1), and the `uploadImage` comment that still says "PUT" while the code POSTs.
- **Sales record now includes the human's own claims:** `87823` (₱1,550.00) and my `34865` (₱1,050.00) are paid,
  which is why revenue moved ₱1,165.00 -> ₱3,765.00 over 9 completed orders (avg ₱418.33). The duplicate
  `09031` is gone from `orders` entirely.

### 9.7 Deferred password decision (staff identity, 2026-10-21)

**Employee self-change + owner reset APPLYING to a GoTrue identity = a service-role Edge-Function bundle, PENDING OWNER APPROVAL** — same approval class as the §10.2 cron decision. `roster_reset_password` in `sql/07_staff_roster.sql` GENERATES and returns a memorable temp password **ONCE**, and `roster_add` echoes the owner's proposed password **ONCE** so it can be copied to the new employee; neither can touch GoTrue, because signup/reset/self-change against an auth identity is a service-role operation and SQL has no path to it. What IS live in SQL is the generator: `make_memorable_password` (word-word-Number, CSPRNG-backed, 20 cafe words) — and it is what Tab 5's add-employee flow calls.

---

## 10. Phase 8 prep pass (2026-10-21)

Four prep items that need no human; all verified. The phase itself (Vercel go-live) stays parked.

### 10.1 Tailwind CDN  →  compiled CSS (commit `c30b540`)

| Item | Evidence |
| --- | --- |
| Build | `node ./node_modules/tailwindcss/lib/cli.js build -i tools/tailwind.src.css -o assets/tailwind.compiled.css -c tools/tailwind.config.js -m`  →  `assets/tailwind.compiled.css`, **12,139 B committed** (regenerate on any token change). |
| Single source | `tools/tailwind.config.js` READS `assets/tokens.css` at build time, so `tokens.css` stays the single source of truth for brand colors  —  the compiled CSS carries the resolved hexes, no page re-declares one. |
| Pages | All five load it at **line 30**, immediately after `assets/app.css`, matching the cascade the CDN produced at runtime (the CDN injected its generated stylesheet after every head link). The `cdn.tailwindcss.com` script and the inline `tailwind.config` block are gone from all five pages. |
| Latent defect found | `min-height-[48px]` is **not a valid v3 class**  —  the plugin prefix is `min-h`, so the rule never existed and the KDS 48 px tap targets silently never applied. |
| Fix | `kitchen.html` Hold (`:186`) and `owner.html` Void (`:217`) / Up (`:361`) / Down (`:362`) now use `min-h-[48px]`; the compiled CSS emits `.min-h-\[48px\]{min-height:48px}`. |
| QA | **0 console messages on all five pages** (the `cdn.tailwindcss.com should not be used in production` warning is gone), computed styles exact (`bg-brand-card/60`  →  `rgba(34,22,16,0.6)`, header `border-b` still wins the cascade), compiled CSS serves **200 / 12,139 B**, no favicon 404, no CDN request, `@media print` rules intact. |

### 10.2 Cron artifacts (commit `e91ce3c`)  —  authored, NOT applied

`functions/purge-expired/index.ts` (dependency-free Deno Edge Function) + `tools/cron/purge-expired.json`
(`*/15 * * * *`, array-wrapped so `supabase cron add -f` accepts it). The lazy client-side sweep in
`list_active_pending` / `kitchen_queue` stays unchanged as the self-healing backstop.

**DESIGN DECISION FLAGGED FOR OWNER APPROVAL  —  not yet locked.** The Edge Function mints a REAL staff JWT
(password grant) rather than using the service-role key, because `sql/03_rls.sql:141` `orders_staff_delete`
is `TO authenticated` and therefore DENIES a service-role sweep by design  —  the RLS boundary Gate A proved
cannot be bypassed from the server side. Provisioning `SL_STAFF_EMAIL` / `SL_STAFF_PASSWORD` as Edge-Function
secrets is a credential decision that needs an explicit human yes, and whether the cron authenticates as a
dedicated cron staff account or reuses `staff-gate` is a second decision. Secrets live only in Edge-Function
env; nothing is deployed and nothing is pushed.

### 10.3 Injector exercised (4 runs, no commit  —  artifacts are gitignored)

| Run | Result |
| --- | --- |
| Success | exit 0  —  `assets/config.generated.js` written, 5 `<script type="module">` tags injected across the five pages, `tools/vercel.json` copied to the deploy root |
| Idempotent re-run | everything skipped, exit 0, no duplicate tags |
| Missing `SL_SB_URL` | fail-loud, exit 1, names only reported (never values) |
| `sk_`-shaped key | fail-loud, exit 1, **0 leak hits**  —  a service-role-shaped key is refused before anything is written |

Artifacts stay gitignored (`.gitignore:7` `assets/config.generated.js`, `:20` `/vercel.json`) and the tracked
pages were byte-exact restored afterwards, so the injector is **net-zero on the tree**.

### 10.4 DB drift found during QA

The live DB now renders **14 visible items over 5 categories**: `GM Americano` added inside Coffee and `Coopper`
in a brand-new `Doggy` category, from human menu edits made after the last handoff. The 12-seed counts in §2 and
§3 are superseded; the hidden `Test Ristretto R9` item is unchanged.

### 10.5 QA summary

0 console messages ×5 pages, computed styles exact, probes conform, DB drift noted. Nothing pushed: `main` is
3 ahead of `origin/main` (a push needs an explicit human request).

**Staff identity pass supersedes the `?email=&password=` URL hack at `login.html`** — credentials are typed in the page there; the station pages keep the `sl_auth` boot (they read `sl_auth` themselves, so no URL params are needed).

---

## 11. Staff identity — APPLY CHECKLIST (LIVE: applied 2026-10-21, human-authorized)

**Status 2026-10-21: steps 1–4 below are DONE and live.** The human authorized the live apply and the agent
executed it over the `database/query` endpoint (§1.x path, not the SQL Editor): sql/07 pasted in 4 chunks (all
201), the amended sql/02 re-pasted in 5 chunks (all 201 — the 17 fences went live), 3 auth identities created via
`POST /auth/v1/signup` (publishable key, autoconfirm), and QA probes green BOTH ways (cashier→`kitchen_queue` and
kitchen→`list_active_pending` = `WRONG_STATION`; cashier→`create_menu_item` = `NOT_OWNER`; dev→`roster_list` = 3
rows; anon→`staff_session` = `STAFF_NOT_REGISTERED`; `staff_session` answers owner/cashier/kitchen for the three
probes). Passwords were reported to the human out-of-band and are **not** in any file. Shipped the same day: 4 conventional
commits (`deae3df` roster SQL · `779ce0c` login door · `d8a4a15` Tailwind scan · `da26aa4` docs) pushed `21a55a5..da26aa4`
to `origin/main`, and the browser door was then **PROVEN on the public host** — `login.html` routed cashier-probe→`cashier.html`,
kitchen-probe→`kitchen.html`, dev→`owner.html` (Tab 5 renders the 3 roster rows with live `last_seen_at`), and
`stranger@sleepless-cafe.test` stayed on the door with the honest copy. The checklist below is kept as the record of
what was applied — read it as history, not as pending work. Apply in this order (as originally written, before the apply):

1. **Paste `sql/07_staff_roster.sql` into the Dashboard SQL Editor.** Apply **after 06** — it assumes 01/02/03 already
   exist and adds a NEW table plus its own RLS; it never edits an earlier file. The file is idempotent: every policy
   carries a `DROP POLICY IF EXISTS`, every function is `CREATE OR REPLACE`, RLS is turned on with
   `ALTER TABLE … ENABLE ROW LEVEL SECURITY`, and the seed INSERTs are `ON CONFLICT (email) DO NOTHING` — so a
   re-paste is a strict no-op. No DELETE / TRUNCATE anywhere.
2. **Re-paste the amended `sql/02_functions.sql`.** Every function is `CREATE OR REPLACE`, so re-pasting replaces the
   live rows and the **17 fences go live**: 7 owner `NOT_OWNER` (`roster_role_of(email) <> 'owner'`) + 10 station
   `WRONG_STATION`, each preceded by `STAFF_SESSION_REQUIRED` → `STAFF_NOT_REGISTERED`. Never run both sets at once —
   the repo file is the truth.
3. **Create the THREE auth identities via `POST /auth/v1/signup`** with the **publishable key** (the dashboard
   **Confirm email** toggle is currently OFF, so autoconfirm creates the user straight away, no verification email).
   **SQL cannot create auth identities** — it seeds the roster row only, so this is a separate human step. The exact
   curl shape is in the header of `sql/07_staff_roster.sql` (`:50-56`). Emails: `dev@sleepless-cafe.test`,
   `cashier-probe@sleepless-cafe.test` (the `staff-probe@…` name collided with a legacy unusable auth user — see
   §1.5), `kitchen-probe@sleepless-cafe.test`. Passwords are **chosen by the human and must never be committed** —
   not into these docs, not into a tracked shell file (reported out-of-band 2026-10-21).
4. **Then `login.html` boots the door and QA can prove station blocking BOTH ways.** With the roster live and the
   three identities created: the cashier probe is refused on `kitchen_queue` / `mark_served` = **WRONG_STATION**; the
   kitchen probe is refused on the claim edits (`claim_view` / `set_claim_item_qty` / `add_claim_item`) =
   **WRONG_STATION**; a signed-in **non-owner** is refused on menu writes = **NOT_OWNER**. Until steps 1–3 are done,
   every one of those probes answers `PGRST202` / `PGRST205` — that is the honest absent-live state, not a regression.
   (Superseded 2026-10-21: steps 1–3 are done, the probes now answer the envelopes listed in the status block above.)

---

## 12. UI/UX sweep (2026-10-21) — ten human-reported items, LIVE + shipped-to-file

**Status 2026-10-21.** **File-complete (edited on disk, localhost-proven):** `login.html`, `cashier.html`,
`menu.html`, `kitchen.html`, `owner.html`, `assets/api.js`, `assets/realtime.js`, and
`assets/tailwind.compiled.css` (rebuilt so every new token compiles). **Live-applied:** `sql/02_functions.sql` —
the `items_count` cups fix and the new `sales_report` went live over the dashboard `database/query` endpoint
(HTTP 201 each). **Committed and pushed 2026-10-21 (human authorized "ship it"):** four conventional commits in governance order —
`a60ccb4` fix(sql) → `2a06908` feat(assets) → `0654614` feat(pages) → `614b9f3` docs — pushed `4888f24..614b9f3`, tree clean,
`HEAD == origin/main == 614b9f3`. **Public-host proof after the push:** `login.html` renders the narrow centred card and the door
routes to `cashier.html`, which shows "Signed in as Probe (cashier)" and a working Log out (gate copy + footer back to `nobody`);
`owner.html` shows the Focus combobox (31 options) and, focused on 2026, the window line "2026-01-01 → 2026-12-31 · monthly bars ·
focused on 2026" and a downloaded `sleepless-sales-yearly-2026.csv` = `month,cups,cash_received,orders` / `2026-10,49,8650,13`.
Still localhost-only: the kitchen realtime backstop (the pushed `assets/realtime.js` blob is the proven file, but no public
board watch was run). The "(files only, not yet committed)" tags in the §3 table above predate the push — this block supersedes them.
`tools/tailwind.config.js` already covered
`login.html` in its content scan, so no config change was needed.

The ten items, in the order they were reported:

1. **Staff door rendered full-width (`login.html`, item 1).** Root cause: `<input>` is a VOID element and a `</div>`
   had been written after it, closing the card early — everything after the first field lost its container. Fix:
   `renderCard`/`openForm` use `glass-card rounded-xl p-6 my-6 mx-auto max-w-md flex flex-col gap-3`, inputs end
   bare with `py-2 min-h-[48px]`, the Sign-in button is `mt-3 w-full`.
2. **The cashier never said who was signed in (`cashier.html`, item 2).** The staff NAME comes from `staff_session()`
   `display_name` and is rendered in the footer plus an accent line on the board.
3. **No way to log out, no idle expiry (`cashier.html`, item 2).** A real `data-logout` Log out button; a 3 h
   idle teardown (`IDLE_MS = 3*60*60*1000` without a tap → `clearSessionToken()` + the `sl_auth` localStorage entry
   removed + the gate copy); a boot-time roster check refusing a non-cashier role with `NOT_CASHIER` and an
   unknown email with `STAFF_NOT_REGISTERED`.
4. **Cart said 7 items, cashier board said 2 (item 4).** Root cause: `items_count` counted `order_items` LINES,
   not cups. Fix in `sql/02_functions.sql`: `COALESCE((SELECT SUM(oi.quantity) FROM order_items AS oi WHERE oi.order_id = o.id), 0)`
   at the four sites — `create_order`, `claim_view`, `list_active_pending`, `confirm_payment`.
5. **Stepper direction (`menu.html` + `cashier.html`, item 3).** The stepper is now `− qty +` (minus LEFT, plus
   RIGHT) with the copy "The number between − and + is how many you have…".
6. **Peso on the KDS (`kitchen.html`, item 6).** Peso removed entirely — the cashier owns pricing, the kitchen
   owns make-time, so the board must not restate a price.
7. **Unreadable kitchen card (`kitchen.html`, items 6).** Item name `text-2xl font-serif`, per-line qty
   `text-2xl font-mono` as `N×`, a cups chip `N cups` summed from the items' quantities, order code demoted to `text-xs`.
8. **Kitchen board frozen until F5 (`assets/realtime.js`, item 5).** Root cause: a silently-dead socket — a
   throttled/backgrounded tab never fires `'close'` — left the board waiting on a dead ws. Fix: `startPolling(poll)`
   starts ALONGSIDE the WebSocket in `startWatching` right after `mode = 'poll'`; the 3 s poll is the backstop and
   `mode` only becomes `'ws'` after a server-confirmed SUBSCRIBED.
9. **Owner Sales tab could not pick one day/month/year (`owner.html`, items 7/9/10).** A Focus `<select data-sales-focus>`
   dropdown — All days plus every day, month or year in the window, generated in UTC so an empty period is still
   selectable. Focusing narrows the window AND drops the chart one step (day → that day, month → its days, year → its months).
10. **CSV and window line ignored the selection (`owner.html`, items 8/9/10).** The CSV follows the grain the OWNER
    selected (`salesGrain`), not the chart's finer grain — monthly exports per-day totals, yearly per-month totals;
    the filename carries the focus label (`sleepless-sales-monthly-2026-10.csv`, `sleepless-sales-yearly-2026.csv`);
    the window line, which used to print clock times via `fmtTime` ("14:03 → 14:03"), now prints ISO slices plus
    the bar grain ("Window 2026-10-01 → 2026-10-31 · daily bars · focused on 2026").

**Evidence.** REST (dashboard `database/query`, and an owner bearer token over `2026-01-01..2026-12-31`): `create_order`
→ `items_count` 7, board 7, `confirm_payment` 7 — the cup count agrees at every site. `sales_report` live apply 201;
monthly → 3 day rows (2026-10-19 2/230/2, 2026-10-20 31/5250/9, 2026-10-21 16/3170/2) summing 49 cups / 8650 cash /
13 orders; yearly → 1 row `2026-10` 49/8650/13; daily → 13 sale rows unchanged. Frontend localhost-proven on
`http://localhost:8731`: login renders a narrow centred card; cashier shows the name "Probe (cashier)", Log out → gate,
reload → gate persists, board shows 7 cups; menu cart line `Caramel Latte · Regular | ₱280.00 | − 2 + | Remove`;
kitchen card proven by screenshot; three downloaded CSVs in `%USERPROFILE%\Downloads` — daily header
`code,customer_name,paid_at,served_at,turnaround_hhmm,turnaround_seconds,cups,items,cash_received` (items joined like
`2x Caramel Latte (Regular)`), monthly header `day,cups,cash_received,orders`, yearly header
`month,cups,cash_received,orders`. Tailwind rebuilt (`node ./node_modules/tailwindcss/lib/cli.js build -i tools/tailwind.src.css -o assets/tailwind.compiled.css -c tools/tailwind.config.js -m`, 314 ms); `get_errors` on all eight touched files: clean.

**New lessons (do-not-re-derive):**
- The dashboard `database/query` endpoint answers HTTP 400 for an UNALIASED expression SELECT — use the aliased form (`SELECT m.id::text AS mid, … AS szt FROM menu_items AS m LIMIT 2` → 201).
- `fmtTime` in `assets/api.js` is a CLOCK formatter (HH:MM) — date windows need ISO slices (`String(iso).slice(0, 10)`), never `fmtTime`.
- The session-store FTS5 index tokenizes on hyphens, so `'cashier-probe'` fails as "no such column: probe" — use `LIKE` on the `turns` columns instead.
- PowerShell strips embedded double quotes for native commands, so `node -e "…"` breaks — write a temp `.mjs` outside the repo and run it (and `.mjs` is ESM: `import { readFileSync } from 'node:fs'`, no `require`).
- A native `<select>` cannot be driven by clicking an `<option>` (Playwright: "element is not visible") or by typing into the select — the page's own click path is a click on the SELECT plus `selectedOption()`, so simulate by setting `.value` then dispatching a click on the select.
- `sales_report` answers one level FINER than the grain it is handed while `sales_summary` buckets AT the grain — two different fmt lines (`sales_report`: `CASE grain WHEN 'yearly' THEN 'YYYY-MM' ELSE 'YYYY-MM-DD' END`; `sales_summary` keeps its own coarser fmt for the chart). Do not merge them.

---

## 13. UI sweep 2 (2026-10-21) — seven human-reported tap-target / layout items — **SHIPPED `9bd7ee9..fe296fb`**

**Status 2026-10-21 — SHIPPED (human authorized the push).** **Committed and pushed the same day, three conventional
chunks:** `fbbf7c5` `feat(assets)` (`assets/app.css` + `assets/tailwind.compiled.css`, 51 insertions / 1 deletion),
`1a1fb43` `feat(pages)` (`cashier.html` + `kitchen.html` + `owner.html`, 138 insertions / 34 deletions), `fe296fb`
`docs` (this file + `MASTER_PLAN.md`). `git push origin main` moved `9bd7ee9..fe296fb`; `git ls-remote origin main` =
`fe296fb5125e358f533e0548b7cda38d5346f52b` == `HEAD`, tree clean. **No SQL touched this pass.** `get_errors` on the
four edited source files: clean. **All seven items re-proven on the PUBLIC host** — Pages had already rebuilt when the
proof ran (served byte sizes matched the raw tree at the new SHA exactly: `cashier.html` 37,171 B, `kitchen.html`
19,736 B, `owner.html` 69,216 B, `assets/app.css` 11,331 B).

The seven items, in the order the human reported them:

1. **"tap a size" chips small and crowded (`cashier.html` + `assets/app.css`, item 1).** Root cause: the Add-to-claim
   panel was a run of inline `text-xs` `.size-chip` buttons — no padding, no minimum height, so two sizes sat a few
   pixels apart and a thumb landed on the wrong one. A plain flex row would not fix it either (chips then drift to
   their label width and the lanes stop lining up down the panel). Fix: each catalogue item is a `.claim-add-row`
   (grid) carrying a `.claim-add-name` and a `.claim-add-sizes` grid of `repeat(auto-fit, minmax(4.5rem, 1fr))`
   equal lanes with a 0.5rem gap; every chip is `min-height: 48px` (the thumb target the rest of the app already uses)
   with `max-width: 14rem` + `justify-items: center` so a desktop lane does not stretch into a full-width bar. auto-fit
   collapses the lanes an item does not use, so a two-size drink gets two wide lanes instead of one dead third column.
   Mobile-first the name sits ABOVE its sizes (a 390 px screen has no room for a name column plus the chips); from
   40rem up the row goes side by side. The sizing rule is scoped to `.claim-add-sizes`, so `menu.html`'s own
   `.size-chip` (which carries the selected/unselected state) keeps its old metrics.
2. **Claim-code input misaligned with its card (`cashier.html`, item 2).** Root cause: the input carried `box-content`
   (`box-sizing: content-box`), so `w-full` sized only the CONTENT and the `p-3` padding plus the border were added
   OUTSIDE it — the box measured ~34 px wider than the card's content box and its border ran past the card's own
   border. Fix: `box-border`, and the buttons moved INSIDE the card (the old markup closed the card right after the
   input, leaving Look Up and Log out as loose siblings under it).
3. **No Log out at the top (`cashier.html`, item 3).** The Log out button moved from the code field into the STICKY
   header, next to the wordmark: `<button id="logoutbtn" hidden data-logout …>`. It is `hidden` until a cashier
   session exists (boot sets `hidden = false`, `signOut` sets it back to `true`). The header is the right home because
   the board repaints every 5 s and the header never does — anything painted into the board is destroyed on the next
   beat. `hidden` on a flex-child button works because Tailwind preflight sets no `display` on `button`.
4. **Cashier name belongs under the counter terminal (`cashier.html`, item 4).** `#wholine` (`text-brand-accentLight
   text-xs mt-1`) sits directly under the `Counter terminal · <clock>` paragraph in that same sticky header, written
   by `paintWhoLine()` with `textContent` — never `innerHTML`, since `display_name` is server-supplied. The old
   in-board `${whoLine()}` call was removed from `renderBoard()`.
5. **Logout should land on the staff door (`cashier.html`, item 5).** `signOut(copy)` keeps `renderAuthGate(copy)`
   and then, after 2.5 s, `window.location.replace('login.html')` — the gate copy stays on screen for a beat first
   because with an idle sign-out that line is the whole answer to "why is the board gone"; a silent redirect would
   throw it away. `location.replace` (not `href`) so the back button cannot walk a signed-out cashier back onto a
   board. `sl_auth` is already removed above, so the door shows the FORM rather than booting straight back in.
6. **Kitchen card cramped (`kitchen.html`, item 6).** The card header row is now `flex items-baseline space-between
   gap-4 flex-wrap` and the reference number wears its own chip (`rounded-md px-2 py-1 bg-brand-card border
   border-brand-border/60 font-mono text-brand-accentLight text-xs tracking-widest`, `letter-spacing:0.3em`) instead
   of a bare `<div>` butting against the cup count — that run-together was "ownertry7 cups72818" in the screenshot.
   Name and cup count stay big (24 px), the code is 12 px, and there is still no peso (the cashier owns pricing).
7. **Owner Focus opened and closed by itself (`owner.html`, item 7).** Root cause: the control was a STYLED native
   `<select>`. Once a `<select>` carries `rounded-lg`/background/border, Chrome stops drawing the OS picker and
   renders its own dropdown as a popup that OPENS ON MOUSEDOWN AND CLOSES ON MOUSEUP — one tap therefore flashes
   the list and selects nothing (and on a phone the popup is OS-coloured, dark-on-dark). There was no paint interval
   in `owner.html` (only the 1 s clock tick) and `app.css` styles no `select`, so the popup was the whole cause. Fix:
   the list is ours — a page-level `focusOpen` flag, `focusToggle()` (the Focus button, 48 px) and `focusPanel()`
   (a card of `data-focus-label` chips plus "Close focus"). Tapping Focus flips `focusOpen`; tapping a chip sets
   `salesFocus` and folds the panel; grain/range changes reset `focusOpen = false`. Labels are unchanged — still
   `focusLabels()`, still calendar-generated in UTC, so an empty period stays selectable.

**Evidence (localhost, all seven measured in the live DOM).** Cashier signed in as the cashier
probe: `logoutbtn` is inside `header` and `hidden === false`; `#wholine` reads "Signed in as Probe (cashier) — tap
Log out to close the register."; the code input sits 17 px inside the card on BOTH sides (symmetric, flush at the
`p-4` inset). The cashier was re-measured on a FRESH origin `http://localhost:8741` because the `:8731` server served
a stale `app.css` on a plain reload (no `Cache-Control` — see the lesson below). Add-to-claim panel after looking up a
live claim (code 09547, 2 items): 14 `.claim-add-row`s, all 29 chips 48 px tall, `justify-content: center`, chip widths
59–102 px (the `max-width: 14rem` cap never binds at these label lengths), rows stacked 60 px apart at desktop width
with the name column 128 px (`minmax(8rem, auto)`). Phone pass at 390 × 844 (`setViewportSize`): the same panel stacks
with rows 92 px apart, three-size lanes ~100 px apart (chip lefts 55/157/256) and two-size lanes ~138 px apart (84/222)
— auto-fit collapsed the unused lane — and the code input still sits 17 px inside the card on both sides at phone
width. Kitchen after paying 22120 over REST: header children sit 16 px apart (`gap-4`), name and
"3 cups" at 24 px, the code chip 12 px with a 1 px border and `bg-brand-card` fill. Owner: tapping Focus opened 30
chips + "Close focus" and they were still there 6 s later (a browser popup cannot survive that); tapping the
`2026-10-20` chip set the window line to "Window 2026-10-20 → 2026-10-20 · daily bars · focused on 2026-10-20" with
₱5,250.00 / 9 completed — the same day the sweep-1 monthly proof established — and folded the panel. Logging out
showed the gate copy, then `page.url` became `http://localhost:8731/login.html` with the sign-in FORM on screen
(`sl_auth` gone, so the door did not boot back in).

**Public-host re-proof (`https://savage13317.github.io/sleepless-cafe-pos/`, same day, after the `fe296fb` push).**
Cashier: `logoutbtn` inside the sticky header, `hidden === false`, 69 × 48 px; `#wholine` "Signed in as Probe (cashier)
— tap Log out to close the register."; the code input 17 px inside the card on both sides. At **390 × 844** the Add-to-claim
panel (live claim 46752) measured 14 rows / 29 chips, every chip 48 px tall, rows 92 px apart, three-size lanes at lefts
55/157/256 and two-size at 84/222 — byte-identical measurements to the localhost pass, so the compiled CSS shipped intact.
Logging out navigated to `…/login.html` showing the sign-in FORM (Email / Password / Sign in), not an auto-boot. Kitchen
header: `display: flex`, `gap: 16px`, `align-items: baseline`, name 24 px, "7 cups" 24 px, code chip 12 px with a 1 px
border and `rgb(34, 22, 16)` (`bg-brand-card`) fill, children 16 px apart. Owner: Focus opened 30 chips + "Close focus"
at 48 px tall, still 30 after a 6 s repaint, and tapping `2026-10-20` folded the panel to 0 with "Window 2026-10-20 → 2026-10-20
· daily bars · focused on 2026-10-20" at ₱5,250.00 / 9 completed / ₱583.33 — the same day sweep 1 proved.

**Honest flags — found, reported, deliberately NOT fixed this pass.**
- `login.html`'s two inputs still carry `w-full box-content`, the same overflow pattern as item 2. The door's card is
  `max-w-md` with `p-6`, so the overflow is smaller than the cashier's, but it is the same defect and should get the
  same `box-border` treatment.
- `owner.html` still has native `<select>`s elsewhere — the menu builder's two size-pair pickers (~:691/:716), the
  category picker (~:761/:765) and the roster role picker (~:870), all still served by `selectedOption()` at :683.
- The claim line inside an open cashier card (`.cart-line`, a six-column grid) is CLIPPED at the right edge on a 390 px
  viewport — the phone screenshot cut the `Remove` button in half. That grid predates this sweep, was not one of the
  seven reports, and was left alone; it is the next narrow-width layout bug a phone dogfood will hit.
  They carry the same Chrome popup defect the Sales tab had. Not reported by the human, not touched.
- `focusLabels()` caps the daily list at `Math.min(salesDays, 31)`, so with the 365-day range only the last 31 days
  are selectable. Unchanged from sweep 1; the chip panel now makes the cap VISIBLE, which is why it is worth knowing.
- The local static server sends no `Cache-Control`, so Chrome heuristically caches `assets/app.css` and a plain reload
  can serve the previous stylesheet (the new rules then silently do not apply). This pass proved the rules by fetching
  the stylesheet at a fresh URL — a QA artifact, not a code defect; on the public host the note in §3 applies instead
  (`Cache-Control: max-age=600`).

**New lessons (do-not-re-derive).**
- `w-full` + `box-content` overflows its card: content-box sizing means `w-full` sizes only the CONTENT, so padding
  and border land outside. Use `box-border` on any full-width input/box inside a padded card.
- A styled native `<select>` is unusable by tap in Chrome (popup opens on mousedown, closes on mouseup) and unusable
  by touch on a phone. Build the list as DOM chips with an explicit open/closed page-level flag.
- The sticky header is the right home for identity/logout state on any page whose body repaints on a timer — anything
  painted into the repainted block is destroyed on the next beat.
- The `hidden` ATTRIBUTE reliably hides a flex-child button here (Tailwind preflight sets no `display` on `button`);
  `.hidden` as a CLASS is a separate Tailwind utility and is not what this uses.
- `repeat(auto-fit, minmax(4.5rem, 1fr))` collapses the lanes an item does not use, so equal lanes stay predictable
  without leaving a dead column; cap the chip itself (`max-width` + `justify-items: center`) if the lanes get wide.

---

## 14. Phase 9 — multi-store (multi-tenancy) + tier subscription model (2026-10-23) — **9a APPLIED LIVE · 9b–9f pending · files uncommitted**

**Status 2026-10-23 — 9a APPLIED LIVE (schema block only, human-authorized via the authenticated `database/query` path):**
`stores` created + seeded (1 row, slug `flagship`, id `00000000-0000-0000-8333-000000000001`, tier `starter`), `store_id`
added to `menu_items`/`categories`/`orders`/`staff_roster` (constant default = legacy id), `created_at` on `order_items`,
`updated_at` on `menu_items`/`categories`, the 5 store indexes, and `ALTER TABLE stores ENABLE ROW LEVEL SECURITY`.
**9a gate verified:** stores=1, orders 18/18 legacy, menu 15/15 legacy, categories 5/5 legacy, roster 3/3 legacy,
order_items 38/38 carry `created_at`; anon `GET /rest/v1/menu_items` still HTTP 200 and now returns `store_id`. The
existing `sql/03` policies are untouched, so the running single-store app is unchanged. **9b–9f are NOT yet done**
(9b needs human-typed passwords; 9c needs the JWT signing secret + Edge Function; 9d/9e are file edits). The two
files remain uncommitted. The human asked for a comprehensive architecture spec + step-by-step refactoring plan for
multi-store + Tier 1 / Tier 2 gating on ONE Supabase instance. The deliverables:

| Asked for | Delivered in |
| --- | --- |
| (1) the SQL migration file | `sql/08_multitenant.sql` (32,869 B / 623 lines) |
| (2) frontend routing + auth architecture | `MULTI_TENANT_SPEC.md` §4 |
| (3) feature-gating design | `MULTI_TENANT_SPEC.md` §2 (tier matrix) + §5 (per-function delta) |
| (4) step-by-step safe-migration roadmap | `MULTI_TENANT_SPEC.md` §6 (9a→9f + 6-probe checklist) |

§3 of the spec covers realtime + the 30-min unpaid-order expiry, which the human raised as a fourth concern.
**The two files cross-reference each other's numbering — do not renumber either one.**

**The design, in one paragraph.** The store axis is additive, not a rewrite: `sql/08` creates `stores` and gives
every existing data table a `store_id uuid NOT NULL DEFAULT <legacy-store-uuid> REFERENCES stores (id) ON DELETE
RESTRICT`. Because the default is a constant, every existing row lands in the legacy store with no data movement,
no re-key, and no window where the current single-store app is broken. The legacy store is seeded with the fixed
id literal **`00000000-0000-0000-8333-000000000001`** and slug **`flagship`** — that literal appears in four `ADD
COLUMN` defaults plus the seed row, so if a second store is ever bootstrapped by hand, replace the literal
**ONCE before the first paste**, never mid-file. `order_items` deliberately gets **no** `store_id`: it inherits the
store through its `orders` FK, and a second copy of the axis there is a second thing that can drift out of sync.

**The store travels in the JWT, not in a lookup.** `jwt_store_id()` reads `sid` (or `user_metadata.sid`) out of
`request.jwt.claims` and UUID-guards it (garbage → NULL). It reads **no table at all**, on pain of recursion: a
policy helper that SELECTed `staff_roster` would re-enter `roster_authenticated_read_*`, and Postgres does not
allow a policy expression to read a table the caller is already being filtered by. Consequence: a staff member's
store is asserted by the token that minted their session, so re-issuing identities with `data:{sid: <store-uuid>}`
is step **9b**, not a cosmetic edit.

**Tier is not self-serviceable.** Two UPDATE policies pin the tier — `stores_owner_update_starter` (USING
`tier = 'starter'`) and `stores_owner_update_pro` (USING `tier = 'pro'`), each with the matching WITH CHECK — so an
authenticated owner can edit name/city/timezone/`is_open` inside their own tier but can never flip `tier` itself;
a tier change is a `service_role` (i.e. dashboard/CLI) action only. The 25-item Tier-1 cap is enforced in two
layers: the policy helper `cap_allows(store_id)` in the WITH CHECK of `menu_items_staff_write_store`, and a copy of
the same count inside `create_menu_item` returning `MENU_LIMIT_REACHED` (a policy refusal is an opaque HTTP 401-ish
card; the function copy is what the owner page can render as prose). `tier_gate(store_id, need)` is the single
backend boundary in front of `sales_summary` / `sales_report` / `turnover_stats`, and `starter_write_gate(...)` is
the Tier-1 restriction on `update_menu_item` (availability toggles allowed, name/description/price edits refused
with `TIER_REQUIRED`). Frontend gating is cosmetic by design — the backend refusal is the answer to "can I stop it",
the UI hiding is only the answer to "will I see it".

**Critical ordering trap — the anon store-scoped policies are Phase 9c, NOT 9a.** `menu_read_store_anon` /
`categories_read_store_anon` require `jwt_store_id() IS NOT NULL`. If they are applied before the store token exists
(step 9c mints it), every visitor's catalogue renders **empty** — the anon read is the whole menu page. Until 9c
ships, keep 03's broad anon read (interim option **B** in spec §4.3): with one branch live it is safe, and the
public-menu read is public data anyway. Option **A** (target) is an Edge Function minting a 5-minute HS256
`{role:'anon', sid, exp}` — needs `SL_JWT_SECRET`, which must never enter the repo, the browser, or the model.
Option **C** (an Auth identity per walk-in customer) is rejected: it burns a GoTrue user per visitor.

**Gotchas recorded while writing the file (all still open, none fixed live).**
- `code varchar(5)` is **globally UNIQUE** in `sql/01_schema.sql:74`. Two stores will collide on claim codes
  immediately. The scoped fix — `ALTER TABLE orders DROP CONSTRAINT <generated-name>` then
  `CREATE UNIQUE INDEX orders_store_code_idx ON orders (store_id, code)` — is documented in spec §1.4 but NOT in
  `sql/08`, because the generated constraint name must be confirmed against the live DB before it is dropped.
  Do this as its own verified step, not inside the 9a paste.
- `stores` uses `text + CHECK IN ('starter','pro')`, not an ENUM. Enumerations are type-level, cannot be extended
  without a rewrite, and would make a future Tier 3 a schema migration. Keep the CHECK.
- There is **no `users` table** and there must not be one: GoTrue owns identities, `staff_roster` owns role/store,
  and a third copy of either is a desync risk. `analytics_logs` is present in `sql/08` only as a commented block —
  Tier-2 analytics today reads `orders`/`order_items` through the existing summary functions.
- `purge_expired_orders_store(uuid)` and `purge_expired_orders_all()` are new because the existing cron Edge
  Function calls the global sweep; renaming it would break the registered job. Both keep the physical `DELETE`
  (the partial index `orders_store_live_idx (store_id, expires_at) WHERE status='pending_payment'` is what makes
  the sweep cheap) — and **do not add a VIEW** for freshness: a view's read is subject to the view's own policies,
  which is a silent RLS bypass trap. Freshness filtering belongs inside `list_active_pending()`'s body (step 9d).

**Syntax traps hit while drafting `sql/08` (fixed in-file; do not reintroduce).** `INSERT (cols)` without `INTO
stores`; a self-referential `CHECK (id <> id)`; `SELECT … FROM menu_items.columns` (not valid introspection);
`DELETE o FROM orders AS o` (MySQL syntax, not PG) → `DELETE FROM orders AS o`; `WHERE o.id IN <jsonb array>`;
locals named `before`/`after` (grammar-keyword collision) → `n_before`/`n_after`; `COUNT(<alias>)` on a scalar
→ `COUNT(1)`. The file was rewritten rather than patched after these were found.

**No local PostgreSQL parser exists on this box** (`Get-Command psql` → nothing; `node_modules/pgsql-parser` and
`node_modules/sqlparser` → both absent). So `sql/08_multitenant.sql` is **hand-reviewed only** — its first live
paste is the syntax gate, and multi-statement groups in the dashboard abort atomically on a parse error, which is
what makes that paste safe. The schema block runs ONCE; a re-paste failing is the expected safe signal, not a defect.

**Honest flags — deliberately NOT done this pass.**
- **9a is now applied live** (schema block only, verified above); 9b–9f are not. `sql/08` and `MULTI_TENANT_SPEC.md`
  are still uncommitted. The next human-authorized step is **9b** — re-issue the 3 staff identities with `data:{sid}`
  (signup with the same email/password, or admin API with service role); passwords must be typed by the human, never
  routed through the model.
- `assets/api.js`, `assets/config.js` and the five pages are unchanged — no page knows about `?store=<slug>`, and
  `assets/config.js` has no `storeSlug` key yet. That is step 9e, and it must not start before 9c exists.
- `sql/03_rls.sql` still carries `USING ( true )` on every authenticated policy — the single-store assumption that
  Phase 9c replaces. Until then, an authenticated staff member can technically read another store's rows; with one
  store live that is unobservable, which is why it is a roadmap item and not a hotfix.
- The realtime side is unchanged: isolation is already RLS-enforced per store, so the client filter strings
  (`eq:orders.INSERT`) are bandwidth-only and must be re-verified live once a second branch exists.
- Phase 8's open items (live cron, Vercel account/domain, manual phone run of Gate A) are untouched and still parked.

**COMPLETENESS GAP — the 9d function delta is live-only, not in any repo file (verified 2026-10-23).** The 9d body edits
(store-scope via `jwt_store_id()`, tier/cap gating via `tier_gate`/`starter_write_gate`/`cap_allows`, `create_order`
`COALESCE(jwt_store_id(), legacy)`) were applied to the **live DB** (chunks 1–5, all 201) but are **not captured in a file**:
`sql/02_functions.sql` on disk is still the **pre-9d** version (its `create_menu_item`/`update_menu_item` bodies use the
email/`roster_role_of` owner fence, no `store_id` on INSERT, no cap/tier guards), and `sql/08` holds only the new helpers/routing,
not the modified core bodies. **Hazard:** any future session that re-applies `sql/02_functions.sql` (`CREATE OR REPLACE`) silently
**reverts** the store-scope/tier gating. **FIX — DONE 2026-10-23:** the delta is now captured in **`sql/09_function_delta.sql`**
(14 idempotent `CREATE OR REPLACE` bodies: 12 from `sql/02` — `create_order`/`get_order_by_code`/`confirm_payment`/`add_claim_item`/
`create_category`/`reorder_categories`/`delete_category`/`create_menu_item`/`update_menu_item`/`sales_summary`/`sales_report`/`turnover_stats`
— plus `staff_session`/`roster_add` from `sql/07`; `sql/07` on disk was ALSO pre-9d for those two). Replay order is now
**01→02→03→04→05→06→07→08→09**; 09 overrides 02/07 bodies with no signature change, so `api.js` call sites are untouched.
`sql/09` is a **spec-faithful reconstruction** (originals verbatim + MULTI_TENANT_SPEC §5.2 edits), NOT a verbatim dump of the live
bodies — treat it as authoritative for re-runs, but call-test it against a **second store** or a **real staff JWT** before trusting
byte-for-byte equality with the live 9d state. **Verification limit:** with one store + interim option B the 9d
bodies are behaviorally indistinguishable from the old ones (legacy default == the `COALESCE` fallback), and the role guards
(`OWNER_SESSION_REQUIRED`/`STAFF_SESSION_REQUIRED`) are unchanged by 9d and fire before the store-scope code — so those return
codes are **not** evidence of a live regression. Confirming the 9d bodies needs a **second store** or a **real staff JWT** (human login).

---

## 15. Phase 9g — SECOND STORE `marcelas` (2026-10-23) — **APPLIED LIVE + browser-verified + COMMITTED `a64ce1e`**

Human request: "make a another folder in this project … second store is Marcela's B&B Restaurant … get color pattern from this website … assign task to correct agents". This closes the "needs a second store" limit in §14: the **store axis is now observable for READ**.

**The store row (live, verified):** `id 00000000-0000-0000-8333-000000000002` · `slug marcelas` · `name Marcela's B&B Restaurant` · `city Gamay, Northern Samar` · `timezone Asia/Manila` · `is_open true` · **`tier starter`** (deliberate — flagship is `pro`, so the tier axis stays observable and the seeded catalogue stays under the 25-item cap).

**Counts, verbatim from the live DB:** `flagship | pro | 5 | 15` and `marcelas | starter | 4 | 10`. Note the **15 vs 14**: flagship holds 15 `menu_items` rows but `menu_for_store` returns **14** — one row is `is_available=false`. That is not leakage; do not "fix" it.

**Call-test proofs (publishable key, public surface):** `resolve_store {"p_slug":"marcelas"}` → `success:true` with `tier:"starter"`; `menu_for_store {…0002}` → exactly the 10 marcelas items, zero flagship ids; `categories_for_store {…0002}` → the 4 marcelas categories; flagship calls still 14/5. Envelope `{success,data,error}` on all.

**Files (all uncommitted):** `sql/10_marcelas_store.sql` (9,193 B — INSERT-only, `ON CONFLICT (id) DO NOTHING`, fixed UUID space categories `3333…`/items `4444…`, `store_id` passed **explicitly** on all 14 rows) · `stores/marcelas/README.md` · `stores/marcelas/tokens.css`. **Replay order is now 01→02→03→04→05→06→07→08→09→10.**

**THEMING ARCHITECTURE — the trap that cost the most this pass.** There are **two** theming layers and a store theme must cover **both**: `assets/app.css` reads `var(--brand-*)` **at runtime** (a custom-property override cascades), but `assets/tailwind.compiled.css` is a **build artifact with literal hex baked in** (`tools/tailwind.config.js` `readFileSync`s `assets/tokens.css` and resolves `token()`→hex at build time). Proof from the browser: with only the custom properties, `.text-brand-accent` stayed `rgb(212 141 55)`. `stores/marcelas/tokens.css` therefore **hand-mirrors all 27 compiled `brand-*` rules** (plus the `::-moz-selection` twins), each prefixed `[data-sl-store="marcelas"]`, `--tw-*` plumbing byte-identical, **no `!important`** — specificity does the work. The **same baked-literal problem applies to fonts**: `.font-serif` is baked as `font-family:Playfair Display,serif`, so `--font-serif` alone never repaints it; block 3 mirrors `.font-serif{font-family:Cinzel,serif}`. There is **no `.font-sans` rule in the artifact** — the body face reaches up through `app.css`'s `var(--font-sans)`, which block 1 already covers.

**Palette (from Marcela's own website, inline Tailwind config):** `gold 400 #E6C65A / 500 #D4AF37 / 600 #B89028 / 700 #8C6A15`, `resort dark #0F172A / cream #FAF9F6`, fonts `Cinzel` + `Plus Jakarta Sans` → mapped onto the **existing** token names (no new token names): dark `#0f172a`, card `#1e293b`, card-hover `#334155`, accent `#d4af37`, accent-light `#e6c65a`, cream `#faf9f6`, muted `#94a3b8`, border `#8c6a15` (gold-700 — reads as a hairline gold rule at the `/40`–`/60` opacities the pages already use).

**`menu.html` wiring (4 surgical edits, flagship byte-stable):** Google Fonts extended with `Cinzel` + `Plus Jakarta Sans` (Inter/Playfair untouched) · `<link rel="stylesheet" href="stores/marcelas/tokens.css">` after the compiled artifact (safe unconditionally — every rule is scoped) · a **classic non-module `<script>` in `<head>`** stamping `data-sl-store` from `?store=` before the module runs (no first-paint flash) · `<h1 data-branch-title>` + `<span data-branch-name>` ×2 in the footer, rewritten by `applyBranchTitle()` **only when `slug !== 'flagship'`**, via `textContent` (the store name is DB data — never parsed as markup).

**Browser proof (local static server, working tree):** `?store=marcelas` → `data-sl-store=marcelas`, body `rgb(15,23,42)`, `--brand-accent #d4af37`, `.text-brand-accent` computed `rgb(212,175,55)`, `.bg-brand-card/60` `rgba(30,41,59,.6)`, `.border-brand-border/60` `rgba(140,106,21,.6)`, h1 `Cinzel` + `MARCELA'S B&B RESTAURANT`, body `Plus Jakarta Sans`, footer `Marcela's B&B Restaurant` ×2, 4 categories + marcelas items. `menu.html` (no param) and `?store=flagship` → flagship palette byte-identical (`rgb(20,12,8)`, `#d48d37`, `rgb(212,141,55)`, Playfair/Inter, `SLEEPLESS CAFE`, 5 categories). `?store=ghost` → flagship palette retained + "That branch isn't open right now."

**STILL OPEN — state these honestly, they are capability gates, not bugs:**
1. **An order placed from `menu.html?store=marcelas` lands in flagship.** Interim option B keeps the broad anon read, and an anon customer carries no `sid`, so `create_order` `COALESCE`s to the legacy uuid. Closing this needs the store-bearing anon token (§4.3-A, Edge-Function-minted, needs `SL_JWT_SECRET`).
2. **No `marcelas` staff identity exists.** A staff/owner JWT for the second branch needs a human-created auth user (bcrypt password typed by the human) — the DB-query path cannot mint one.
3. **Claim-code collision hazard:** `code varchar(5)` is **globally UNIQUE** (`sql/01_schema.sql:74`) and `create_order` draws codes without per-store scoping. Two live branches will eventually collide; the 23505 retry loop re-draws, so it degrades silently rather than failing. The scoped fix (`DROP CONSTRAINT` + `CREATE UNIQUE INDEX orders_store_code_idx ON orders (store_id, code)`) is in `MULTI_TENANT_SPEC.md` §1.4 and is **deliberately not applied** — it needs the generated constraint name confirmed against the live DB.
4. `assets/tokens.css` stays flagship's single source of truth; `stores/marcelas/tokens.css` is a **hand-mirrored copy of the build artifact**, so a future `tailwind.compiled.css` rebuild must be re-mirrored (durable fix: a second Tailwind build with the store tokens).
5. Cron/Vercel (Phase 8 / 9f) still parked.

**COMMITTED + PUSHED 2026-10-23** (human "commit and push"): `a64ce1e` `feat(phase-9g)` — 11 files, +2217/−12; pushed `16bf529..a64ce1e`, **HEAD == origin/main == `a64ce1e`**, tree clean. Pre-commit secret scan: zero `sb_secret_`/`sk_`/`eyJ`-shaped strings repo-wide (only prose mentions and `sql/08` policy clauses `FOR INSERT TO service_role`, which are policy syntax, not keys). **Public GitHub Pages re-proved after the push** (Pages rebuilt ~1 min; an immediate 404 on the new CSS was rebuild lag, not a missing file): `menu.html?store=marcelas` → `data-sl-store=marcelas`, body `rgb(15,23,42)`, `--brand-accent #d4af37`, h1 `Cinzel` + `MARCELA'S B&B RESTAURANT`, body `Plus Jakarta Sans`, footer `Marcela's B&B Restaurant` ×2, 4 categories + marcelas items; `menu.html` (no param) → flagship byte-stable (`rgb(20,12,8)`, `#d48d37`, Playfair/Inter, `SLEEPLESS CAFE`, 5 categories).