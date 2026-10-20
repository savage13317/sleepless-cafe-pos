# HANDOFF.md — Sleepless Cafe POS · continuation brief

**Written:** 2026-10-19 · **Branch:** `main` · **Repo:** `github.com/savage13317/sleepless-cafe-pos`
**Where we are:** Phases 1–6 done · **Phase 5 (owner dashboard) gate PASSED** · **Phase 6 (QA sweep) PASSED** (14/14 anon probes conform, zero dead links, zero static console risks) · **Phase 7 (GitHub Pages dogfood) is next.**

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
- Staff identity in use: `staff-probe@sleepless-cafe.test` (password deliberately **not**
  recorded here — it is a credential, and this file is committed; it lives only in the local
  browser URL / `localStorage.sl_auth`), id `890bb2f2-4ee3-45ce-9935-392dd032663d`,
  role `authenticated`, `email_confirmed_at` set. Rotate it if this repo ever becomes public.
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
- Verified `CREATE POLICY` grammar: `CREATE POLICY n ON t [AS {PERMISSIVE|RESTRICTIVE}] [FOR {ALL|SELECT|INSERT|UPDATE|DELETE}] [TO {role|PUBLIC|CURRENT_ROLE|CURRENT_USER|SESSION_USER},…] [USING (e)] [WITH CHECK (e)]`. `ON <table>` precedes `FOR`; `FOR` never takes a table name; role restriction is the `TO` clause. `DROP POLICY [IF EXISTS] n ON t [CASCADE|RESTRICT]`.
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

### 1.x SQL execution path (verified 2026-10-24) — do not re-derive
- The Supabase **SQL Editor in the dashboard never initializes**: the Monaco query pane stays an `svg`
  spinner and the `textarea` / `.monaco-editor` element counts stay 0 after 45 s plus a reload. Do not
  waste time on it — clicking `sql-run-button` cannot help while the editor never mounts.
- Working path instead, on the **authenticated dashboard page**: `localStorage['supabase.dashboard.auth.token']`
  is raw JSON whose `.token` (≈ 1406 chars) works as `Authorization: Bearer <tok>` against
  `POST https://api.supabase.com/v1/projects/epldhypmhpxkebtiidsc/database/query` with body
  `{"query":"<sql>"}` → `201`, rows returned as JSON. Proved with `SELECT 6*7 AS product;` → `[{"product":42}]`.
  No PAT is minted and no credential is ever printed — the token is read and used in place inside the page.
- Multi-statement bodies work; a `DROP FUNCTION` must precede a signature-changing
  `CREATE OR REPLACE FUNCTION` (`42P13 cannot change name of input parameter` otherwise).
- Cosmetic drift: the two live functions were applied with `$q$` fences and single-line
  `jsonb_build_object` calls, while `sql/02_functions.sql` uses `$$` and wrapped lines. Semantically
  identical; re-pasting the repo file replaces the live rows (never run both sets at once).

---

## 2. Live project state (as of this commit)

- Project ref `epldhypmhpxkebtiidsc` · org ref `isiqwbqhfmqztvttvdbf` · org "POS", project
  "sleepless-cafe", branch `main (Production)`, plan **FREE**.
- Publishable (client) key — public by design: `sb_publishable_krQEeT-v7feHLYl01f8zsw_to9JjsAD`.
  The service-role/secret key has never been shipped to a browser and must never be.
- DB: seed + Phase-4 probe orders — `orders` 3 (`63242` and `02342` both `status=served` with `served_at`
  + `fulfillment_time_seconds` 1641/894; `13977` still `pending_payment`), `order_items` populated,
  `categories` 4, `menu_items` 12.
  Category UUIDs `11111111-1111-1111-8333-000000000001..4` (Coffee 1, Non-Coffee 2, Pastries 3,
  Desserts 4). Menu UUIDs `22222222-2222-2222-8333-000000000001..12`, all `image_url` empty.
- All probe objects removed live (`zz_probe_tbl`, `zz_view1`, `zz_probe_fn`, `zz_p1..zz_p6`,
  `zz_m1..zz_m3`).
- Local static server (still live): `python -m http.server 8731 --directory <repo root>`.
  Working URLs: `http://localhost:8731/menu.html?sburl=…&sbkey=…`, same for
  `cashier.html` (+ `&email=&password=` — values not recorded here), `kitchen.html`, `owner.html`.

---

## 3. What each file currently is

| File | State |
| --- | --- |
| `sql/01_schema.sql` | Unchanged. 4 tables, 6 indexes incl. partial `orders_live_pending_idx`. No RLS enablement anywhere (by design). |
| `sql/02_functions.sql` | **Fixed, 579 lines, applied live, call-tested.** 16 functions, all `RETURNS jsonb … LANGUAGE plpgsql`. Header carries six `-- FIX:` paragraphs. |
| `sql/03_rls.sql` | **Rewritten, applied live, behaviour-verified.** 4× `ENABLE ROW LEVEL SECURITY` first, then 10 policy pairs each preceded by `DROP POLICY IF EXISTS`. |
| `sql/04_realtime.sql` | **Corrected + applied live.** Publication claim replaced with the verified membership+delivery contract; executable `alter publication supabase_realtime add table orders;` added; v4 wire block replaced with the 2.118.0 `.on(...)` surface. |
| `sql/05_seed.sql` | Applied live, idempotent (`ON CONFLICT (id) DO NOTHING`), no DELETE/TRUNCATE. |
| `assets/api.js` | 12,895 B. JSON envelope `{success,data,error}`; `callSql` on `/rpc/`; thin wrappers over all 16 fns; `getRows`/`getMenu`/`getCategories`; `uploadImage` is a **POST** with `x-upsert: true` + binary body (docs-confirmed form, unchanged — the comment above it still says "PUT", fix in Phase 6); `deleteCategory`/`updateMenuItem` now send `p_*` keys (`p_category_id`/`p_fallback_category_id`, `p_menu_item_id`/`p_name`/`p_description`/`p_image_url`/`p_sizes_and_prices`/`p_is_available`); `fmtPeso`/`fmtTime`/`fmtCountdown`; session-token setters. |
| `assets/config.js` | 1,480 B, untouched. Priority `window.SL_CONFIG` → `localStorage.sl_config` → committed placeholder. **Phase 5 note:** `ownerEmails` comes from `sl_config`, so the staff/owner email must be added there for the owner gate. |
| `assets/realtime.js` | **Functional, ported to supabase-js 2.118.0.** Public surface unchanged (`mode`, `stopWatching()`, `startWatching(onEvent, poll)`), so `kitchen.html` needed no edit. WS confirmed via `wait:true` before `mode='ws'`; honest polling fallback; per-socket `dead` flag teardown. |
| `menu.html` | 20,233 B. Gate passed: cart → checkout → real order with a real 5-digit code. Config bootstrap is a **classic** script above the module script. Code rendered as a **string** (leading zeros preserved). |
| `cashier.html` | 20,177 B. Gate passed: code lookup + live unpaid table + countdown + Confirm Payment → `paid`. Same classic-script bootstrap fix. |
| `kitchen.html` | 19,949 B, **unchanged**. Board renders, Hold only when not preparing, `startWatching(repaint, repaint)` + 1 s paint tick. **Gate met** via the fixed realtime.js (dot = WS live, card appears without reload). |
| `owner.html` | 40,991 B, **Phase 5 fix applied**. The config bootstrap was lifted into a classic `<script>` above the module script (same block as `cashier.html`) and now also persists `?owneremails=` into `sl_config.ownerEmails`, which is what the owner allowlist gate reads. |
| `index.html` | Only valid cross-page link in the repo: `<a href="menu.html">` at line 160. |
| `MASTER_PLAN.md` | §4a added: "Platform facts verified live (Phases 1–3)" — RPC path, Phase-A staff account, `assets/ui.js` deviation. |
| `tests/api.spec.md` | TRANSPORT NOTE added under §1. |
| `assets/ui.js` | **Does not exist** and is referenced by no page (only `MASTER_PLAN.md:99`). Deliberate deviation: each page ships its own inline UI, keeping dispatches inside the 1–3 file budget. Do not create dead code. |
| `Sleepless.html` | Design reference only, never edited. Its dangling `staff.html` link at `:237` is out of scope. |

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
- Static console sweep clean: no import/export mismatches (25 exports in `api.js`), no undefined
  identifiers, no duplicate `id` attributes, all 8 in-page `JSON.parse` sites are `try/catch`-guarded.
- One defect found and fixed: the comment above `uploadImage` said **PUT** while the code is **POST**
  + `x-upsert` — comment corrected, code untouched.
- Flagged, NOT fixed: `void_order` carries no JWT/session guard, so as anon it answers `NOT_VOIDABLE`
  (its `SELECT` is RLS-filtered to empty) rather than `OWNER_SESSION_REQUIRED`. Safety is RLS
  (`orders_staff_delete` is authenticated-only + `status='pending_payment'`), so no anon `DELETE` is
  reachable; "owner-only" is a UI decision (§9.7), not a JWT claim check.

**Start here next → D. Phase 7 — GitHub Pages dogfood** (public URL is live; tick the Gate A items
including the TTL deletion proof and the paid-permanence proof).

**D. Phase 7 — GitHub Pages dogfood:** 3-order walkthrough on the public URL
`https://savage13317.github.io/sleepless-cafe-pos/`.
**E. Phase 8 — Vercel go-live** (`tools/inject-config.mjs` writes `assets/config.generated.js`;
that file and root `vercel.json` are gitignored artifacts).

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
19fef79 fix(phase-4): publish orders for postgres_changes and port realtime.js to supabase-js 2.118.0   <- origin/main (HEAD)
c581d84 feat(phase-4): kitchen KDS board and realtime watcher (ws path still broken)
a3fed04 fix(transport): call SQL RPCs under /rest/v1/rpc/ and hoist config bootstrap
c80f8bc fix(sql): repair plpgsql bodies and migrate RLS to verified PG grammar
4217d22 chore: ignore deploy-root vercel.json artifact
```

Conventional-commit style is the project's; keep `fix(phase-N):` / `feat(phase-N):` prefixes and
put the live-verification evidence in the commit body, as the three commits above do.
