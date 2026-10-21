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
--
-- FIX: jsonb has NO `+` operator. `||` is the jsonb concat/merge operator
--   (array||array appends elements, so `[] || [x]` yields `[x]`; object||object
--   merges keys). plpgsql is parsed lazily, so `CREATE OR REPLACE FUNCTION`
--   compiles fine and an unknown-operator error (42883: jsonb + jsonb) only
--   surfaces at CALL time - a function can "apply" cleanly and still be broken.
--   Three such sites were corrected from `+` to `||`: create_order (append to
--   the resolved array), void_order (merge row_o), delete_category (merge cat).
--
-- FIX: a bare `SELECT func();` inside a plpgsql body is rejected (42601: query
--   has no destination for result data) - unlike top-level SQL, a SELECT in a
--   function MUST route its result somewhere (an assignment, or INTO). To call a
--   function purely for its side effect, PG 13+ (so PG 15) provides the PERFORM
--   statement, which discards the result. Same lazy-parse caveat as the jsonb
--   case: CREATE OR REPLACE FUNCTION still "applies" cleanly and the 42601 only
--   surfaces at CALL time. Two sites fixed SELECT -> PERFORM: list_active_pending
--   and kitchen_queue (both call purge_expired_orders() for its DELETE side effect).
--
-- FIX: an ORDER BY written at the QUERY level of a SELECT whose projection is an
--   aggregate (jsonb_agg(...)) is rejected (42803: column "o.created_at" must
--   appear in the GROUP BY clause or be used in an aggregate function) - and even
--   where it parses it sorts the aggregate's single result row, not the elements
--   inside the array, so it orders nothing useful. To order the ELEMENTS inside an
--   aggregate, PostgreSQL's aggregate sort clause puts ORDER BY INSIDE the call:
--   jsonb_agg(expr ORDER BY key). This also matters semantically: the board must
--   be newest-claim-first and the kitchen queue oldest-paid-first, so the sort has
--   to apply to the array elements. Same lazy-parse caveat as above: CREATE OR
--   REPLACE FUNCTION still "applies" cleanly and the 42803 only surfaces at CALL
--   time. Two sites fixed, query-level ORDER BY moved inside the outer jsonb_agg:
--   list_active_pending (ORDER BY o.created_at DESC) and kitchen_queue
--   (ORDER BY o.paid_at ASC). The other ORDER BY occurrences (GROUP BY-keyed
--   subqueries and LIMIT-ed scalar subqueries) are legal and left untouched.
--
-- FIX: SYSTEM_GETENV('request.jwt.claims') is a PostgreSQL 16+ builtin and is
--   absent on this PG 15 project, so every Phase 5 owner gate fails at CALL time
--   (42883: function system_getenv(unknown) does not exist) even though plpgsql
--   parses lazily and the function "applies" cleanly. On PG 15 the request-scoped
--   custom setting is read with current_setting(name, true); the DEFINE_DEFAULT
--   second argument (true) is REQUIRED because the one-argument form raises
--   42704 (unrecognized configuration parameter) when the setting is unset,
--   whereas the two-argument form returns '' instead. Seven owner-gate sites
--   fixed to COALESCE(NULLIF(current_setting('request.jwt.claims', true),
--   '')::jsonb, '{}').
--
-- FIX: `-> idx ->> ''` is NOT "array element as text". `jsonb -> integer` returns
--   the array ELEMENT still wrapped as jsonb, and the chained `->> ''` then looks
--   up an object KEY named the empty string, which never exists, so the whole
--   expression is always NULL (verified live on PG 15: '["...uuid..."]'::jsonb ->
--   0 ->> '' = NULL, while '["...uuid..."]'::jsonb ->> 0 = the uuid as text). In
--   reorder_categories that makes `raw` always '', which fails the uuid regex and
--   returns INVALID_ORDER for EVERY call, so the function can never succeed. The
--   correct element-as-text accessor is `->> idx` (`->>` with an integer index
--   yields the element as text, which is what the uuid regex and raw::uuid need).
--   One site fixed: reorder_categories `new_order -> idx ->> ''` -> `new_order ->>
--   idx`. This class differs from the previous four: it raises NO error at all,
--   parses and "applies" cleanly, and silently always fails at runtime, which is
--   why live call-testing of every function is the only thing that catches it.
--
-- FIX: sales_summary and turnover_stats ordered their buckets/peak_hours with an
--   ORDER BY on the GROUP BY-keyed SUBQUERY feeding jsonb_agg. PostgreSQL applies
--   a subquery's ORDER BY when it materialises it, but that ordering is not part of
--   the aggregate's contract, so the array order is unspecified rather than stated.
--   Same two sites, sort moved into the aggregate sort clause: jsonb_agg(expr ORDER
--   BY b.label ASC) and jsonb_agg(expr ORDER BY t.hour ASC), with the subquery ORDER
--   BY dropped. Verified live with three planted served orders across two days and
--   three hours: buckets came back 2026-10-18 then 2026-10-19 and peak_hours 9, 14,
--   20, and p95 read 300 (OFFSET FLOOR(3*0.95)=2 over [100,200,300]), so revenue,
--   aov, avg and p95 math all check out.
--
-- NOTE: items_count is CUPS (SUM(order_items.quantity)), never COUNT(1) over
--   order_items - the cashier board column is headed "No. of Items/Drinks" and a
--   customer cart counts cups, so a 2-line cart (Americano x2 + Long Black x5)
--   reports 7, not 2. Four sites fixed in create_order, claim_view, list_active_pending
--   and confirm_payment; the `lines` local in set_claim_item_qty legitimately still
--   counts LINES for its LAST_LINE_ONLY guard and is left alone. sales_report is the
--   CSV-grade sibling of sales_summary (per-sale / per-day / per-month rows behind the
--   headline numbers, completed 'served' sales only).
--
-- DEPENDS ON 07_staff_roster.sql AT CALL TIME: jwt_claims_email()/roster_role_of()
--   are defined there; plpgsql resolves those calls at runtime, so the apply order
--   01->02->03->04->05->06->07 must complete before any function here is called.
-- ============================================================================


-- ----------------------------------------------------------------------------
-- create_order :: called by menu.html (customer checkout). The code is generated
-- HERE, server-side, so it is collision-checked atomically - the customer page
-- displays it and never invents it. Sleepless.html is design reference only.
-- items = [{"menu_item_id":"uuid","size":"Regular","quantity":2}]
-- ----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION create_order (customer_name text, items jsonb)
RETURNS jsonb AS $$
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

    resolved := resolved || jsonb_build_array(jsonb_build_object('menu_item_id', mi_id, 'item_name', menu_row -> 'name', 'size', sz, 'unit_price', price, 'quantity', qty, 'subtotal', price * qty));
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
      -- status and expires_at take the column defaults: pending_payment, now()+30min
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
  RETURN jsonb_build_object('success', true, 'data', jsonb_build_object('code', new_code, 'order_id', new_order_id, 'total', total, 'items_count', COALESCE((SELECT SUM((e ->> 'quantity')::int) FROM jsonb_array_elements(resolved) AS e), 0)), 'error', NULL);
END;
$$ LANGUAGE plpgsql;


-- ----------------------------------------------------------------------------
-- claim_view :: the cashier's view of ONE live unpaid claim, LINE ITEMS included,
-- so cashier.html can show the claim as editable cart lines exactly like the
-- customer cart in menu.html. get_order_by_code, set_claim_item_qty and add_claim_item
-- all return this same shape, which is what lets a cashier edit repaint from
-- SERVER truth (recomputed total included) instead of a client-side guess.
-- Returns NULL when the claim is not a live unpaid one - callers turn that into
-- their own envelope copy, so this stays the single definition of "open claim".
-- item_id is the order_items row id: the only stable handle a page can address a
-- single line by, since two lines of the same item+size never exist (add_claim_item
-- merges them) and quantity is a column rather than one row per unit.
-- items_count is CUPS (SUM of order_items.quantity), not lines: the cashier board
--   column is headed "No. of Items/Drinks" and a customer cart counts cups.
-- ----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION claim_view (p_order_id uuid)
RETURNS jsonb AS $$
DECLARE
  email text; role text;
BEGIN
  -- station fence (roster): claim_view runs for cashier only — sql/07 roster_role_of
  email := jwt_claims_email();
  role := roster_role_of(email);
  IF email = '' THEN RETURN jsonb_build_object('success', false, 'data', NULL, 'error', jsonb_build_object('code', 'STAFF_SESSION_REQUIRED', 'message', 'this surface needs a signed-in staff session')); END IF;
  IF role = '' THEN RETURN jsonb_build_object('success', false, 'data', NULL, 'error', jsonb_build_object('code', 'STAFF_NOT_REGISTERED', 'message', 'this signed-in email is not on the active staff roster')); END IF;
  IF role NOT IN ('cashier') THEN RETURN jsonb_build_object('success', false, 'data', NULL, 'error', jsonb_build_object('code', 'WRONG_STATION', 'message', 'this surface runs for cashier only')); END IF;
  RETURN (SELECT jsonb_build_object(
              'order_id', o.id,
              'code', o.code, 'customer_name', o.customer_name,
              'status', o.status, 'total_amount', o.total_amount,
              'created_at', o.created_at, 'expires_at', o.expires_at,
              'seconds_remaining', GREATEST(0, EXTRACT(EPOCH FROM (o.expires_at - now()))::int),
              'items_count', COALESCE((SELECT SUM(oi.quantity) FROM order_items AS oi WHERE oi.order_id = o.id), 0),
              'items', COALESCE((SELECT jsonb_agg(jsonb_build_object(
                    'item_id', oi.id, 'menu_item_id', oi.menu_item_id,
                    'item_name', oi.item_name, 'size', oi.size,
                    'quantity', oi.quantity, 'unit_price', oi.unit_price,
                    'subtotal', oi.subtotal)
                  ORDER BY oi.item_name ASC, oi.size ASC)
                FROM order_items AS oi WHERE oi.order_id = o.id), '[]'::jsonb))
           FROM orders AS o
           WHERE o.id = p_order_id AND o.status = 'pending_payment' AND o.expires_at >= now());
END;
$$ LANGUAGE plpgsql;


-- ----------------------------------------------------------------------------
-- get_order_by_code :: cashier.html code lookup. Deliberately does not tell the
-- client whether the code was wrong or simply ran out of time - an expired row
-- no longer exists, so both answers are the same truth. Delegates the shape to
-- claim_view so the lookup and every later edit return one identical view.
-- ----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION get_order_by_code (claim_code text)
RETURNS jsonb AS $$
DECLARE
  open_id uuid;
  row_o jsonb;
  email text;
  role text;
BEGIN
  -- station fence (roster): get_order_by_code runs for cashier, owner — sql/07 roster_role_of
  email := jwt_claims_email();
  role := roster_role_of(email);
  IF email = '' THEN RETURN jsonb_build_object('success', false, 'data', NULL, 'error', jsonb_build_object('code', 'STAFF_SESSION_REQUIRED', 'message', 'this surface needs a signed-in staff session')); END IF;
  IF role = '' THEN RETURN jsonb_build_object('success', false, 'data', NULL, 'error', jsonb_build_object('code', 'STAFF_NOT_REGISTERED', 'message', 'this signed-in email is not on the active staff roster')); END IF;
  IF role NOT IN ('cashier', 'owner') THEN RETURN jsonb_build_object('success', false, 'data', NULL, 'error', jsonb_build_object('code', 'WRONG_STATION', 'message', 'this surface runs for cashier or owner')); END IF;
  open_id := (SELECT o.id FROM orders AS o
              WHERE o.code = claim_code AND o.status = 'pending_payment' AND o.expires_at >= now());
  IF open_id IS NULL THEN
    RETURN jsonb_build_object('success', false, 'data', NULL, 'error', jsonb_build_object('code', 'ORDER_NOT_FOUND', 'message', 'that order is not open any more'));
  END IF;
  row_o := claim_view(open_id);
  IF row_o IS NULL THEN
    RETURN jsonb_build_object('success', false, 'data', NULL, 'error', jsonb_build_object('code', 'ORDER_NOT_FOUND', 'message', 'that order is not open any more'));
  END IF;
  RETURN jsonb_build_object('success', true, 'data', row_o, 'error', NULL);
END;
$$ LANGUAGE plpgsql;


-- ----------------------------------------------------------------------------
-- purge_expired_orders :: the TTL sweep. ONLY DELETE on orders for expiry.
-- Called by list_active_pending / kitchen_queue (the boards) and by the
-- cashier page before it reads anything.
-- ----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION purge_expired_orders()
RETURNS jsonb AS $$
DECLARE
  removed integer;
BEGIN
  SELECT COUNT(1) FROM orders AS o WHERE o.status = 'pending_payment' AND o.expires_at < now() INTO removed;
  -- CASCADE removes the line items; they are never touched directly
  DELETE FROM orders AS o WHERE o.status = 'pending_payment' AND o.expires_at < now();
  RETURN jsonb_build_object('success', true, 'data', jsonb_build_object('removed', removed), 'error', NULL);
END;
$$ LANGUAGE plpgsql;


-- ----------------------------------------------------------------------------
-- list_active_pending :: ORDERS BOARD page (the live "waiting for payment"
-- list). Purges first so the board can never show a dead claim.
--
-- ORDER IS SERVER-AUTHORITATIVE: alphabetical by customer_name, case-insensitive
-- through lower() rather than a COLLATE so no locale collation table is assumed on
-- this PG 15 project, with newest-created as the tiebreak inside one name. The
-- cashier reads claims by WHO they are for, not by when they arrived, and a page
-- level sort could only ever disagree with this one, so cashier.html keeps this
-- order as returned rather than re-sorting (see the aggregate sort clause note in
-- the file header for why ORDER BY lives inside jsonb_agg).
-- ----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION list_active_pending()
RETURNS jsonb AS $$
DECLARE
  rows jsonb := '[]'::jsonb;
  email text; role text;
BEGIN
  -- station fence (roster): list_active_pending runs for cashier, owner — sql/07 roster_role_of
  email := jwt_claims_email();
  role := roster_role_of(email);
  IF email = '' THEN RETURN jsonb_build_object('success', false, 'data', NULL, 'error', jsonb_build_object('code', 'STAFF_SESSION_REQUIRED', 'message', 'this surface needs a signed-in staff session')); END IF;
  IF role = '' THEN RETURN jsonb_build_object('success', false, 'data', NULL, 'error', jsonb_build_object('code', 'STAFF_NOT_REGISTERED', 'message', 'this signed-in email is not on the active staff roster')); END IF;
  IF role NOT IN ('cashier', 'owner') THEN RETURN jsonb_build_object('success', false, 'data', NULL, 'error', jsonb_build_object('code', 'WRONG_STATION', 'message', 'this surface runs for cashier or owner')); END IF;
  PERFORM purge_expired_orders();
  rows := COALESCE((SELECT jsonb_agg(jsonb_build_object(
                'order_id', o.id,
                'code', o.code, 'customer_name', o.customer_name,
                'created_at', o.created_at, 'expires_at', o.expires_at,
                'seconds_remaining', GREATEST(0, EXTRACT(EPOCH FROM (o.expires_at - now()))::int),
                'items_count', COALESCE((SELECT SUM(oi.quantity) FROM order_items AS oi WHERE oi.order_id = o.id), 0),
                'total_amount', o.total_amount)
                ORDER BY lower(o.customer_name) ASC, o.created_at DESC)
              FROM orders AS o
              WHERE o.status = 'pending_payment' AND o.expires_at >= now()), '[]'::jsonb);
  RETURN jsonb_build_object('success', true, 'data', rows, 'error', NULL);
END;
$$ LANGUAGE plpgsql;


-- ----------------------------------------------------------------------------
-- confirm_payment :: PAYMENT page (customer taps "I'm paying"). The UPDATE is
-- fenced on status AND expiry, so a stale claim cannot be paid.
-- ----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION confirm_payment (claim_code text)
RETURNS jsonb AS $$
DECLARE
  stamp timestamptz;
  row_o jsonb;
  email text;
  role text;
BEGIN
  -- station fence (roster): confirm_payment runs for cashier, owner — sql/07 roster_role_of
  email := jwt_claims_email();
  role := roster_role_of(email);
  IF email = '' THEN RETURN jsonb_build_object('success', false, 'data', NULL, 'error', jsonb_build_object('code', 'STAFF_SESSION_REQUIRED', 'message', 'this surface needs a signed-in staff session')); END IF;
  IF role = '' THEN RETURN jsonb_build_object('success', false, 'data', NULL, 'error', jsonb_build_object('code', 'STAFF_NOT_REGISTERED', 'message', 'this signed-in email is not on the active staff roster')); END IF;
  IF role NOT IN ('cashier', 'owner') THEN RETURN jsonb_build_object('success', false, 'data', NULL, 'error', jsonb_build_object('code', 'WRONG_STATION', 'message', 'this surface runs for cashier or owner')); END IF;
  stamp := now();
  UPDATE orders AS o
    SET status = 'paid', paid_at = stamp
    WHERE o.code = claim_code AND o.status = 'pending_payment' AND o.expires_at >= stamp;

  -- paid_at = stamp identifies exactly the row this call transitioned
  row_o := (SELECT jsonb_build_object(
              'code', o.code, 'customer_name', o.customer_name,
              'status', o.status, 'total_amount', o.total_amount,
              'paid_at', o.paid_at,
              'items_count', COALESCE((SELECT SUM(oi.quantity) FROM order_items AS oi WHERE oi.order_id = o.id)))
           FROM orders AS o
           WHERE o.code = claim_code AND o.status = 'paid' AND o.paid_at = stamp);

  IF row_o IS NULL THEN
    RETURN jsonb_build_object('success', false, 'data', NULL, 'error', jsonb_build_object('code', 'ORDER_EXPIRED', 'message', 'This order''s time is up, please place a new one'));
  END IF;
  RETURN jsonb_build_object('success', true, 'data', row_o, 'error', NULL);
END;
$$ LANGUAGE plpgsql;


-- ----------------------------------------------------------------------------
-- kitchen_queue :: KITCHEN BOARD page (kitchen.html). Purges dead claims first,
-- then lists the orders the kitchen still owes, oldest-paid first. 'preparing'
-- is included so a cook tapping set_preparing cannot silently lose the card.
-- ----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION kitchen_queue()
RETURNS jsonb AS $$
DECLARE
  rows jsonb := '[]'::jsonb;
  email text; role text;
BEGIN
  -- station fence (roster): kitchen_queue runs for kitchen, owner — sql/07 roster_role_of
  email := jwt_claims_email();
  role := roster_role_of(email);
  IF email = '' THEN RETURN jsonb_build_object('success', false, 'data', NULL, 'error', jsonb_build_object('code', 'STAFF_SESSION_REQUIRED', 'message', 'this surface needs a signed-in staff session')); END IF;
  IF role = '' THEN RETURN jsonb_build_object('success', false, 'data', NULL, 'error', jsonb_build_object('code', 'STAFF_NOT_REGISTERED', 'message', 'this signed-in email is not on the active staff roster')); END IF;
  IF role NOT IN ('kitchen', 'owner') THEN RETURN jsonb_build_object('success', false, 'data', NULL, 'error', jsonb_build_object('code', 'WRONG_STATION', 'message', 'this surface runs for kitchen or owner')); END IF;
  PERFORM purge_expired_orders();
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
                ORDER BY o.paid_at ASC)
              FROM orders AS o
              WHERE o.status = 'paid' OR o.status = 'preparing'), '[]'::jsonb);
  RETURN jsonb_build_object('success', true, 'data', rows, 'error', NULL);
END;
$$ LANGUAGE plpgsql;


-- ----------------------------------------------------------------------------
-- mark_served :: KITCHEN BOARD page (cook taps "done"). Only paid or preparing
-- can be served; the schema CHECKs then require paid_at / served_at.
-- fulfillment_time_seconds is total seconds (EXTRACT EPOCH), which is the
-- sub-hour EXTRACT(SECOND ...) the spec describes, kept correct past 1 hour.
-- ----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION mark_served (order_id uuid)
RETURNS jsonb AS $$
DECLARE
  stamp timestamptz;
  row_o jsonb;
  email text;
  role text;
BEGIN
  -- station fence (roster): mark_served runs for kitchen, owner — sql/07 roster_role_of
  email := jwt_claims_email();
  role := roster_role_of(email);
  IF email = '' THEN RETURN jsonb_build_object('success', false, 'data', NULL, 'error', jsonb_build_object('code', 'STAFF_SESSION_REQUIRED', 'message', 'this surface needs a signed-in staff session')); END IF;
  IF role = '' THEN RETURN jsonb_build_object('success', false, 'data', NULL, 'error', jsonb_build_object('code', 'STAFF_NOT_REGISTERED', 'message', 'this signed-in email is not on the active staff roster')); END IF;
  IF role NOT IN ('kitchen', 'owner') THEN RETURN jsonb_build_object('success', false, 'data', NULL, 'error', jsonb_build_object('code', 'WRONG_STATION', 'message', 'this surface runs for kitchen or owner')); END IF;
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
$$ LANGUAGE plpgsql;


-- ----------------------------------------------------------------------------
-- set_preparing :: KITCHEN BOARD page - optional hold so a cook can claim a
-- paid order without finishing it. paid -> preparing only; re-tapping an order
-- that is already preparing is a harmless no-op success.
-- ----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION set_preparing (order_id uuid)
RETURNS jsonb AS $$
DECLARE
  row_o jsonb;
  email text; role text;
BEGIN
  -- station fence (roster): set_preparing runs for kitchen, owner — sql/07 roster_role_of
  email := jwt_claims_email();
  role := roster_role_of(email);
  IF email = '' THEN RETURN jsonb_build_object('success', false, 'data', NULL, 'error', jsonb_build_object('code', 'STAFF_SESSION_REQUIRED', 'message', 'this surface needs a signed-in staff session')); END IF;
  IF role = '' THEN RETURN jsonb_build_object('success', false, 'data', NULL, 'error', jsonb_build_object('code', 'STAFF_NOT_REGISTERED', 'message', 'this signed-in email is not on the active staff roster')); END IF;
  IF role NOT IN ('kitchen', 'owner') THEN RETURN jsonb_build_object('success', false, 'data', NULL, 'error', jsonb_build_object('code', 'WRONG_STATION', 'message', 'this surface runs for kitchen or owner')); END IF;
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
$$ LANGUAGE plpgsql;


-- ----------------------------------------------------------------------------
-- void_order :: CASHIER page, cancelling an UNPAID claim early. Same removal
-- mechanism as the TTL sweep, fenced to pending_payment so a paid sale can
-- never be deleted here. CASCADE removes its line items.
-- ----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION void_order (order_id uuid)
RETURNS jsonb AS $$
DECLARE
  row_o jsonb;
  email text; role text;
BEGIN
  -- station fence (roster): void_order runs for owner only — sql/07 roster_role_of
  email := jwt_claims_email();
  role := roster_role_of(email);
  IF email = '' THEN RETURN jsonb_build_object('success', false, 'data', NULL, 'error', jsonb_build_object('code', 'STAFF_SESSION_REQUIRED', 'message', 'this surface needs a signed-in staff session')); END IF;
  IF role = '' THEN RETURN jsonb_build_object('success', false, 'data', NULL, 'error', jsonb_build_object('code', 'STAFF_NOT_REGISTERED', 'message', 'this signed-in email is not on the active staff roster')); END IF;
  IF role NOT IN ('owner') THEN RETURN jsonb_build_object('success', false, 'data', NULL, 'error', jsonb_build_object('code', 'WRONG_STATION', 'message', 'this surface runs for owner only')); END IF;
  row_o := (SELECT jsonb_build_object('order_id', o.id, 'code', o.code, 'customer_name', o.customer_name, 'total_amount', o.total_amount)
           FROM orders AS o WHERE o.id = order_id AND o.status = 'pending_payment');
  IF row_o IS NULL THEN
    RETURN jsonb_build_object('success', false, 'data', NULL, 'error', jsonb_build_object('code', 'NOT_VOIDABLE', 'message', 'that order is not an open unpaid claim'));
  END IF;
  DELETE FROM orders AS o WHERE o.id = order_id AND o.status = 'pending_payment';
  RETURN jsonb_build_object('success', true, 'data', row_o || jsonb_build_object('voided', true), 'error', NULL);
END;
$$ LANGUAGE plpgsql;


-- ----------------------------------------------------------------------------
-- set_claim_item_qty :: CASHIER page, before payment. The cashier may re-count a
-- line on a live unpaid claim (+ / - on the cart line) or drop it entirely
-- (quantity 0 = DELETE that line). Only a pending_payment claim that has not run
-- out of time is editable, so a paid sale - the permanent record - can never be
-- repriced. orders.total_amount is recomputed from the lines after every edit,
-- which is why orders_staff_update in 03_rls.sql also has to accept a PRODUCE
-- state of pending_payment with paid_at NULL (see the note there).
--
-- The last line is protected: a live claim always has at least one line, matching
-- create_order's non-empty-items rule, so an emptied claim can never be paid as
-- zero peso. Emptying a claim is a VOID decision, and void_order is the owner's
-- door - hence LAST_LINE_ONLY rather than a silent delete.
-- ----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION set_claim_item_qty (p_order_id uuid, p_item_id uuid, p_quantity integer)
RETURNS jsonb AS $$
DECLARE
  live jsonb;
  lines integer;
  total numeric;
  email text;
  role text;
BEGIN
  -- station fence (roster): set_claim_item_qty runs for cashier only — sql/07 roster_role_of
  email := jwt_claims_email();
  role := roster_role_of(email);
  IF email = '' THEN RETURN jsonb_build_object('success', false, 'data', NULL, 'error', jsonb_build_object('code', 'STAFF_SESSION_REQUIRED', 'message', 'this surface needs a signed-in staff session')); END IF;
  IF role = '' THEN RETURN jsonb_build_object('success', false, 'data', NULL, 'error', jsonb_build_object('code', 'STAFF_NOT_REGISTERED', 'message', 'this signed-in email is not on the active staff roster')); END IF;
  IF role NOT IN ('cashier') THEN RETURN jsonb_build_object('success', false, 'data', NULL, 'error', jsonb_build_object('code', 'WRONG_STATION', 'message', 'this surface runs for cashier only')); END IF;
  live := claim_view(p_order_id);
  IF live IS NULL THEN
    RETURN jsonb_build_object('success', false, 'data', NULL, 'error', jsonb_build_object('code', 'CLAIM_NOT_OPEN', 'message', 'that claim is not open for edits'));
  END IF;
  IF p_quantity IS NULL OR p_quantity < 0 OR p_quantity > 999 THEN
    RETURN jsonb_build_object('success', false, 'data', NULL, 'error', jsonb_build_object('code', 'INVALID_QTY', 'message', 'quantity must be 0-999, 0 drops the line'));
  END IF;
  IF NOT EXISTS (SELECT 1 FROM order_items AS oi WHERE oi.id = p_item_id AND oi.order_id = p_order_id) THEN
    RETURN jsonb_build_object('success', false, 'data', NULL, 'error', jsonb_build_object('code', 'LINE_NOT_FOUND', 'message', 'that line is not on this claim'));
  END IF;
  lines := COALESCE((SELECT COUNT(1) FROM order_items AS oi WHERE oi.order_id = p_order_id), 0);
  IF p_quantity = 0 AND lines <= 1 THEN
    RETURN jsonb_build_object('success', false, 'data', NULL, 'error', jsonb_build_object('code', 'LAST_LINE_ONLY', 'message', 'that is the only line on this claim - void the claim instead of emptying it'));
  END IF;
  IF p_quantity = 0 THEN
    DELETE FROM order_items AS oi WHERE oi.id = p_item_id AND oi.order_id = p_order_id;
  ELSE
    UPDATE order_items AS oi
      SET quantity = p_quantity,
          subtotal = oi.unit_price * p_quantity
      WHERE oi.id = p_item_id AND oi.order_id = p_order_id;
  END IF;
  -- the claim total always follows its lines, so the board and the card agree
  total := COALESCE((SELECT SUM(oi.subtotal) FROM order_items AS oi WHERE oi.order_id = p_order_id), 0);
  UPDATE orders AS o SET total_amount = total WHERE o.id = p_order_id AND o.status = 'pending_payment';
  live := claim_view(p_order_id);
  IF live IS NULL THEN
    RETURN jsonb_build_object('success', false, 'data', NULL, 'error', jsonb_build_object('code', 'CLAIM_NOT_OPEN', 'message', 'that claim ran out of time mid-edit'));
  END IF;
  RETURN jsonb_build_object('success', true, 'data', live, 'error', NULL);
END;
$$ LANGUAGE plpgsql;


-- ----------------------------------------------------------------------------
-- add_claim_item :: CASHIER page, before payment. Adds one line to a live unpaid
-- claim, or bumps the matching line when that item+size is already on it, so a
-- claim never carries two rows for the same thing (the cart keys by item+size too).
-- unit_price is pulled from menu_items.sizes_and_prices exactly as create_order
-- does - the cashier never sends a price, only a catalogue reference - and item_name
-- / size are snapshotted, so a later rename cannot rewrite this claim.
-- ----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION add_claim_item (p_order_id uuid, p_menu_item_id uuid, p_size text, p_quantity integer)
RETURNS jsonb AS $$
DECLARE
  live jsonb;
  menu_row jsonb;
  price numeric;
  qty integer;
  existing_id uuid;
  total numeric;
  email text;
  role text;
BEGIN
  -- station fence (roster): add_claim_item runs for cashier only — sql/07 roster_role_of
  email := jwt_claims_email();
  role := roster_role_of(email);
  IF email = '' THEN RETURN jsonb_build_object('success', false, 'data', NULL, 'error', jsonb_build_object('code', 'STAFF_SESSION_REQUIRED', 'message', 'this surface needs a signed-in staff session')); END IF;
  IF role = '' THEN RETURN jsonb_build_object('success', false, 'data', NULL, 'error', jsonb_build_object('code', 'STAFF_NOT_REGISTERED', 'message', 'this signed-in email is not on the active staff roster')); END IF;
  IF role NOT IN ('cashier') THEN RETURN jsonb_build_object('success', false, 'data', NULL, 'error', jsonb_build_object('code', 'WRONG_STATION', 'message', 'this surface runs for cashier only')); END IF;
  live := claim_view(p_order_id);
  IF live IS NULL THEN
    RETURN jsonb_build_object('success', false, 'data', NULL, 'error', jsonb_build_object('code', 'CLAIM_NOT_OPEN', 'message', 'that claim is not open for edits'));
  END IF;
  qty := COALESCE(p_quantity, 1);
  IF qty < 1 OR qty > 999 THEN
    RETURN jsonb_build_object('success', false, 'data', NULL, 'error', jsonb_build_object('code', 'INVALID_QTY', 'message', 'quantity must be 1-999'));
  END IF;
  menu_row := (SELECT jsonb_build_object('name', m.name, 'sizes', m.sizes_and_prices)
               FROM menu_items AS m WHERE m.id = p_menu_item_id AND m.is_available = true);
  IF menu_row IS NULL THEN
    RETURN jsonb_build_object('success', false, 'data', NULL, 'error', jsonb_build_object('code', 'MENU_ITEM_UNAVAILABLE', 'message', 'that item is not on the menu right now'));
  END IF;
  price := (SELECT (el ->> 'price')::numeric FROM jsonb_array_elements(menu_row -> 'sizes') AS el
            WHERE (el ->> 'size') = p_size);
  IF price IS NULL THEN
    RETURN jsonb_build_object('success', false, 'data', NULL, 'error', jsonb_build_object('code', 'INVALID_SIZE', 'message', 'that size is not offered for this item'));
  END IF;
  existing_id := (SELECT oi.id FROM order_items AS oi
                  WHERE oi.order_id = p_order_id AND oi.menu_item_id = p_menu_item_id AND oi.size = p_size);
  IF existing_id IS NOT NULL THEN
    UPDATE order_items AS oi
      SET quantity = LEAST(999, oi.quantity + qty)::int,
          subtotal = oi.unit_price * LEAST(999, oi.quantity + qty)::int
      WHERE oi.id = existing_id;
  ELSE
    INSERT INTO order_items (order_id, menu_item_id, item_name, size, unit_price, quantity, subtotal)
      VALUES (p_order_id, p_menu_item_id, menu_row ->> 'name', p_size, price, qty, price * qty);
  END IF;
  total := COALESCE((SELECT SUM(oi.subtotal) FROM order_items AS oi WHERE oi.order_id = p_order_id), 0);
  UPDATE orders AS o SET total_amount = total WHERE o.id = p_order_id AND o.status = 'pending_payment';
  live := claim_view(p_order_id);
  IF live IS NULL THEN
    RETURN jsonb_build_object('success', false, 'data', NULL, 'error', jsonb_build_object('code', 'CLAIM_NOT_OPEN', 'message', 'that claim ran out of time mid-edit'));
  END IF;
  RETURN jsonb_build_object('success', true, 'data', live, 'error', NULL);
END;
$$ LANGUAGE plpgsql;


-- ============================================================================
-- ===== PHASE 5: OWNER ANALYTICS + MENU BUILDER =====
-- OWNER GATE: each fn below reads the caller's JWT claims via the Supabase
-- idiom current_setting('request.jwt.claims', true). Presence check ONLY - it proves a
-- signed-in session exists; the identity boundary is now roster_role_of(email) in
-- sql/07_staff_roster.sql, whose NOT_OWNER fence refuses a signed-in non-owner (CONFIG.ownerEmails
-- stays a page-side UI gate; RLS in 03_rls.sql plus the roster fence are the boundary). `from`, `to`
-- and `order` are reserved words, so params are from_time / to_time / new_order.
-- ----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION sales_summary (from_time timestamptz, to_time timestamptz, grain text)
RETURNS jsonb AS $$
DECLARE
  claims jsonb; email text; fmt text;
  rev numeric := 0; cnt integer := 0; aov numeric := 0; buckets jsonb := '[]'::jsonb;
BEGIN
  claims := COALESCE(NULLIF(current_setting('request.jwt.claims', true), '')::jsonb, '{}');
  email := COALESCE(claims ->> 'email', '');
  IF email = '' THEN RETURN jsonb_build_object('success', false, 'data', NULL, 'error', jsonb_build_object('code', 'OWNER_SESSION_REQUIRED', 'message', 'menu changes need a signed-in owner session')); END IF;
  -- roster fence (sql/07): NOT_OWNER - a signed-in non-owner is refused here
  IF roster_role_of(email) <> 'owner' THEN RETURN jsonb_build_object('success', false, 'data', NULL, 'error', jsonb_build_object('code', 'NOT_OWNER', 'message', 'this action needs an active owner on the staff roster')); END IF;
  IF grain NOT IN ('daily', 'monthly', 'yearly') THEN RETURN jsonb_build_object('success', false, 'data', NULL, 'error', jsonb_build_object('code', 'INVALID_GRAIN', 'message', 'grain must be daily, monthly or yearly')); END IF;
  fmt := CASE grain WHEN 'yearly' THEN 'YYYY' WHEN 'monthly' THEN 'YYYY-MM' ELSE 'YYYY-MM-DD' END;
  -- completed sales ONLY: status 'served', paid inside the window
  rev := COALESCE((SELECT SUM(o.total_amount) FROM orders AS o WHERE o.status = 'served' AND o.paid_at >= from_time AND o.paid_at <= to_time), 0);
  cnt := COALESCE((SELECT COUNT(*) FROM orders AS o WHERE o.status = 'served' AND o.paid_at >= from_time AND o.paid_at <= to_time), 0);
  aov := CASE WHEN cnt > 0 THEN ROUND(rev / cnt, 2) ELSE 0 END;
  -- FIX: the sort clause lives INSIDE jsonb_agg. A subquery ORDER BY feeding an aggregate
  -- is not guaranteed by PostgreSQL, so bucket order must be stated where it is honoured.
  buckets := COALESCE((SELECT jsonb_agg(jsonb_build_object('label', b.label, 'revenue', b.rev, 'count', b.cnt) ORDER BY b.label ASC)
                        FROM (SELECT to_char(o.paid_at, fmt) AS label, SUM(o.total_amount) AS rev, COUNT(*) AS cnt
                              FROM orders AS o WHERE o.status = 'served' AND o.paid_at >= from_time AND o.paid_at <= to_time
                              GROUP BY to_char(o.paid_at, fmt)) AS b),
                      '[]'::jsonb);
  RETURN jsonb_build_object('success', true, 'data', jsonb_build_object('revenue', rev, 'completed_count', cnt, 'aov', aov, 'grain', grain, 'buckets', buckets), 'error', NULL);
END;
$$ LANGUAGE plpgsql;

-- ----------------------------------------------------------------------------
-- sales_report :: the CSV-grade rows behind sales_summary's headline numbers
-- (owner dashboard, assets/api.js salesReport). One grain-appropriate table per
-- export, so each download answers the question the matching tab asks:
--   daily   -> one row per COMPLETED sale: who, when it was paid, when the
--              kitchen served it, the turnaround (paid_at -> served_at, which is
--              exactly the derived fulfillment_time_seconds column), the line
--              items with quantities, cups and the cash received.
--   monthly -> one row per DAY inside the window: cups sold and cash received.
--   yearly  -> one row per MONTH inside the window: cups sold and cash received.
-- Completed sales ONLY (status 'served'): an abandoned claim left zero trace by
-- design (TTL DELETE) and a paid-but-never-served order is still open, so
-- neither belongs in a sales record. 'cups' sums order_items.quantity, matching
-- items_count above (cups, not lines). Labels are to_char(paid_at, fmt) in the
-- server's timezone, exactly like sales_summary's buckets, so a page can line a
-- label up with a window without translating anything.
-- ----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION sales_report (from_time timestamptz, to_time timestamptz, grain text)
RETURNS jsonb AS $$
DECLARE
  claims jsonb; email text; fmt text;
  rows jsonb := '[]'::jsonb;
BEGIN
  claims := COALESCE(NULLIF(current_setting('request.jwt.claims', true), '')::jsonb, '{}');
  email := COALESCE(claims ->> 'email', '');
  IF email = '' THEN RETURN jsonb_build_object('success', false, 'data', NULL, 'error', jsonb_build_object('code', 'OWNER_SESSION_REQUIRED', 'message', 'this report needs a signed-in owner session')); END IF;
  -- roster fence (sql/07): NOT_OWNER - a signed-in non-owner is refused here
  IF roster_role_of(email) <> 'owner' THEN RETURN jsonb_build_object('success', false, 'data', NULL, 'error', jsonb_build_object('code', 'NOT_OWNER', 'message', 'this report needs an active owner on the staff roster')); END IF;
  IF grain NOT IN ('daily', 'monthly', 'yearly') THEN RETURN jsonb_build_object('success', false, 'data', NULL, 'error', jsonb_build_object('code', 'INVALID_GRAIN', 'message', 'grain must be daily, monthly or yearly')); END IF;
  -- fmt drives the ELSE branch ONLY, and it is one level FINER than the grain the
  -- page asked for: 'monthly' rows are days, 'yearly' rows are months. That is what
  -- the owner's CSV wants (item 9: per-day totals inside a month; item 10: per-month
  -- totals inside a year). sales_summary keeps its own coarser fmt for the chart.
  fmt := CASE grain WHEN 'yearly' THEN 'YYYY-MM' ELSE 'YYYY-MM-DD' END;
  IF grain = 'daily' THEN
    -- one row per completed sale; the line items ride inside the row as a jsonb
    -- array so the page can format them however a reader wants (the SQL layer
    -- never builds display strings - same rule as claim_view carrying items[]).
    rows := COALESCE((SELECT jsonb_agg(jsonb_build_object(
                  'code', o.code, 'customer_name', o.customer_name,
                  'paid_at', o.paid_at, 'served_at', o.served_at,
                  'turnaround_seconds', o.fulfillment_time_seconds,
                  'cash_received', o.total_amount,
                  'cups', COALESCE((SELECT SUM(oi.quantity) FROM order_items AS oi WHERE oi.order_id = o.id), 0),
                  'items', COALESCE((SELECT jsonb_agg(jsonb_build_object(
                        'item_name', oi.item_name, 'size', oi.size,
                        'quantity', oi.quantity)
                      ORDER BY oi.item_name ASC, oi.size ASC)
                    FROM order_items AS oi WHERE oi.order_id = o.id), '[]'::jsonb))
                ORDER BY o.paid_at ASC)
              FROM orders AS o
              WHERE o.status = 'served' AND o.paid_at >= from_time AND o.paid_at <= to_time), '[]'::jsonb);
  ELSE
    -- monthly / yearly: per-day or per-month totals. The inner SELECT resolves
    -- each order's cups ONCE (a correlated scalar subquery cannot sit in a
    -- GROUP BY projection, so the per-order work lives one level down and the
    -- aggregate below only adds whole numbers up).
    rows := COALESCE((SELECT jsonb_agg(jsonb_build_object(
                  'label', g.label, 'cups', g.cups, 'cash_received', g.cash, 'orders', g.cnt)
                ORDER BY g.label ASC)
              FROM (SELECT s.label AS label, SUM(s.cups) AS cups, SUM(s.cash) AS cash, COUNT(1) AS cnt
                    FROM (SELECT to_char(o.paid_at, fmt) AS label,
                          COALESCE((SELECT SUM(oi.quantity) FROM order_items AS oi WHERE oi.order_id = o.id), 0) AS cups,
                          o.total_amount AS cash
                          FROM orders AS o
                          WHERE o.status = 'served' AND o.paid_at >= from_time AND o.paid_at <= to_time) AS s
                    GROUP BY s.label) AS g),
            '[]'::jsonb);
  END IF;
  RETURN jsonb_build_object('success', true, 'data', jsonb_build_object('grain', grain, 'rows', rows), 'error', NULL);
END;
$$ LANGUAGE plpgsql;
-- ----------------------------------------------------------------------------
-- turnover_stats :: peak_hours is a heatmap of PAID orders only - an abandoned
-- claim leaves zero trace by design (TTL DELETE), so demand is never inflated.
-- ----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION turnover_stats (from_time timestamptz, to_time timestamptz)
RETURNS jsonb AS $$
DECLARE
  claims jsonb; email text; cnt integer := 0;
  avg_s integer := 0; p95_s integer := 0; peak_hours jsonb := '[]'::jsonb;
BEGIN
  claims := COALESCE(NULLIF(current_setting('request.jwt.claims', true), '')::jsonb, '{}');
  email := COALESCE(claims ->> 'email', '');
  IF email = '' THEN RETURN jsonb_build_object('success', false, 'data', NULL, 'error', jsonb_build_object('code', 'OWNER_SESSION_REQUIRED', 'message', 'menu changes need a signed-in owner session')); END IF;
  -- roster fence (sql/07): NOT_OWNER - a signed-in non-owner is refused here
  IF roster_role_of(email) <> 'owner' THEN RETURN jsonb_build_object('success', false, 'data', NULL, 'error', jsonb_build_object('code', 'NOT_OWNER', 'message', 'this action needs an active owner on the staff roster')); END IF;
  cnt := COALESCE((SELECT COUNT(*) FROM orders AS o WHERE o.status = 'served' AND o.paid_at >= from_time AND o.paid_at <= to_time), 0);
  avg_s := COALESCE((SELECT AVG(o.fulfillment_time_seconds)::int FROM orders AS o WHERE o.status = 'served' AND o.paid_at >= from_time AND o.paid_at <= to_time), 0);
  -- p95 by position: sort the durations, skip FLOOR(count*0.95) rows, take the next one.
  -- FLOOR matters: with ::int alone, 10 samples gives OFFSET 10 (9.5 rounds up) and the
  -- LIMIT 1 finds nothing, so p95 would read 0. FLOOR keeps the index inside the range.
  p95_s := COALESCE((SELECT o.fulfillment_time_seconds FROM orders AS o
                     WHERE o.status = 'served' AND o.paid_at >= from_time AND o.paid_at <= to_time
                     ORDER BY o.fulfillment_time_seconds ASC OFFSET FLOOR(cnt * 0.95)::int LIMIT 1), 0);
  -- FIX: same reason as sales_summary - the sort belongs inside jsonb_agg, not on the
  -- subquery, so the heatmap reads left to right by hour by contract.
  peak_hours := COALESCE((SELECT jsonb_agg(jsonb_build_object('hour', t.hour, 'orders', t.orders) ORDER BY t.hour ASC)
                            FROM (SELECT EXTRACT(HOUR FROM o.created_at)::int AS hour, COUNT(*) AS orders
                                  FROM orders AS o WHERE o.status = 'served' AND o.paid_at >= from_time AND o.paid_at <= to_time
                                  GROUP BY EXTRACT(HOUR FROM o.created_at)::int) AS t),
                          '[]'::jsonb);
  RETURN jsonb_build_object('success', true, 'data', jsonb_build_object('sample_size', cnt, 'avg_fulfillment_seconds', avg_s, 'p95_fulfillment_seconds', p95_s, 'peak_hours', peak_hours), 'error', NULL);
END;
$$ LANGUAGE plpgsql;
-- ----------------------------------------------------------------------------
-- create_category :: OWNER page, display_order is the shelf position.
-- ----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION create_category (name text, display_order integer)
RETURNS jsonb AS $$
DECLARE
  claims jsonb; email text; new_id uuid;
BEGIN
  claims := COALESCE(NULLIF(current_setting('request.jwt.claims', true), '')::jsonb, '{}');
  email := COALESCE(claims ->> 'email', '');
  IF email = '' THEN RETURN jsonb_build_object('success', false, 'data', NULL, 'error', jsonb_build_object('code', 'OWNER_SESSION_REQUIRED', 'message', 'menu changes need a signed-in owner session')); END IF;
  -- roster fence (sql/07): NOT_OWNER - a signed-in non-owner is refused here
  IF roster_role_of(email) <> 'owner' THEN RETURN jsonb_build_object('success', false, 'data', NULL, 'error', jsonb_build_object('code', 'NOT_OWNER', 'message', 'this action needs an active owner on the staff roster')); END IF;
  IF COALESCE(TRIM(name), '') = '' OR LENGTH(TRIM(name)) > 80 THEN RETURN jsonb_build_object('success', false, 'data', NULL, 'error', jsonb_build_object('code', 'INVALID_CATEGORY_NAME', 'message', 'category name must be 1-80 characters')); END IF;
  new_id := gen_random_uuid();
  INSERT INTO categories (id, name, display_order) VALUES (new_id, TRIM(name), COALESCE(display_order, 0));
  RETURN jsonb_build_object('success', true, 'data', jsonb_build_object('category_id', new_id), 'error', NULL);
END;
$$ LANGUAGE plpgsql;
-- ----------------------------------------------------------------------------
-- reorder_categories :: new_order = array of category uuids in the wanted order;
-- display_order := array index. Categories left out keep their old position.
-- ----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION reorder_categories (new_order jsonb)
RETURNS jsonb AS $$
DECLARE
  claims jsonb; email text; raw text; target uuid; touched integer := 0;
BEGIN
  claims := COALESCE(NULLIF(current_setting('request.jwt.claims', true), '')::jsonb, '{}');
  email := COALESCE(claims ->> 'email', '');
  IF email = '' THEN RETURN jsonb_build_object('success', false, 'data', NULL, 'error', jsonb_build_object('code', 'OWNER_SESSION_REQUIRED', 'message', 'menu changes need a signed-in owner session')); END IF;
  -- roster fence (sql/07): NOT_OWNER - a signed-in non-owner is refused here
  IF roster_role_of(email) <> 'owner' THEN RETURN jsonb_build_object('success', false, 'data', NULL, 'error', jsonb_build_object('code', 'NOT_OWNER', 'message', 'this action needs an active owner on the staff roster')); END IF;
  IF jsonb_typeof(new_order) <> 'array' THEN RETURN jsonb_build_object('success', false, 'data', NULL, 'error', jsonb_build_object('code', 'INVALID_ORDER', 'message', 'new_order must be an array of category uuids')); END IF;
  FOR idx IN 0 .. jsonb_array_length(new_order) - 1 LOOP
    raw := COALESCE(new_order ->> idx, '');
    IF raw !~ '^[0-9a-fA-F-]{36}$' THEN RETURN jsonb_build_object('success', false, 'data', NULL, 'error', jsonb_build_object('code', 'INVALID_ORDER', 'message', 'every entry must be a category uuid')); END IF;
    target := raw::uuid;
    UPDATE categories AS c SET display_order = idx WHERE c.id = target;
    touched := touched + 1;
  END LOOP;
  RETURN jsonb_build_object('success', true, 'data', jsonb_build_object('reordered', touched), 'error', NULL);
END;
$$ LANGUAGE plpgsql;
-- ----------------------------------------------------------------------------
-- delete_category :: 01_schema.sql has ON DELETE RESTRICT on menu_items.category_id,
-- so a category with live items cannot be deleted directly. Order of operations
-- is what satisfies that CHECK: children are reassigned to fallback_category_id
-- (or deleted when none is given) BEFORE the category row is dropped.
--
-- NEW INVARIANT: order_items.menu_item_id -> menu_items.id carries NO ON DELETE
-- clause on purpose, because paid orders are the permanent sales record. Deleting
-- a menu item still referenced by order_items would raise a raw FK violation
-- (SQLSTATE 23503), so a category whose items were ordered is REFUSED with a
-- structured envelope (MENU_ITEM_IN_USE) rather than corrupting that record. The
-- pre-check counts referenced items before the DELETE; the nested
-- EXCEPTION WHEN SQLSTATE '23503' handler is the portable spelling (plpgsql
-- condition names are single tokens, so FOREIGN KEY VIOLATION is a 42704 parse
-- error, and SQLSTATE_VALUE / FK_CONSTRAINT_VIOLATION are both 42704 here) and a
-- race safety net that rolls the partial DELETE back, so
-- the category row is never dropped on a refusal.
-- ----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION delete_category (p_category_id uuid, p_fallback_category_id uuid DEFAULT NULL)
RETURNS jsonb AS $$
DECLARE
  claims jsonb; email text; cat jsonb; fb jsonb;
  moved integer := 0; blocked integer := 0;
BEGIN
  claims := COALESCE(NULLIF(current_setting('request.jwt.claims', true), '')::jsonb, '{}');
  email := COALESCE(claims ->> 'email', '');
  IF email = '' THEN RETURN jsonb_build_object('success', false, 'data', NULL, 'error', jsonb_build_object('code', 'OWNER_SESSION_REQUIRED', 'message', 'menu changes need a signed-in owner session')); END IF;
  -- roster fence (sql/07): NOT_OWNER - a signed-in non-owner is refused here
  IF roster_role_of(email) <> 'owner' THEN RETURN jsonb_build_object('success', false, 'data', NULL, 'error', jsonb_build_object('code', 'NOT_OWNER', 'message', 'this action needs an active owner on the staff roster')); END IF;
  cat := (SELECT jsonb_build_object('category_id', c.id, 'name', c.name) FROM categories AS c WHERE c.id = p_category_id);
  IF cat IS NULL THEN RETURN jsonb_build_object('success', false, 'data', NULL, 'error', jsonb_build_object('code', 'CATEGORY_NOT_FOUND', 'message', 'that category is not on the menu')); END IF;
  IF p_fallback_category_id IS NOT NULL THEN
    fb := (SELECT jsonb_build_object('found', true) FROM categories AS c WHERE c.id = p_fallback_category_id);
    IF fb IS NULL OR p_fallback_category_id = p_category_id THEN RETURN jsonb_build_object('success', false, 'data', NULL, 'error', jsonb_build_object('code', 'INVALID_FALLBACK', 'message', 'fallback_category_id must be a different existing category')); END IF;
  END IF;
  moved := COALESCE((SELECT COUNT(*) FROM menu_items AS m WHERE m.category_id = p_category_id), 0);
  IF p_fallback_category_id IS NOT NULL THEN
    UPDATE menu_items AS m SET category_id = p_fallback_category_id WHERE m.category_id = p_category_id;
  ELSE
    blocked := COALESCE((SELECT COUNT(*) FROM menu_items AS m WHERE m.category_id = p_category_id AND EXISTS (SELECT 1 FROM order_items AS oi WHERE oi.menu_item_id = m.id)), 0);
    IF blocked > 0 THEN RETURN jsonb_build_object('success', false, 'data', NULL, 'error', jsonb_build_object('code', 'MENU_ITEM_IN_USE', 'message', 'items in that category appear in past orders - move them to another category or hide them instead of deleting')); END IF;
    BEGIN
      DELETE FROM menu_items AS m WHERE m.category_id = p_category_id;
    EXCEPTION WHEN SQLSTATE '23503' THEN
      RETURN jsonb_build_object('success', false, 'data', NULL, 'error', jsonb_build_object('code', 'MENU_ITEM_IN_USE', 'message', 'items in that category appear in past orders - move them to another category or hide them instead of deleting'));
    END;
  END IF;
  DELETE FROM categories AS c WHERE c.id = p_category_id;
  RETURN jsonb_build_object('success', true, 'data', cat || jsonb_build_object('items_moved', moved, 'items_deleted', CASE WHEN p_fallback_category_id IS NULL THEN moved ELSE 0 END, 'fallback_category_id', p_fallback_category_id), 'error', NULL);
END;
$$ LANGUAGE plpgsql;
-- ----------------------------------------------------------------------------
-- create_menu_item :: sizes_and_prices validated against the same CHECK shape as
-- 01_schema.sql (non-empty array of {size,price}) so bad input returns envelope.
-- ----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION create_menu_item (category_id uuid, name text, description text, image_url text, sizes_and_prices jsonb, is_available boolean)
RETURNS jsonb AS $$
DECLARE
  claims jsonb; email text; cat jsonb; el jsonb; new_id uuid;
BEGIN
  claims := COALESCE(NULLIF(current_setting('request.jwt.claims', true), '')::jsonb, '{}');
  email := COALESCE(claims ->> 'email', '');
  IF email = '' THEN RETURN jsonb_build_object('success', false, 'data', NULL, 'error', jsonb_build_object('code', 'OWNER_SESSION_REQUIRED', 'message', 'menu changes need a signed-in owner session')); END IF;
  -- roster fence (sql/07): NOT_OWNER - a signed-in non-owner is refused here
  IF roster_role_of(email) <> 'owner' THEN RETURN jsonb_build_object('success', false, 'data', NULL, 'error', jsonb_build_object('code', 'NOT_OWNER', 'message', 'this action needs an active owner on the staff roster')); END IF;
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
$$ LANGUAGE plpgsql;
-- ----------------------------------------------------------------------------
-- update_menu_item :: COALESCE patch. '' or null means leave as is for the text
-- fields, null keeps sizes_and_prices, null is_available keeps the current flag.
-- ----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION update_menu_item (p_menu_item_id uuid, p_name text DEFAULT '', p_description text DEFAULT '', p_image_url text DEFAULT '', p_sizes_and_prices jsonb DEFAULT NULL, p_is_available boolean DEFAULT NULL)
RETURNS jsonb AS $$
DECLARE
  claims jsonb; email text; current jsonb; patched jsonb;
BEGIN
  claims := COALESCE(NULLIF(current_setting('request.jwt.claims', true), '')::jsonb, '{}');
  email := COALESCE(claims ->> 'email', '');
  IF email = '' THEN RETURN jsonb_build_object('success', false, 'data', NULL, 'error', jsonb_build_object('code', 'OWNER_SESSION_REQUIRED', 'message', 'menu changes need a signed-in owner session')); END IF;
  -- roster fence (sql/07): NOT_OWNER - a signed-in non-owner is refused here
  IF roster_role_of(email) <> 'owner' THEN RETURN jsonb_build_object('success', false, 'data', NULL, 'error', jsonb_build_object('code', 'NOT_OWNER', 'message', 'this action needs an active owner on the staff roster')); END IF;
  current := (SELECT jsonb_build_object('name', m.name, 'description', m.description, 'image_url', m.image_url,
                                        'sizes_and_prices', m.sizes_and_prices, 'is_available', m.is_available)
               FROM menu_items AS m WHERE m.id = p_menu_item_id);
  IF current IS NULL THEN RETURN jsonb_build_object('success', false, 'data', NULL, 'error', jsonb_build_object('code', 'MENU_ITEM_NOT_FOUND', 'message', 'that item is not on the menu')); END IF;
  -- '' (or null) means "keep the current name", so the length CHECK only applies
  -- when a name was actually supplied. Validating the blank default would make
  -- every patch call fail.
  IF NULLIF(TRIM(COALESCE(p_name, '')), '') IS NOT NULL
     AND LENGTH(TRIM(p_name)) > 120 THEN RETURN jsonb_build_object('success', false, 'data', NULL, 'error', jsonb_build_object('code', 'INVALID_ITEM_NAME', 'message', 'item name must be 1-120 characters')); END IF;
  IF p_sizes_and_prices IS NOT NULL AND (jsonb_typeof(p_sizes_and_prices) <> 'array' OR jsonb_array_length(p_sizes_and_prices) < 1) THEN RETURN jsonb_build_object('success', false, 'data', NULL, 'error', jsonb_build_object('code', 'INVALID_SIZES', 'message', 'sizes_and_prices must be a non-empty array or null to keep')); END IF;
  UPDATE menu_items AS m
    SET name = COALESCE(NULLIF(TRIM(COALESCE(p_name, '')), ''), m.name),
        description = CASE WHEN COALESCE(p_description, '') = '' THEN m.description ELSE p_description END,
        image_url = CASE WHEN COALESCE(p_image_url, '') = '' THEN m.image_url ELSE p_image_url END,
        sizes_and_prices = COALESCE(p_sizes_and_prices, m.sizes_and_prices),
        is_available = COALESCE(p_is_available, m.is_available)
    WHERE m.id = p_menu_item_id;
  patched := (SELECT jsonb_build_object('menu_item_id', m.id, 'category_id', m.category_id, 'name', m.name,
                                        'description', m.description, 'image_url', m.image_url,
                                        'sizes_and_prices', m.sizes_and_prices, 'is_available', m.is_available)
               FROM menu_items AS m WHERE m.id = p_menu_item_id);
  RETURN jsonb_build_object('success', true, 'data', patched, 'error', NULL);
END;
$$ LANGUAGE plpgsql;
-- ============================================================================
-- END 02_functions.sql
-- ============================================================================
