# tests/api.spec.md - Phase 6 QA API contract

Truth sources: `assets/api.js` (transport) + `sql/02_functions.sql` (state machine). Envelope on every call:
`{"success":bool,"data":any,"error":null|{"code":"STR","message":"STR"}}`. `api.js` never throws; pages map `error.code` only.

## 1. RPC table - export | HTTP target | named-arg body | success envelope (keys verbatim from 02_functions.sql)

TRANSPORT NOTE (verified live): this project's API gateway exposes SQL functions ONLY under
`/rest/v1/rpc/<fn>`. The bare `/rest/v1/<fn>` form answers 404 `PGRST205 "Could not find the
table 'public.<fn>'"` even though PostgREST's schema cache reports the RPCs as loaded. Every
`POST /rest/v1/<fn>` row below therefore really targets `POST /rest/v1/rpc/<fn>`; table reads
(`getMenu` / `getCategories`) keep the bare form, which does resolve.

| api.js export | HTTP target | named-arg body | success envelope |
|---|---|---|---|
| `createOrder(name, items)` | `POST /rest/v1/create_order` | `{"customer_name":"Ana Reyes","items":[{"menu_item_id":"<uuid>","size":"Regular","quantity":2}]}` | `{"success":true,"data":{"code":"04271","order_id":"<uuid>","total":120.00,"items_count":2},"error":null}` |
| `getOrderByCode(code)` | `POST /rest/v1/get_order_by_code` | `{"claim_code":"04271"}` | `{"success":true,"data":{"code","customer_name","status","total_amount","created_at","expires_at","seconds_remaining","items_count"},"error":null}` |
| (no client export) `purge_expired_orders` | `POST /rest/v1/purge_expired_orders` | `{}` | `{"success":true,"data":{"removed":3},"error":null}` - server-side only, called inside `list_active_pending` + `kitchen_queue`; no client wrapper by design (see §6 note) |
| `listActivePending()` | `POST /rest/v1/list_active_pending` | `{}` | `{"success":true,"data":[{"order_id","code","customer_name","created_at","expires_at","seconds_remaining","items_count","total_amount"}],"error":null}` |
| `confirmPayment(code)` | `POST /rest/v1/confirm_payment` | `{"claim_code":"04271"}` | `{"success":true,"data":{"code","customer_name","status","total_amount","paid_at","items_count"},"error":null}` |
| `kitchenQueue()` | `POST /rest/v1/kitchen_queue` | `{}` | `{"success":true,"data":[{"order_id","code","customer_name","status","paid_at","elapsed_seconds","items":[{"item_name","size","quantity","unit_price","subtotal"}]}],"error":null}` |
| `markServed(id)` | `POST /rest/v1/mark_served` | `{"order_id":"<uuid>"}` | `{"success":true,"data":{"order_id","code","customer_name","status","served_at","fulfillment_time_seconds"},"error":null}` |
| `setPreparing(id)` | `POST /rest/v1/set_preparing` | `{"order_id":"<uuid>"}` | `{"success":true,"data":{"order_id","code","customer_name","status","paid_at"},"error":null}` |
| `voidOrder(id)` | `POST /rest/v1/void_order` | `{"order_id":"<uuid>"}` | `{"success":true,"data":{"order_id","code","customer_name","total_amount","voided":true},"error":null}` - called from `owner.html` Tab 1 live-claims panel (two-step confirm); `cashier.html` has no void button by design |
| `salesSummary(from, to, grain)` | `POST /rest/v1/sales_summary` | `{"from_time":"2026-10-01T00:00:00Z","to_time":"2026-10-19T00:00:00Z","grain":"daily"}` | `{"success":true,"data":{"revenue","completed_count","aov","grain","buckets":[{"label","revenue","count"}]},"error":null}` |
| `turnoverStats(from, to)` | `POST /rest/v1/turnover_stats` | `{"from_time":"2026-10-01T00:00:00Z","to_time":"2026-10-19T00:00:00Z"}` | `{"success":true,"data":{"sample_size","avg_fulfillment_seconds","p95_fulfillment_seconds","peak_hours":[{"hour","orders"}]},"error":null}` |
| `createCategory(name, order)` | `POST /rest/v1/create_category` | `{"name":"Cold Brew","display_order":3}` | `{"success":true,"data":{"category_id":"<uuid>"},"error":null}` |
| `reorderCategories(list)` | `POST /rest/v1/reorder_categories` | `{"new_order":["<uuid>","<uuid>"]}` | `{"success":true,"data":{"reordered":2},"error":null}` |
| `deleteCategory(id, fb)` | `POST /rest/v1/delete_category` | `{"category_id":"<uuid>","fallback_category_id":"<uuid>" or null}` | `{"success":true,"data":{"category_id","name","items_moved","items_deleted","fallback_category_id"},"error":null}` |
| `createMenuItem(...)` | `POST /rest/v1/create_menu_item` | `{"category_id":"<uuid>","name":"Iced Latte","description":"","image_url":"<storage url>","sizes_and_prices":[{"size":"Regular","price":120}],"is_available":true}` | `{"success":true,"data":{"menu_item_id":"<uuid>"},"error":null}` |
| `updateMenuItem(...)` | `POST /rest/v1/update_menu_item` | `{"menu_item_id":"<uuid>","name":"","description":"","image_url":"","sizes_and_prices":null,"is_available":null}` | `{"success":true,"data":{"menu_item_id","category_id","name","description","image_url","sizes_and_prices","is_available"},"error":null}` |
| `uploadImage(file, bytes, mime)` | `POST /storage/v1/object/menu-images/<slug>` (`x-upsert: true`) | raw bytes, `Content-Type: <mime>` | `{"success":true,"data":"<sbUrl>/storage/v1/object/public/menu-images/<slug>","error":null}` (data is a string URL) |
| `signIn(email, password)` | `POST /auth/v1/token?grant_type=password` | `{"email":"owner@cafe.ph","password":"..."}` | `{"success":true,"data":{"access_token","token_type","expires_in","refresh_token","id_token","user":{"email","user_metadata"}},"error":null}` (raw GoTrue body) |
| `getMenu()` / `getCategories()` | `GET /rest/v1/menu_items?select=id,category_id,name,description,image_url,sizes_and_prices,is_available&order=category_id.asc,name.asc` / `GET /rest/v1/categories?select=id,name,display_order&order=display_order.asc` | none | `{"success":true,"data":[<raw row array>],"error":null}` |

## 2. Error-code table - code | SQL site (02_functions.sql) | page copy | pages that can see it

| code | emitted by | page copy string | pages |
|---|---|---|---|
| `INVALID_CUSTOMER_NAME` | create_order :38 | menu "We need your name at the counter." | menu |
| `INVALID_ITEMS` | create_order :41 :47 :52 | menu "Your cart looks empty - add something before checking out." | menu |
| `MENU_ITEM_UNAVAILABLE` | create_order :58 | menu "One of those items just went away..." / owner "That item isn't on the menu right now." | menu, owner |
| `INVALID_SIZE` | create_order :64 | menu "That size isn't on the board anymore..." | menu |
| `CODE_EXHAUSTED` | create_order :87 | menu "We're out of claim codes right now - please try again in a few minutes." | menu |
| `ORDER_NOT_FOUND` | get_order_by_code :120 | cashier "Wrong code, or that order's time is up." / kitchen "That card isn't on the board right now." / owner "That claim isn't on the board any more - it was paid, voided, or its time ran out." | cashier, kitchen, owner |
| `ORDER_EXPIRED` | confirm_payment :198 | cashier + kitchen "This order's time is up, please place a new one" | cashier, kitchen |
| `NOT_SERVABLE` | mark_served :263 | kitchen "That order isn't waiting in the kitchen any more - it's already done." | kitchen |
| `NOT_PREPARABLE` | set_preparing :289 | kitchen "That order is already on hold, no need to hold it again." | kitchen |
| `NOT_VOIDABLE` | void_order :310 | owner "That claim isn't open any more - it's already paid or gone." (reachable: the live-claims list can be stale, so the row may already be paid or purged when the button is tapped) | owner |
| `OWNER_SESSION_REQUIRED` | sales_summary :335, turnover_stats :363, create_category :391, reorder_categories :410, delete_category :437, create_menu_item :466, update_menu_item :497 | owner "The cafe didn't recognize you as an owner. Sign in with an owner account." | owner |
| `INVALID_GRAIN` | sales_summary :336 | owner "That time grain isn't supported - try daily, monthly or yearly." | owner |
| `CATEGORY_NOT_FOUND` | delete_category :439, create_menu_item :468 | owner "That category isn't there any more - refresh and try again." | owner |
| `INVALID_CATEGORY_NAME` | create_category :392 | owner "That category name is empty or too long - try a shorter one." | owner |
| `INVALID_ORDER` | reorder_categories :411 :414 | owner "The new shelf order didn't take - refresh the list and try again." | owner |
| `INVALID_FALLBACK` | delete_category :442 | owner "Pick a different category for the items to move to, or say to delete them too." | owner |
| `INVALID_ITEM_NAME` | create_menu_item :469, update_menu_item :506 | owner "That item name is empty or too long - keep it under 120 characters." | owner |
| `INVALID_SIZES` | create_menu_item :470 :476, update_menu_item :507 | owner "Every size line needs the form Small=120 - check the sizes and try again." | owner |
| `MENU_ITEM_NOT_FOUND` | update_menu_item :501 | owner "That item isn't on the menu any more - refresh and try again." | owner |
| `BAD_SHAPE` | client-side guard, `cashier.html:143` (pre-RPC, not a SQL code) | cashier rejects a malformed board row before the RPC call | cashier |
| `NETWORK` | api.js transport (fetch throw / signIn offline) | mapped on all four pages "We can't reach the cafe right now..." | menu, cashier, kitchen, owner |
| `HTTP` | api.js transport (non-2xx / unreadable body) | mapped on all four pages; also the `?? ERR_COPY.HTTP` fallback | menu, cashier, kitchen, owner |
| `AUTH` | api.js `signIn` | cashier/kitchen/owner `AUTH_COPY` (rendered outside ERR_COPY) | cashier, kitchen, owner |
| `PERMISSION_DENIED` | RLS denial on any table write (PostgREST code, not a function code) | owner "The cafe won't let this account do that." | owner |
| `INVALID_RANGE` | not emitted by any SQL - legacy entry | owner map entry only; no SQL site emits it (defensive courtesy for a future range CHECK) | owner (defensive) |
| `FALLBACK_REQUIRED` | not emitted by any SQL - legacy entry | superseded by `INVALID_FALLBACK`; no live page copy - drop on next pass | - |

## 3. Gate checks (MASTER_PLAN §3, §5, §6 + §7 Gate A, Phase 1-5)

- [ ] P1 - every `sql/02` fn returns the expected JSON/rows in a Dashboard Run test; seed menu (`sql/05`) visible
- [ ] P1 - `01_schema.sql` carries `ON DELETE CASCADE` on the `order_items -> orders` FK
- [ ] P2 - cart -> checkout -> real order in DB with a real 5-digit code (leading zeros preserved, string-typed)
- [ ] P3 - code lookup + live unpaid table + countdown + Confirm Payment flips status to `paid`
- [ ] P4 - paid order appears without refresh; Mark as Served writes `served_at` + `fulfillment_time_seconds`
- [ ] P5 - Auth gate blocks anonymous (all 7 owner RPCs return `OWNER_SESSION_REQUIRED` anon); menu builder creates a real renderable item
- [ ] TTL proof - unpaid order past 60 min: `SELECT` on its code in the Dashboard -> **no row**; `SELECT` `order_items` for that `order_id` -> **0** (cascade)
- [ ] Permanence proof - a `paid` order survives 10 consecutive `purge_expired_orders()` calls and still appears in `sales_summary` + `turnover_stats`

### 3.1 Phase 5 prerequisites applied in the Supabase Dashboard

- [ ] (a) public Storage bucket `menu-images` exists - `api.js` uploads to `/storage/v1/object/menu-images/<slug>` and the PUBLIC URL (`/storage/v1/object/public/menu-images/<slug>`) is what `menu_items.image_url` stores; a private bucket stores a URL that 403s and every menu card renders a broken image
- [ ] (b) the staff/owner Auth user(s) exist (`signIn` succeeds for each) and each email is present in `CONFIG.ownerEmails` - the allowlist is the UI gate, RLS is the real boundary (`sql/03_rls.sql`)
- [ ] (c) anon (publishable-key-only) calls of the 7 owner RPCs return `OWNER_SESSION_REQUIRED`, not `HTTP` or an empty array - confirms the Phase 5 guard is live in the Dashboard

## 4. Console-error checklist (per page)

- menu.html: [ ] `loadCatalogue` failure paints copy, no uncaught rejection [ ] all 5 `create_order` codes mapped [ ] no `error.message` in DOM [ ] no `console.*` in the checkout path [ ] `esc()` on every DB string
- cashier.html: [ ] `signIn` failure paints `AUTH_COPY`, table never renders without a session [ ] `ORDER_NOT_FOUND`/`ORDER_EXPIRED` copy verbatim [ ] `BAD_SHAPE` client-side before RPC (`cashier.html:143`) [ ] board error = one line, never a stack [ ] `NOT_VOIDABLE` is defensive/unreachable (no void button on cashier) [ ] 5 s re-poll cannot throw [ ] realtime `DELETE` removes the row (no ghost rows) [ ] no unhandled WS error [ ] no password ever echoed
- kitchen.html: [ ] WS give-up falls back to 3 s polling, no unhandled rejection [ ] realtime.js import failure degrades to poll [ ] `NOT_SERVABLE`/`NOT_PREPARABLE` mapped [ ] realtime callback is sync-safe [ ] no card rendered from a stale payload [ ] elapsed counter never NaN [ ] polling fallback silent (no console noise)
- owner.html: [ ] anon gets the gate card and zero dashboard data [ ] all 7 owner RPCs' codes mapped - no code falls through to the `HTTP` copy [ ] every tab renders `copyFor(code)`, never raw [ ] CSV export cannot throw on an empty bucket list and never reads `error.message` [ ] photo upload failure degrades to a text-only item, calls `say()` not throw [ ] live-claims panel: `listActivePending` failure paints copy, panel still renders [ ] void needs TWO taps on the same row (arm -> "Confirm void"); one tap never calls `voidOrder` [ ] an arm older than 12 s is dropped before the handler runs [ ] void id comes from the row's `data-order-id`, never invented [ ] after a void the claims list reloads (row gone, no ghost)
- index.html: [ ] launcher is import-free, so only static-link checks apply [ ] no script errors; only console risk is a 404 on `menu.html`

## 5. Dead-link checklist (local targets must exist on disk)

- [ ] `index.html -> menu.html` is the ONLY cross-page link in the repo (public page only)
- [ ] no POS page links another POS page, `index.html`, or `Sleepless.html`
- [ ] no POS page links `staff.html`; `Sleepless.html:237 -> staff.html` is out of scope (reference file, never edited)
- [ ] `cashier.html`, `kitchen.html`, `owner.html` carry `noindex`; `menu.html` and `index.html` stay indexable
- [ ] `index.html` static targets exist: `assets/tokens.css`, `assets/app.css`, `menu.html`
- [ ] the four app pages link `assets/tokens.css` + `assets/app.css`
- [ ] every local `href`/`src`/module import resolves on disk: `assets/tokens.css`, `assets/app.css`, `assets/config.js`, `assets/api.js`, `assets/realtime.js`
- [ ] module imports are written `./assets/api.js`, `./assets/config.js`, `./assets/realtime.js` (realtime: kitchen only) - bare `./api.js` / `./config.js` / `./realtime.js` would 404 from repo root
- [ ] `Sleepless.html` is reference-only and unreferenced by any live page

## 6. Phase 6 fixes applied (2026-10)

- **Import paths (runtime 404 blocker):** the four app pages live at repo root, so a relative module import must name the folder. `menu.html`, `cashier.html`, `kitchen.html`, `owner.html` now import `./assets/api.js`, `./assets/realtime.js`, `./assets/config.js`. `api.js` and `realtime.js` keep `./config.js` (they already live in `assets/`).
- **`sql/02_functions.sql` p95:** `OFFSET (cnt*0.95)::int` rounded 9.5 -> 10 for 10 samples, so the `LIMIT 1` found nothing and p95 read 0. Now `OFFSET FLOOR(cnt * 0.95)::int`.
- **`sql/02_functions.sql` update_menu_item:** the name CHECK rejected the documented blank/"keep" default, so every patch call failed. Now the length CHECK only applies when a name was supplied; `description`/`image_url` guards use `COALESCE(x,'') = ''` so an explicit `null` can no longer wipe an existing image URL.
- **`owner.html` ERR_COPY (Phase 5 additions):** the 6 new owner codes mapped + `FALLBACK_REQUIRED` renamed to the real code `INVALID_FALLBACK`. All owner codes are now mapped - the old claim that "5 unmapped owner codes hit the HTTP fallback" is stale and was removed from §2/§4.
- **`cashier.html` void comment:** was stale (claimed `list_active_pending` returns no id - it does now). Rewritten to state void is an owner-only decision by design; `cashier.html` has no void button, so `NOT_VOIDABLE` is a defensive/unreachable copy there, not a mapped UI path.
- **`api.js` error table:** Phase 5 owner codes documented alongside the customer/staff codes.
- **Not a defect:** `purge_expired_orders` intentionally has no client wrapper - it runs server-side inside `list_active_pending` and `kitchen_queue`; the browser never gets a TTL lever.
- **Resolved (2026-10-19, owner chose option A):** `void_order` is owner-only. `owner.html` Tab 1 now lists live unpaid claims (`listActivePending`) and voids one through a two-step confirm; `MASTER_PLAN.md` deviation 7 and the §5 function table were updated to match. `cashier.html` still has no void button - unchanged, by design. `INVALID_RANGE` and `FALLBACK_REQUIRED` remain as legacy owner-map entries with no SQL emitter (harmless, defensive).
