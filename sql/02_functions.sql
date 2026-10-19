-- ============================================================================
-- 02_functions.sql :: PHASE 1b - THE ORDER STATE MACHINE (Supabase / PostgreSQL 15)
-- APPLY AFTER 01_schema.sql, BEFORE 03_rls.sql
--
-- These are the ONLY state transitions in the system: RLS (03) gates who may
-- call them, it never moves state itself. All are browser-callable, no role
-- checks live in this file.
--
-- INVARIANTS (must match 01_schema.sql exactly):
--   * status is ONLY pending_payment | paid | preparing | served. There is no
--     'expired' and no 'cancelled': expiry and void are physical DELETEs.
--     purge_expired_orders() is the ONLY TTL DELETE on orders; void_order() is
--     the only other and is fenced to pending_payment, so a paid sale can never
--     be erased. order_items CASCADEs, so items are never deleted on their own.
--   * code is varchar(5) digits, leading zeros preserved, never cast to int.
--   * unit_price comes only from menu_items.sizes_and_prices, never the client.
--   * bad input returns success:false with data:null and an error object, never
--     an exception, so the browser never sees a 500 for a typo.
-- ============================================================================


-- ----------------------------------------------------------------------------
-- create_order :: called by menu.html (customer checkout). The code is generated
-- HERE, server-side, so it is collision-checked atomically - the customer page
-- displays it and never invents it. Sleepless.html is design reference only.
-- items = [{"menu_item_id":"uuid","size":"Regular","quantity":2}]
-- ----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION create_order (customer_name text, items jsonb)
RETURNS jsonb AS
CREATE_ORDER_BODY
DECLARE
  cname text; row_el jsonb; mi_id text; sz text; qty_txt text; qty integer; menu_row jsonb;
  price numeric; resolved jsonb := '[]'::jsonb; total numeric := 0;
  new_order_id uuid; code_uuid uuid; new_code text; inserted boolean := false;
BEGIN
  cname := COALESCE(TRIM(customer_name), '');
  IF cname = '' OR LENGTH(cname) > 100 THEN
    RETURN jsonb_build_object('success', false, 'data', NULL, 'error', jsonb_build_object('code', 'INVALID_CUSTOMER_NAME', 'message', 'customer_name must be 1-100 characters'));
  END IF;
  IF jsonb_typeof(items) <> 'array' OR jsonb_array_length(items) = 0 THEN
    RETURN jsonb_build_object('success', false, 'data', NULL, 'error', jsonb_build_object('code', 'INVALID_ITEMS', 'message', 'items must be a non-empty array'));
  END IF;
  -- resolve every line against the catalogue before anything is written
  FOR idx IN 0 .. jsonb_array_length(items) - 1 LOOP
    row_el := items -> idx;
    IF jsonb_typeof(row_el) <> 'object' THEN
      RETURN jsonb_build_object('success', false, 'data', NULL, 'error', jsonb_build_object('code', 'INVALID_ITEMS', 'message', 'each item must be an object'));
    END IF;
    mi_id := COALESCE(row_el ->> 'menu_item_id', ''); sz := COALESCE(row_el ->> 'size', '');
    qty_txt := COALESCE(row_el ->> 'quantity', '');
    IF mi_id !~ '^[0-9a-fA-F-]{36}$' OR sz = '' OR qty_txt !~ '^[1-9][0-9]{0,2}$' THEN
      RETURN jsonb_build_object('success', false, 'data', NULL, 'error', jsonb_build_object('code', 'INVALID_ITEMS', 'message', 'menu_item_id, size and quantity (1-999) are required'));
    END IF;
    qty := qty_txt::int;
    menu_row := (SELECT jsonb_build_object('name', m.name, 'sizes', m.sizes_and_prices)
                 FROM menu_items AS m WHERE m.id::text = mi_id AND m.is_available = true);
    IF menu_row IS NULL THEN
      RETURN jsonb_build_object('success', false, 'data', NULL, 'error', jsonb_build_object('code', 'MENU_ITEM_UNAVAILABLE', 'message', 'that item is not on the menu right now'));
    END IF;
    -- unit_price is server-authoritative: pulled from the item's own sizes_and_prices
    price := (SELECT (el ->> 'price')::numeric FROM jsonb_array_elements(menu_row -> 'sizes') AS el
              WHERE (el ->> 'size') = sz);
    IF price IS NULL THEN
      RETURN jsonb_build_object('success', false, 'data', NULL, 'error', jsonb_build_object('code', 'INVALID_SIZE', 'message', 'that size is not offered for this item'));
    END IF;

    resolved := resolved + jsonb_build_array(jsonb_build_object('menu_item_id', mi_id, 'item_name', menu_row -> 'name', 'size', sz, 'unit_price', price, 'quantity', qty, 'subtotal', price * qty));
    total := total + price * qty;
  END LOOP;

  new_order_id := gen_random_uuid();
  -- 5-digit code from gen_random_uuid() (CSPRNG-backed). On a UNIQUE violation
  -- (SQLSTATE 23505) the implicit savepoint rolls back only the failed INSERT,
  -- so the loop just draws another code - up to 12 tries.
  FOR attempt IN 1 .. 12 LOOP
    code_uuid := gen_random_uuid();
    new_code := lpad((('x' || SUBSTR(code_uuid::text, 1, 8))::bit(32)::bigint % 100000)::text, 5, '0');
    BEGIN
      -- status and expires_at take the column defaults: pending_payment, now()+60min
      INSERT INTO orders (id, code, customer_name, total_amount) VALUES (new_order_id, new_code, cname, total);
      inserted := true;
      EXIT;
    EXCEPTION WHEN SQLSTATE '23505' THEN NULL; -- code collision, draw another
    END;
  END LOOP;
  IF NOT inserted THEN
    RETURN jsonb_build_object('success', false, 'data', NULL, 'error', jsonb_build_object('code', 'CODE_EXHAUSTED', 'message', 'no free code left, please retry'));
  END IF;
  -- item_name / size snapshotted from menu_items at order time
  INSERT INTO order_items (order_id, menu_item_id, item_name, size, unit_price, quantity, subtotal)
    SELECT new_order_id, (e ->> 'menu_item_id')::uuid, e ->> 'item_name', e ->> 'size',
           (e ->> 'unit_price')::numeric, (e ->> 'quantity')::int, (e ->> 'subtotal')::numeric
      FROM jsonb_array_elements(resolved) AS e;
  RETURN jsonb_build_object('success', true, 'data', jsonb_build_object('code', new_code, 'order_id', new_order_id, 'total', total, 'items_count', jsonb_array_length(resolved)), 'error', NULL);
END;
CREATE_ORDER_BODY;


-- ----------------------------------------------------------------------------
-- get_order_by_code :: cashier.html code lookup. Deliberately does not tell the
-- client whether the code was wrong or simply ran out of time - an expired row
-- no longer exists, so both answers are the same truth.
-- ----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION get_order_by_code (claim_code text)
RETURNS jsonb AS
GET_ORDER_BODY
DECLARE
  row_o jsonb;
BEGIN
  row_o := (SELECT jsonb_build_object(
              'code', o.code, 'customer_name', o.customer_name,
              'status', o.status, 'total_amount', o.total_amount,
              'created_at', o.created_at, 'expires_at', o.expires_at,
              'seconds_remaining', GREATEST(0, EXTRACT(EPOCH FROM (o.expires_at - now()))::int),
              'items_count', (SELECT COUNT(1) FROM order_items AS oi WHERE oi.order_id = o.id))
           FROM orders AS o
           WHERE o.code = claim_code AND o.status = 'pending_payment' AND o.expires_at >= now());

  IF row_o IS NULL THEN
    RETURN jsonb_build_object('success', false, 'data', NULL, 'error', jsonb_build_object('code', 'ORDER_NOT_FOUND', 'message', 'that order is not open any more'));
  END IF;
  RETURN jsonb_build_object('success', true, 'data', row_o, 'error', NULL);
END;
GET_ORDER_BODY;


-- ----------------------------------------------------------------------------
-- purge_expired_orders :: the TTL sweep. ONLY DELETE on orders for expiry.
-- Called by list_active_pending / kitchen_queue (the boards) and by the
-- cashier page before it reads anything.
-- ----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION purge_expired_orders()
RETURNS jsonb AS
PURGE_BODY
DECLARE
  removed integer;
BEGIN
  SELECT COUNT(1) FROM orders AS o WHERE o.status = 'pending_payment' AND o.expires_at < now() INTO removed;
  -- CASCADE removes the line items; they are never touched directly
  DELETE FROM orders AS o WHERE o.status = 'pending_payment' AND o.expires_at < now();
  RETURN jsonb_build_object('success', true, 'data', jsonb_build_object('removed', removed), 'error', NULL);
END;
PURGE_BODY;


-- ----------------------------------------------------------------------------
-- list_active_pending :: ORDERS BOARD page (the live "waiting for payment"
-- list). Purges first so the board can never show a dead claim.
-- ----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION list_active_pending()
RETURNS jsonb AS
LIST_PENDING_BODY
DECLARE
  rows jsonb := '[]'::jsonb;
BEGIN
  SELECT purge_expired_orders();
  rows := COALESCE((SELECT jsonb_agg(jsonb_build_object(
                'order_id', o.id,
                'code', o.code, 'customer_name', o.customer_name,
                'created_at', o.created_at, 'expires_at', o.expires_at,
                'seconds_remaining', GREATEST(0, EXTRACT(EPOCH FROM (o.expires_at - now()))::int),
                'items_count', (SELECT COUNT(1) FROM order_items AS oi WHERE oi.order_id = o.id),
                'total_amount', o.total_amount)
              FROM orders AS o
              WHERE o.status = 'pending_payment' AND o.expires_at >= now()
              ORDER BY o.created_at DESC), '[]'::jsonb);
  RETURN jsonb_build_object('success', true, 'data', rows, 'error', NULL);
END;
LIST_PENDING_BODY;


-- ----------------------------------------------------------------------------
-- confirm_payment :: PAYMENT page (customer taps "I'm paying"). The UPDATE is
-- fenced on status AND expiry, so a stale claim cannot be paid.
-- ----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION confirm_payment (claim_code text)
RETURNS jsonb AS
CONFIRM_BODY
DECLARE
  stamp timestamptz;
  row_o jsonb;
BEGIN
  stamp := now();
  UPDATE orders AS o
    SET status = 'paid', paid_at = stamp
    WHERE o.code = claim_code AND o.status = 'pending_payment' AND o.expires_at >= stamp;

  -- paid_at = stamp identifies exactly the row this call transitioned
  row_o := (SELECT jsonb_build_object(
              'code', o.code, 'customer_name', o.customer_name,
              'status', o.status, 'total_amount', o.total_amount,
              'paid_at', o.paid_at,
              'items_count', (SELECT COUNT(1) FROM order_items AS oi WHERE oi.order_id = o.id))
           FROM orders AS o
           WHERE o.code = claim_code AND o.status = 'paid' AND o.paid_at = stamp);

  IF row_o IS NULL THEN
    RETURN jsonb_build_object('success', false, 'data', NULL, 'error', jsonb_build_object('code', 'ORDER_EXPIRED', 'message', 'This order''s time is up, please place a new one'));
  END IF;
  RETURN jsonb_build_object('success', true, 'data', row_o, 'error', NULL);
END;
CONFIRM_BODY;


-- ----------------------------------------------------------------------------
-- kitchen_queue :: KITCHEN BOARD page (kitchen.html). Purges dead claims first,
-- then lists the orders the kitchen still owes, oldest-paid first. 'preparing'
-- is included so a cook tapping set_preparing cannot silently lose the card.
-- ----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION kitchen_queue()
RETURNS jsonb AS
KITCHEN_BODY
DECLARE
  rows jsonb := '[]'::jsonb;
BEGIN
  SELECT purge_expired_orders();
  rows := COALESCE((SELECT jsonb_agg(jsonb_build_object(
                'order_id', o.id,
                'code', o.code, 'customer_name', o.customer_name,
                'status', o.status, 'paid_at', o.paid_at,
                'elapsed_seconds', GREATEST(0, EXTRACT(EPOCH FROM (now() - o.paid_at))::int),
                'items', COALESCE((SELECT jsonb_agg(jsonb_build_object(
                    'item_name', oi.item_name, 'size', oi.size,
                    'quantity', oi.quantity, 'unit_price', oi.unit_price,
                    'subtotal', oi.subtotal))
                 FROM order_items AS oi WHERE oi.order_id = o.id), '[]'::jsonb))
              FROM orders AS o
              WHERE o.status = 'paid' OR o.status = 'preparing'
              ORDER BY o.paid_at ASC), '[]'::jsonb);
  RETURN jsonb_build_object('success', true, 'data', rows, 'error', NULL);
END;
KITCHEN_BODY;


-- ----------------------------------------------------------------------------
-- mark_served :: KITCHEN BOARD page (cook taps "done"). Only paid or preparing
-- can be served; the schema CHECKs then require paid_at / served_at.
-- fulfillment_time_seconds is total seconds (EXTRACT EPOCH), which is the
-- sub-hour EXTRACT(SECOND ...) the spec describes, kept correct past 1 hour.
-- ----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION mark_served (order_id uuid)
RETURNS jsonb AS
SERVE_BODY
DECLARE
  stamp timestamptz;
  row_o jsonb;
BEGIN
  stamp := now();
  UPDATE orders AS o
    SET status = 'served',
        served_at = stamp,
        fulfillment_time_seconds = GREATEST(0, EXTRACT(EPOCH FROM (stamp - o.paid_at))::int)
    WHERE o.id = order_id AND (o.status = 'paid' OR o.status = 'preparing');

  row_o := (SELECT jsonb_build_object(
              'order_id', o.id, 'code', o.code, 'customer_name', o.customer_name,
              'status', o.status, 'served_at', o.served_at,
              'fulfillment_time_seconds', o.fulfillment_time_seconds)
           FROM orders AS o
           WHERE o.id = order_id AND o.status = 'served' AND o.served_at = stamp);

  IF row_o IS NULL THEN
    RETURN jsonb_build_object('success', false, 'data', NULL, 'error', jsonb_build_object('code', 'NOT_SERVABLE', 'message', 'that order is not waiting in the kitchen'));
  END IF;
  RETURN jsonb_build_object('success', true, 'data', row_o, 'error', NULL);
END;
SERVE_BODY;


-- ----------------------------------------------------------------------------
-- set_preparing :: KITCHEN BOARD page - optional hold so a cook can claim a
-- paid order without finishing it. paid -> preparing only; re-tapping an order
-- that is already preparing is a harmless no-op success.
-- ----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION set_preparing (order_id uuid)
RETURNS jsonb AS
PREPARE_BODY
DECLARE
  row_o jsonb;
BEGIN
  UPDATE orders AS o
    SET status = 'preparing'
    WHERE o.id = order_id AND o.status = 'paid';

  row_o := (SELECT jsonb_build_object('order_id', o.id, 'code', o.code, 'customer_name', o.customer_name, 'status', o.status, 'paid_at', o.paid_at)
           FROM orders AS o WHERE o.id = order_id AND o.status = 'preparing');

  IF row_o IS NULL THEN
    RETURN jsonb_build_object('success', false, 'data', NULL, 'error', jsonb_build_object('code', 'NOT_PREPARABLE', 'message', 'that order is not waiting to be cooked'));
  END IF;
  RETURN jsonb_build_object('success', true, 'data', row_o, 'error', NULL);
END;
PREPARE_BODY;


-- ----------------------------------------------------------------------------
-- void_order :: CASHIER page, cancelling an UNPAID claim early. Same removal
-- mechanism as the TTL sweep, fenced to pending_payment so a paid sale can
-- never be deleted here. CASCADE removes its line items.
-- ----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION void_order (order_id uuid)
RETURNS jsonb AS
VOID_BODY
DECLARE
  row_o jsonb;
BEGIN
  row_o := (SELECT jsonb_build_object('order_id', o.id, 'code', o.code, 'customer_name', o.customer_name, 'total_amount', o.total_amount)
           FROM orders AS o WHERE o.id = order_id AND o.status = 'pending_payment');
  IF row_o IS NULL THEN
    RETURN jsonb_build_object('success', false, 'data', NULL, 'error', jsonb_build_object('code', 'NOT_VOIDABLE', 'message', 'that order is not an open unpaid claim'));
  END IF;
  DELETE FROM orders AS o WHERE o.id = order_id AND o.status = 'pending_payment';
  RETURN jsonb_build_object('success', true, 'data', row_o + jsonb_build_object('voided', true), 'error', NULL);
END;
VOID_BODY;


-- ============================================================================
-- ===== PHASE 5: OWNER ANALYTICS + MENU BUILDER =====
-- OWNER GATE: each fn below reads the caller's JWT claims via the Supabase
-- idiom SYSTEM_GETENV('request.jwt.claims'). Presence check ONLY - it proves a
-- signed-in session, it is NOT the allowlist (CONFIG.ownerEmails is checked
-- page-side; RLS in 03_rls.sql plus this guard are the boundary). `from`, `to`
-- and `order` are reserved words, so params are from_time / to_time / new_order.
-- ----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION sales_summary (from_time timestamptz, to_time timestamptz, grain text)
RETURNS jsonb AS
SALES_SUMMARY_BODY
DECLARE
  claims jsonb; email text; fmt text;
  rev numeric := 0; cnt integer := 0; aov numeric := 0; buckets jsonb := '[]'::jsonb;
BEGIN
  claims := COALESCE(NULLIF(SYSTEM_GETENV('request.jwt.claims'), '')::jsonb, '{}');
  email := COALESCE(claims ->> 'email', '');
  IF email = '' THEN RETURN jsonb_build_object('success', false, 'data', NULL, 'error', jsonb_build_object('code', 'OWNER_SESSION_REQUIRED', 'message', 'menu changes need a signed-in owner session')); END IF;
  IF grain NOT IN ('daily', 'monthly', 'yearly') THEN RETURN jsonb_build_object('success', false, 'data', NULL, 'error', jsonb_build_object('code', 'INVALID_GRAIN', 'message', 'grain must be daily, monthly or yearly')); END IF;
  fmt := CASE grain WHEN 'yearly' THEN 'YYYY' WHEN 'monthly' THEN 'YYYY-MM' ELSE 'YYYY-MM-DD' END;
  -- completed sales ONLY: status 'served', paid inside the window
  rev := COALESCE((SELECT SUM(o.total_amount) FROM orders AS o WHERE o.status = 'served' AND o.paid_at >= from_time AND o.paid_at <= to_time), 0);
  cnt := COALESCE((SELECT COUNT(*) FROM orders AS o WHERE o.status = 'served' AND o.paid_at >= from_time AND o.paid_at <= to_time), 0);
  aov := CASE WHEN cnt > 0 THEN ROUND(rev / cnt, 2) ELSE 0 END;
  buckets := COALESCE((SELECT jsonb_agg(jsonb_build_object('label', b.label, 'revenue', b.rev, 'count', b.cnt)
                        FROM (SELECT to_char(o.paid_at, fmt) AS label, SUM(o.total_amount) AS rev, COUNT(*) AS cnt
                              FROM orders AS o WHERE o.status = 'served' AND o.paid_at >= from_time AND o.paid_at <= to_time
                              GROUP BY to_char(o.paid_at, fmt) ORDER BY to_char(o.paid_at, fmt)) AS b),
                      '[]'::jsonb);
  RETURN jsonb_build_object('success', true, 'data', jsonb_build_object('revenue', rev, 'completed_count', cnt, 'aov', aov, 'grain', grain, 'buckets', buckets), 'error', NULL);
END;
SALES_SUMMARY_BODY;
-- ----------------------------------------------------------------------------
-- turnover_stats :: peak_hours is a heatmap of PAID orders only - an abandoned
-- claim leaves zero trace by design (TTL DELETE), so demand is never inflated.
-- ----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION turnover_stats (from_time timestamptz, to_time timestamptz)
RETURNS jsonb AS
TURNOVER_STATS_BODY
DECLARE
  claims jsonb; email text; cnt integer := 0;
  avg_s integer := 0; p95_s integer := 0; peak_hours jsonb := '[]'::jsonb;
BEGIN
  claims := COALESCE(NULLIF(SYSTEM_GETENV('request.jwt.claims'), '')::jsonb, '{}');
  email := COALESCE(claims ->> 'email', '');
  IF email = '' THEN RETURN jsonb_build_object('success', false, 'data', NULL, 'error', jsonb_build_object('code', 'OWNER_SESSION_REQUIRED', 'message', 'menu changes need a signed-in owner session')); END IF;
  cnt := COALESCE((SELECT COUNT(*) FROM orders AS o WHERE o.status = 'served' AND o.paid_at >= from_time AND o.paid_at <= to_time), 0);
  avg_s := COALESCE((SELECT AVG(o.fulfillment_time_seconds)::int FROM orders AS o WHERE o.status = 'served' AND o.paid_at >= from_time AND o.paid_at <= to_time), 0);
  -- p95 by position: sort the durations, skip FLOOR(count*0.95) rows, take the next one.
  -- FLOOR matters: with ::int alone, 10 samples gives OFFSET 10 (9.5 rounds up) and the
  -- LIMIT 1 finds nothing, so p95 would read 0. FLOOR keeps the index inside the range.
  p95_s := COALESCE((SELECT o.fulfillment_time_seconds FROM orders AS o
                     WHERE o.status = 'served' AND o.paid_at >= from_time AND o.paid_at <= to_time
                     ORDER BY o.fulfillment_time_seconds ASC OFFSET FLOOR(cnt * 0.95)::int LIMIT 1), 0);
  peak_hours := COALESCE((SELECT jsonb_agg(jsonb_build_object('hour', t.hour, 'orders', t.orders)
                            FROM (SELECT EXTRACT(HOUR FROM o.created_at)::int AS hour, COUNT(*) AS orders
                                  FROM orders AS o WHERE o.status = 'served' AND o.paid_at >= from_time AND o.paid_at <= to_time
                                  GROUP BY EXTRACT(HOUR FROM o.created_at)::int ORDER BY EXTRACT(HOUR FROM o.created_at)::int) AS t),
                          '[]'::jsonb);
  RETURN jsonb_build_object('success', true, 'data', jsonb_build_object('sample_size', cnt, 'avg_fulfillment_seconds', avg_s, 'p95_fulfillment_seconds', p95_s, 'peak_hours', peak_hours), 'error', NULL);
END;
TURNOVER_STATS_BODY;
-- ----------------------------------------------------------------------------
-- create_category :: OWNER page, display_order is the shelf position.
-- ----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION create_category (name text, display_order integer)
RETURNS jsonb AS
CREATE_CATEGORY_BODY
DECLARE
  claims jsonb; email text; new_id uuid;
BEGIN
  claims := COALESCE(NULLIF(SYSTEM_GETENV('request.jwt.claims'), '')::jsonb, '{}');
  email := COALESCE(claims ->> 'email', '');
  IF email = '' THEN RETURN jsonb_build_object('success', false, 'data', NULL, 'error', jsonb_build_object('code', 'OWNER_SESSION_REQUIRED', 'message', 'menu changes need a signed-in owner session')); END IF;
  IF COALESCE(TRIM(name), '') = '' OR LENGTH(TRIM(name)) > 80 THEN RETURN jsonb_build_object('success', false, 'data', NULL, 'error', jsonb_build_object('code', 'INVALID_CATEGORY_NAME', 'message', 'category name must be 1-80 characters')); END IF;
  new_id := gen_random_uuid();
  INSERT INTO categories (id, name, display_order) VALUES (new_id, TRIM(name), COALESCE(display_order, 0));
  RETURN jsonb_build_object('success', true, 'data', jsonb_build_object('category_id', new_id), 'error', NULL);
END;
CREATE_CATEGORY_BODY;
-- ----------------------------------------------------------------------------
-- reorder_categories :: new_order = array of category uuids in the wanted order;
-- display_order := array index. Categories left out keep their old position.
-- ----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION reorder_categories (new_order jsonb)
RETURNS jsonb AS
REORDER_CATEGORIES_BODY
DECLARE
  claims jsonb; email text; raw text; target uuid; touched integer := 0;
BEGIN
  claims := COALESCE(NULLIF(SYSTEM_GETENV('request.jwt.claims'), '')::jsonb, '{}');
  email := COALESCE(claims ->> 'email', '');
  IF email = '' THEN RETURN jsonb_build_object('success', false, 'data', NULL, 'error', jsonb_build_object('code', 'OWNER_SESSION_REQUIRED', 'message', 'menu changes need a signed-in owner session')); END IF;
  IF jsonb_typeof(new_order) <> 'array' THEN RETURN jsonb_build_object('success', false, 'data', NULL, 'error', jsonb_build_object('code', 'INVALID_ORDER', 'message', 'new_order must be an array of category uuids')); END IF;
  FOR idx IN 0 .. jsonb_array_length(new_order) - 1 LOOP
    raw := COALESCE(new_order -> idx ->> '', '');
    IF raw !~ '^[0-9a-fA-F-]{36}$' THEN RETURN jsonb_build_object('success', false, 'data', NULL, 'error', jsonb_build_object('code', 'INVALID_ORDER', 'message', 'every entry must be a category uuid')); END IF;
    target := raw::uuid;
    UPDATE categories AS c SET display_order = idx WHERE c.id = target;
    touched := touched + 1;
  END LOOP;
  RETURN jsonb_build_object('success', true, 'data', jsonb_build_object('reordered', touched), 'error', NULL);
END;
REORDER_CATEGORIES_BODY;
-- ----------------------------------------------------------------------------
-- delete_category :: 01_schema.sql has ON DELETE RESTRICT on menu_items.category_id,
-- so a category with live items cannot be deleted directly. Order of operations
-- is what satisfies that CHECK: children are reassigned to fallback_category_id
-- (or deleted when none is given) BEFORE the category row is dropped.
-- ----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION delete_category (category_id uuid, fallback_category_id uuid DEFAULT NULL)
RETURNS jsonb AS
DELETE_CATEGORY_BODY
DECLARE
  claims jsonb; email text; cat jsonb; fb jsonb;
  moved integer := 0;
BEGIN
  claims := COALESCE(NULLIF(SYSTEM_GETENV('request.jwt.claims'), '')::jsonb, '{}');
  email := COALESCE(claims ->> 'email', '');
  IF email = '' THEN RETURN jsonb_build_object('success', false, 'data', NULL, 'error', jsonb_build_object('code', 'OWNER_SESSION_REQUIRED', 'message', 'menu changes need a signed-in owner session')); END IF;
  cat := (SELECT jsonb_build_object('category_id', c.id, 'name', c.name) FROM categories AS c WHERE c.id = category_id);
  IF cat IS NULL THEN RETURN jsonb_build_object('success', false, 'data', NULL, 'error', jsonb_build_object('code', 'CATEGORY_NOT_FOUND', 'message', 'that category is not on the menu')); END IF;
  IF fallback_category_id IS NOT NULL THEN
    fb := (SELECT jsonb_build_object('found', true) FROM categories AS c WHERE c.id = fallback_category_id);
    IF fb IS NULL OR fallback_category_id = category_id THEN RETURN jsonb_build_object('success', false, 'data', NULL, 'error', jsonb_build_object('code', 'INVALID_FALLBACK', 'message', 'fallback_category_id must be a different existing category')); END IF;
  END IF;
  moved := COALESCE((SELECT COUNT(*) FROM menu_items AS m WHERE m.category_id = category_id), 0);
  IF fallback_category_id IS NOT NULL THEN
    UPDATE menu_items AS m SET category_id = fallback_category_id WHERE m.category_id = category_id;
  ELSE
    DELETE FROM menu_items AS m WHERE m.category_id = category_id;
  END IF;
  DELETE FROM categories AS c WHERE c.id = category_id;
  RETURN jsonb_build_object('success', true, 'data', cat + jsonb_build_object('items_moved', moved, 'items_deleted', CASE WHEN fallback_category_id IS NULL THEN moved ELSE 0 END, 'fallback_category_id', fallback_category_id), 'error', NULL);
END;
DELETE_CATEGORY_BODY;
-- ----------------------------------------------------------------------------
-- create_menu_item :: sizes_and_prices validated against the same CHECK shape as
-- 01_schema.sql (non-empty array of {size,price}) so bad input returns envelope.
-- ----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION create_menu_item (category_id uuid, name text, description text, image_url text, sizes_and_prices jsonb, is_available boolean)
RETURNS jsonb AS
CREATE_MENU_ITEM_BODY
DECLARE
  claims jsonb; email text; cat jsonb; el jsonb; new_id uuid;
BEGIN
  claims := COALESCE(NULLIF(SYSTEM_GETENV('request.jwt.claims'), '')::jsonb, '{}');
  email := COALESCE(claims ->> 'email', '');
  IF email = '' THEN RETURN jsonb_build_object('success', false, 'data', NULL, 'error', jsonb_build_object('code', 'OWNER_SESSION_REQUIRED', 'message', 'menu changes need a signed-in owner session')); END IF;
  cat := (SELECT jsonb_build_object('found', true) FROM categories AS c WHERE c.id = category_id);
  IF cat IS NULL THEN RETURN jsonb_build_object('success', false, 'data', NULL, 'error', jsonb_build_object('code', 'CATEGORY_NOT_FOUND', 'message', 'that category is not on the menu')); END IF;
  IF COALESCE(TRIM(name), '') = '' OR LENGTH(TRIM(name)) > 120 THEN RETURN jsonb_build_object('success', false, 'data', NULL, 'error', jsonb_build_object('code', 'INVALID_ITEM_NAME', 'message', 'item name must be 1-120 characters')); END IF;
  IF jsonb_typeof(sizes_and_prices) <> 'array' OR jsonb_array_length(sizes_and_prices) < 1 THEN RETURN jsonb_build_object('success', false, 'data', NULL, 'error', jsonb_build_object('code', 'INVALID_SIZES', 'message', 'sizes_and_prices must be a non-empty array')); END IF;
  FOR idx IN 0 .. jsonb_array_length(sizes_and_prices) - 1 LOOP
    el := sizes_and_prices -> idx;
    IF jsonb_typeof(el) <> 'object'
       OR COALESCE(el ->> 'size', '') = ''
       OR jsonb_typeof(el -> 'price') <> 'number' THEN
      RETURN jsonb_build_object('success', false, 'data', NULL, 'error', jsonb_build_object('code', 'INVALID_SIZES', 'message', 'each entry needs a size and a numeric price'));
    END IF;
  END LOOP;
  new_id := gen_random_uuid();
  INSERT INTO menu_items (id, category_id, name, description, image_url, sizes_and_prices, is_available)
    VALUES (new_id, category_id, TRIM(name), COALESCE(description, ''), COALESCE(image_url, ''), sizes_and_prices, COALESCE(is_available, true));
  RETURN jsonb_build_object('success', true, 'data', jsonb_build_object('menu_item_id', new_id), 'error', NULL);
END;
CREATE_MENU_ITEM_BODY;
-- ----------------------------------------------------------------------------
-- update_menu_item :: COALESCE patch. '' or null means leave as is for the text
-- fields, null keeps sizes_and_prices, null is_available keeps the current flag.
-- ----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION update_menu_item (menu_item_id uuid, name text DEFAULT '', description text DEFAULT '', image_url text DEFAULT '', sizes_and_prices jsonb DEFAULT NULL, is_available boolean DEFAULT NULL)
RETURNS jsonb AS
UPDATE_MENU_ITEM_BODY
DECLARE
  claims jsonb; email text; current jsonb; patched jsonb;
BEGIN
  claims := COALESCE(NULLIF(SYSTEM_GETENV('request.jwt.claims'), '')::jsonb, '{}');
  email := COALESCE(claims ->> 'email', '');
  IF email = '' THEN RETURN jsonb_build_object('success', false, 'data', NULL, 'error', jsonb_build_object('code', 'OWNER_SESSION_REQUIRED', 'message', 'menu changes need a signed-in owner session')); END IF;
  current := (SELECT jsonb_build_object('name', m.name, 'description', m.description, 'image_url', m.image_url,
                                        'sizes_and_prices', m.sizes_and_prices, 'is_available', m.is_available)
               FROM menu_items AS m WHERE m.id = menu_item_id);
  IF current IS NULL THEN RETURN jsonb_build_object('success', false, 'data', NULL, 'error', jsonb_build_object('code', 'MENU_ITEM_NOT_FOUND', 'message', 'that item is not on the menu')); END IF;
  -- '' (or null) means "keep the current name", so the length CHECK only applies
  -- when a name was actually supplied. Validating the blank default would make
  -- every patch call fail.
  IF NULLIF(TRIM(COALESCE(name, '')), '') IS NOT NULL
     AND LENGTH(TRIM(name)) > 120 THEN RETURN jsonb_build_object('success', false, 'data', NULL, 'error', jsonb_build_object('code', 'INVALID_ITEM_NAME', 'message', 'item name must be 1-120 characters')); END IF;
  IF sizes_and_prices IS NOT NULL AND (jsonb_typeof(sizes_and_prices) <> 'array' OR jsonb_array_length(sizes_and_prices) < 1) THEN RETURN jsonb_build_object('success', false, 'data', NULL, 'error', jsonb_build_object('code', 'INVALID_SIZES', 'message', 'sizes_and_prices must be a non-empty array or null to keep')); END IF;
  UPDATE menu_items AS m
    WHERE m.id = menu_item_id
    SET name = COALESCE(NULLIF(TRIM(COALESCE(name, '')), ''), m.name),
        description = CASE WHEN COALESCE(description, '') = '' THEN m.description ELSE description END,
        image_url = CASE WHEN COALESCE(image_url, '') = '' THEN m.image_url ELSE image_url END,
        sizes_and_prices = COALESCE(sizes_and_prices, m.sizes_and_prices),
        is_available = COALESCE(is_available, m.is_available);
  patched := (SELECT jsonb_build_object('menu_item_id', m.id, 'category_id', m.category_id, 'name', m.name,
                                        'description', m.description, 'image_url', m.image_url,
                                        'sizes_and_prices', m.sizes_and_prices, 'is_available', m.is_available)
               FROM menu_items AS m WHERE m.id = menu_item_id);
  RETURN jsonb_build_object('success', true, 'data', patched, 'error', NULL);
END;
UPDATE_MENU_ITEM_BODY;
-- ============================================================================
-- END 02_functions.sql
-- ============================================================================
