-- ============================================================================
-- 99_COMPLETE_STAFF_JWT_FIX.sql
-- ============================================================================
-- PROBLEM: Staff JWTs from Auth sign-in have `email` claim but NO `sid` claim.
--          jwt_store_id() returns NULL for staff JWTs.
--          This breaks ~16 functions that use jwt_store_id() for store scoping.
--          Also breaks roster_authenticated_read RLS policy on staff_roster.
--
-- SOLUTION: 
--   PART 1: Create staff_has_email() SECURITY DEFINER helper, then use it in
--           the staff_roster RLS policy (avoids infinite recursion from
--           referencing staff_roster in its own policy).
--   PART 2: Replace jwt_store_id() with roster-based store_id lookup in all
--           ~16 functions.
--
-- Also add SECURITY DEFINER to functions that query staff_roster or orders
-- without explicit store_id filtering (so RLS doesn't block them).
--
-- APPLY THIS FILE IN ONE GO. It is idempotent (DROP POLICY IF EXISTS, CREATE OR REPLACE).
-- ============================================================================

-- ----------------------------------------------------------------------------
-- PART 1: FIX RLS POLICY ON staff_roster (helper function to avoid infinite recursion)
-- ----------------------------------------------------------------------------

-- Helper: SECURITY DEFINER bypasses RLS so we can query staff_roster from within its own policy
CREATE OR REPLACE FUNCTION staff_has_email(p_email text, p_store_id uuid)
RETURNS boolean AS $$
  SELECT EXISTS (
    SELECT 1 FROM staff_roster WHERE email = p_email AND active = true AND store_id = p_store_id
  );
$$ LANGUAGE sql SECURITY DEFINER;

DROP POLICY IF EXISTS roster_authenticated_read_store ON staff_roster;
CREATE POLICY roster_authenticated_read_store ON staff_roster FOR SELECT TO authenticated
  USING (
    jwt_store_id() IS NOT NULL AND store_id = jwt_store_id()
    OR
    staff_has_email(
      current_setting('request.jwt.claims', true)::json->>'email',
      store_id
    )
  );

-- ----------------------------------------------------------------------------
-- PART 2: FIX STAFF-FACING FUNCTIONS (cashier, kitchen, owner)
-- ----------------------------------------------------------------------------

-- 2.1: get_order_by_code — Cashier code lookup
CREATE OR REPLACE FUNCTION get_order_by_code (claim_code text)
RETURNS jsonb AS $$
<<block>>
DECLARE
  open_id uuid;
  row_o jsonb;
  email text;
  role text;
  sid uuid;
BEGIN
  email := jwt_claims_email();
  role := roster_role_of(email);
  IF email = '' THEN RETURN jsonb_build_object('success', false, 'data', NULL, 'error', jsonb_build_object('code', 'STAFF_SESSION_REQUIRED', 'message', 'this surface needs a signed-in staff session')); END IF;
  IF role = '' THEN RETURN jsonb_build_object('success', false, 'data', NULL, 'error', jsonb_build_object('code', 'STAFF_NOT_REGISTERED', 'message', 'this signed-in email is not on the active staff roster')); END IF;
  IF role NOT IN ('cashier', 'owner') THEN RETURN jsonb_build_object('success', false, 'data', NULL, 'error', jsonb_build_object('code', 'WRONG_STATION', 'message', 'this surface runs for cashier or owner')); END IF;
  sid := (SELECT r.store_id FROM staff_roster AS r WHERE r.email = block.email AND r.active = true LIMIT 1);
  open_id := (SELECT o.id FROM orders AS o
              WHERE o.code = claim_code AND o.status = 'pending_payment' AND o.expires_at >= now() AND o.store_id = sid);
  IF open_id IS NULL THEN
    RETURN jsonb_build_object('success', false, 'data', NULL, 'error', jsonb_build_object('code', 'ORDER_NOT_FOUND', 'message', 'that order is not open any more'));
  END IF;
  row_o := claim_view(open_id);
  IF row_o IS NULL THEN
    RETURN jsonb_build_object('success', false, 'data', NULL, 'error', jsonb_build_object('code', 'ORDER_NOT_FOUND', 'message', 'that order is not open any more'));
  END IF;
  RETURN jsonb_build_object('success', true, 'data', row_o, 'error', NULL);
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;

-- 2.2: confirm_payment — Cashier payment confirmation
CREATE OR REPLACE FUNCTION confirm_payment (claim_code text)
RETURNS jsonb AS $$
<<block>>
DECLARE
  stamp timestamptz;
  row_o jsonb;
  email text;
  role text;
  sid uuid;
BEGIN
  email := jwt_claims_email();
  role := roster_role_of(email);
  IF email = '' THEN RETURN jsonb_build_object('success', false, 'data', NULL, 'error', jsonb_build_object('code', 'STAFF_SESSION_REQUIRED', 'message', 'this surface needs a signed-in staff session')); END IF;
  IF role = '' THEN RETURN jsonb_build_object('success', false, 'data', NULL, 'error', jsonb_build_object('code', 'STAFF_NOT_REGISTERED', 'message', 'this signed-in email is not on the active staff roster')); END IF;
  IF role NOT IN ('cashier', 'owner') THEN RETURN jsonb_build_object('success', false, 'data', NULL, 'error', jsonb_build_object('code', 'WRONG_STATION', 'message', 'this surface runs for cashier or owner')); END IF;
  sid := (SELECT r.store_id FROM staff_roster AS r WHERE r.email = block.email AND r.active = true LIMIT 1);
  stamp := now();
  UPDATE orders AS o
    SET status = 'paid', paid_at = stamp
    WHERE o.code = claim_code AND o.status = 'pending_payment' AND o.expires_at >= stamp AND o.store_id = sid;
  row_o := (SELECT jsonb_build_object(
              'code', o.code, 'customer_name', o.customer_name,
              'status', o.status, 'total_amount', o.total_amount,
              'paid_at', o.paid_at,
              'items_count', COALESCE((SELECT SUM(oi.quantity) FROM order_items AS oi WHERE oi.order_id = o.id)))
           FROM orders AS o
           WHERE o.code = claim_code AND o.status = 'paid' AND o.paid_at = stamp AND o.store_id = sid);
  IF row_o IS NULL THEN
    RETURN jsonb_build_object('success', false, 'data', NULL, 'error', jsonb_build_object('code', 'ORDER_NOT_FOUND', 'message', 'order not found or not payable'));
  END IF;
  RETURN jsonb_build_object('success', true, 'data', row_o, 'error', NULL);
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;

-- 2.3: list_active_pending — Cashier board (pending orders)
CREATE OR REPLACE FUNCTION list_active_pending()
RETURNS jsonb AS $$
<<block>>
DECLARE
  rows jsonb := '[]'::jsonb;
  email text;
  role text;
  sid uuid;
BEGIN
  email := jwt_claims_email();
  role := roster_role_of(email);
  IF email = '' THEN RETURN jsonb_build_object('success', false, 'data', NULL, 'error', jsonb_build_object('code', 'STAFF_SESSION_REQUIRED', 'message', 'this surface needs a signed-in staff session')); END IF;
  IF role = '' THEN RETURN jsonb_build_object('success', false, 'data', NULL, 'error', jsonb_build_object('code', 'STAFF_NOT_REGISTERED', 'message', 'this signed-in email is not on the active staff roster')); END IF;
  IF role NOT IN ('cashier', 'owner') THEN RETURN jsonb_build_object('success', false, 'data', NULL, 'error', jsonb_build_object('code', 'WRONG_STATION', 'message', 'this surface runs for cashier or owner')); END IF;
  sid := (SELECT r.store_id FROM staff_roster AS r WHERE r.email = block.email AND r.active = true LIMIT 1);
  PERFORM purge_expired_orders();
  rows := COALESCE((SELECT jsonb_agg(jsonb_build_object(
                'order_id', o.id,
                'code', o.code, 'customer_name', o.customer_name,
                'status', o.status,
                'created_at', o.created_at, 'expires_at', o.expires_at,
                'seconds_remaining', GREATEST(0, EXTRACT(EPOCH FROM (o.expires_at - now()))::int),
                'items_count', COALESCE((SELECT SUM(oi.quantity) FROM order_items AS oi WHERE oi.order_id = o.id), 0),
                'total_amount', o.total_amount)
              ORDER BY lower(o.customer_name) ASC, o.created_at DESC)
              FROM orders AS o
              WHERE o.status = 'pending_payment' AND o.expires_at >= now() AND o.store_id = sid), '[]'::jsonb);
  RETURN jsonb_build_object('success', true, 'data', rows, 'error', NULL);
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;

-- 2.4: kitchen_queue — Kitchen board (paid/preparing orders)
CREATE OR REPLACE FUNCTION kitchen_queue()
RETURNS jsonb AS $$
<<block>>
DECLARE
  rows jsonb := '[]'::jsonb;
  email text;
  role text;
  sid uuid;
BEGIN
  email := jwt_claims_email();
  role := roster_role_of(email);
  IF email = '' THEN RETURN jsonb_build_object('success', false, 'data', NULL, 'error', jsonb_build_object('code', 'STAFF_SESSION_REQUIRED', 'message', 'this surface needs a signed-in staff session')); END IF;
  IF role = '' THEN RETURN jsonb_build_object('success', false, 'data', NULL, 'error', jsonb_build_object('code', 'STAFF_NOT_REGISTERED', 'message', 'this signed-in email is not on the active staff roster')); END IF;
  IF role NOT IN ('kitchen', 'owner') THEN RETURN jsonb_build_object('success', false, 'data', NULL, 'error', jsonb_build_object('code', 'WRONG_STATION', 'message', 'this surface runs for kitchen or owner')); END IF;
  sid := (SELECT r.store_id FROM staff_roster AS r WHERE r.email = block.email AND r.active = true LIMIT 1);
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
              WHERE (o.status = 'paid' OR o.status = 'preparing') AND o.store_id = sid), '[]'::jsonb);
  RETURN jsonb_build_object('success', true, 'data', rows, 'error', NULL);
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;

-- 2.5: mark_served — Kitchen mark order as done
CREATE OR REPLACE FUNCTION mark_served (order_id uuid)
RETURNS jsonb AS $$
<<block>>
DECLARE
  stamp timestamptz;
  row_o jsonb;
  email text;
  role text;
  sid uuid;
BEGIN
  email := jwt_claims_email();
  role := roster_role_of(email);
  IF email = '' THEN RETURN jsonb_build_object('success', false, 'data', NULL, 'error', jsonb_build_object('code', 'STAFF_SESSION_REQUIRED', 'message', 'this surface needs a signed-in staff session')); END IF;
  IF role = '' THEN RETURN jsonb_build_object('success', false, 'data', NULL, 'error', jsonb_build_object('code', 'STAFF_NOT_REGISTERED', 'message', 'this signed-in email is not on the active staff roster')); END IF;
  IF role NOT IN ('kitchen', 'owner') THEN RETURN jsonb_build_object('success', false, 'data', NULL, 'error', jsonb_build_object('code', 'WRONG_STATION', 'message', 'this surface runs for kitchen or owner')); END IF;
  sid := (SELECT r.store_id FROM staff_roster AS r WHERE r.email = block.email AND r.active = true LIMIT 1);
  stamp := now();
  UPDATE orders AS o
    SET status = 'served',
        served_at = stamp,
        fulfillment_time_seconds = GREATEST(0, EXTRACT(EPOCH FROM (stamp - o.paid_at))::int)
    WHERE o.id = order_id AND (o.status = 'paid' OR o.status = 'preparing') AND o.store_id = sid;
  row_o := (SELECT jsonb_build_object(
              'order_id', o.id, 'code', o.code, 'customer_name', o.customer_name,
              'status', o.status, 'served_at', o.served_at,
              'fulfillment_time_seconds', o.fulfillment_time_seconds)
           FROM orders AS o
           WHERE o.id = order_id AND o.status = 'served' AND o.served_at = stamp AND o.store_id = sid);
  IF row_o IS NULL THEN
    RETURN jsonb_build_object('success', false, 'data', NULL, 'error', jsonb_build_object('code', 'NOT_SERVABLE', 'message', 'that order is not waiting in the kitchen'));
  END IF;
  RETURN jsonb_build_object('success', true, 'data', row_o, 'error', NULL);
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;

-- 2.6: set_preparing — Kitchen mark order as preparing
CREATE OR REPLACE FUNCTION set_preparing (order_id uuid)
RETURNS jsonb AS $$
<<block>>
DECLARE
  row_o jsonb;
  email text;
  role text;
  sid uuid;
BEGIN
  email := jwt_claims_email();
  role := roster_role_of(email);
  IF email = '' THEN RETURN jsonb_build_object('success', false, 'data', NULL, 'error', jsonb_build_object('code', 'STAFF_SESSION_REQUIRED', 'message', 'this surface needs a signed-in staff session')); END IF;
  IF role = '' THEN RETURN jsonb_build_object('success', false, 'data', NULL, 'error', jsonb_build_object('code', 'STAFF_NOT_REGISTERED', 'message', 'this signed-in email is not on the active staff roster')); END IF;
  IF role NOT IN ('kitchen', 'owner') THEN RETURN jsonb_build_object('success', false, 'data', NULL, 'error', jsonb_build_object('code', 'WRONG_STATION', 'message', 'this surface runs for kitchen or owner')); END IF;
  sid := (SELECT r.store_id FROM staff_roster AS r WHERE r.email = block.email AND r.active = true LIMIT 1);
  UPDATE orders AS o
    SET status = 'preparing'
    WHERE o.id = order_id AND o.status = 'paid' AND o.store_id = sid;
  row_o := (SELECT jsonb_build_object('order_id', o.id, 'code', o.code, 'customer_name', o.customer_name, 'status', o.status, 'paid_at', o.paid_at)
           FROM orders AS o WHERE o.id = order_id AND o.status = 'preparing' AND o.store_id = sid);
  IF row_o IS NULL THEN
    RETURN jsonb_build_object('success', false, 'data', NULL, 'error', jsonb_build_object('code', 'NOT_PREPARABLE', 'message', 'that order is not waiting to be cooked'));
  END IF;
  RETURN jsonb_build_object('success', true, 'data', row_o, 'error', NULL);
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;

-- 2.7: void_order — Owner-only, cancel unpaid order
CREATE OR REPLACE FUNCTION void_order (order_id uuid)
RETURNS jsonb AS $$
<<block>>
DECLARE
  row_o jsonb;
  email text;
  role text;
  sid uuid;
BEGIN
  email := jwt_claims_email();
  role := roster_role_of(email);
  IF email = '' THEN RETURN jsonb_build_object('success', false, 'data', NULL, 'error', jsonb_build_object('code', 'STAFF_SESSION_REQUIRED', 'message', 'this surface needs a signed-in staff session')); END IF;
  IF role = '' THEN RETURN jsonb_build_object('success', false, 'data', NULL, 'error', jsonb_build_object('code', 'STAFF_NOT_REGISTERED', 'message', 'this signed-in email is not on the active staff roster')); END IF;
  IF role NOT IN ('owner') THEN RETURN jsonb_build_object('success', false, 'data', NULL, 'error', jsonb_build_object('code', 'WRONG_STATION', 'message', 'this surface runs for owner only')); END IF;
  sid := (SELECT r.store_id FROM staff_roster AS r WHERE r.email = block.email AND r.active = true LIMIT 1);
  row_o := (SELECT jsonb_build_object('order_id', o.id, 'code', o.code, 'customer_name', o.customer_name, 'total_amount', o.total_amount)
           FROM orders AS o WHERE o.id = order_id AND o.status = 'pending_payment' AND o.store_id = sid);
  IF row_o IS NULL THEN
    RETURN jsonb_build_object('success', false, 'data', NULL, 'error', jsonb_build_object('code', 'NOT_VOIDABLE', 'message', 'that order is not an open unpaid claim'));
  END IF;
  DELETE FROM orders AS o WHERE o.id = order_id AND o.status = 'pending_payment' AND o.store_id = sid;
  RETURN jsonb_build_object('success', true, 'data', row_o || jsonb_build_object('voided', true), 'error', NULL);
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;

-- 2.8: set_claim_item_qty — Cashier edit claim line quantity
CREATE OR REPLACE FUNCTION set_claim_item_qty (p_order_id uuid, p_item_id uuid, p_quantity integer)
RETURNS jsonb AS $$
<<block>>
DECLARE
  live jsonb;
  lines integer;
  total numeric;
  email text;
  role text;
  sid uuid;
BEGIN
  email := jwt_claims_email();
  role := roster_role_of(email);
  IF email = '' THEN RETURN jsonb_build_object('success', false, 'data', NULL, 'error', jsonb_build_object('code', 'STAFF_SESSION_REQUIRED', 'message', 'this surface needs a signed-in staff session')); END IF;
  IF role = '' THEN RETURN jsonb_build_object('success', false, 'data', NULL, 'error', jsonb_build_object('code', 'STAFF_NOT_REGISTERED', 'message', 'this signed-in email is not on the active staff roster')); END IF;
  IF role NOT IN ('cashier') THEN RETURN jsonb_build_object('success', false, 'data', NULL, 'error', jsonb_build_object('code', 'WRONG_STATION', 'message', 'this surface runs for cashier only')); END IF;
  sid := (SELECT r.store_id FROM staff_roster AS r WHERE r.email = block.email AND r.active = true LIMIT 1);
  -- Verify order belongs to this store
  IF NOT EXISTS (SELECT 1 FROM orders WHERE id = p_order_id AND store_id = sid) THEN
    RETURN jsonb_build_object('success', false, 'data', NULL, 'error', jsonb_build_object('code', 'CLAIM_NOT_OPEN', 'message', 'that claim is not open for edits'));
  END IF;
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
  total := COALESCE((SELECT SUM(oi.subtotal) FROM order_items AS oi WHERE oi.order_id = p_order_id), 0);
  UPDATE orders AS o SET total_amount = total WHERE o.id = p_order_id AND o.status = 'pending_payment';
  live := claim_view(p_order_id);
  IF live IS NULL THEN
    RETURN jsonb_build_object('success', false, 'data', NULL, 'error', jsonb_build_object('code', 'CLAIM_NOT_OPEN', 'message', 'that claim ran out of time mid-edit'));
  END IF;
  RETURN jsonb_build_object('success', true, 'data', live, 'error', NULL);
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;

-- 2.9: add_claim_item — Cashier add line to claim
CREATE OR REPLACE FUNCTION add_claim_item (p_order_id uuid, p_menu_item_id uuid, p_size text, p_quantity integer)
RETURNS jsonb AS $$
<<block>>
DECLARE
  live jsonb;
  menu_row jsonb;
  price numeric;
  qty integer;
  existing_id uuid;
  total numeric;
  email text;
  role text;
  sid uuid;
BEGIN
  email := jwt_claims_email();
  role := roster_role_of(email);
  IF email = '' THEN RETURN jsonb_build_object('success', false, 'data', NULL, 'error', jsonb_build_object('code', 'STAFF_SESSION_REQUIRED', 'message', 'this surface needs a signed-in staff session')); END IF;
  IF role = '' THEN RETURN jsonb_build_object('success', false, 'data', NULL, 'error', jsonb_build_object('code', 'STAFF_NOT_REGISTERED', 'message', 'this signed-in email is not on the active staff roster')); END IF;
  IF role NOT IN ('cashier') THEN RETURN jsonb_build_object('success', false, 'data', NULL, 'error', jsonb_build_object('code', 'WRONG_STATION', 'message', 'this surface runs for cashier only')); END IF;
  sid := (SELECT r.store_id FROM staff_roster AS r WHERE r.email = block.email AND r.active = true LIMIT 1);
  IF NOT EXISTS (SELECT 1 FROM orders WHERE id = p_order_id AND store_id = sid) THEN
    RETURN jsonb_build_object('success', false, 'data', NULL, 'error', jsonb_build_object('code', 'CLAIM_NOT_OPEN', 'message', 'that claim is not open for edits'));
  END IF;
  live := claim_view(p_order_id);
  IF live IS NULL THEN
    RETURN jsonb_build_object('success', false, 'data', NULL, 'error', jsonb_build_object('code', 'CLAIM_NOT_OPEN', 'message', 'that claim is not open for edits'));
  END IF;
  qty := COALESCE(p_quantity, 1);
  IF qty < 1 OR qty > 999 THEN
    RETURN jsonb_build_object('success', false, 'data', NULL, 'error', jsonb_build_object('code', 'INVALID_QTY', 'message', 'quantity must be 1-999'));
  END IF;
  menu_row := (SELECT jsonb_build_object('price', sp ->> 'price')
               FROM menu_items AS m
               CROSS JOIN jsonb_array_elements(m.sizes_and_prices) AS sp
               WHERE m.id = p_menu_item_id AND sp ->> 'size' = p_size AND m.store_id = sid);
  IF menu_row IS NULL THEN
    RETURN jsonb_build_object('success', false, 'data', NULL, 'error', jsonb_build_object('code', 'MENU_ITEM_NOT_FOUND', 'message', 'that menu item/size is not available on this menu'));
  END IF;
  price := (menu_row ->> 'price')::numeric;
  -- Check for existing matching line
  existing_id := (SELECT oi.id FROM order_items AS oi
                  WHERE oi.order_id = p_order_id AND oi.menu_item_id = p_menu_item_id AND oi.size = p_size
                  LIMIT 1);
  IF existing_id IS NOT NULL THEN
    UPDATE order_items AS oi
      SET quantity = oi.quantity + qty,
          subtotal = (oi.quantity + qty) * oi.unit_price
      WHERE oi.id = existing_id;
  ELSE
    INSERT INTO order_items (order_id, menu_item_id, item_name, size, quantity, unit_price, subtotal)
      SELECT p_order_id, p_menu_item_id, m.name, p_size, qty, price, price * qty
      FROM menu_items AS m WHERE m.id = p_menu_item_id;
  END IF;
  total := COALESCE((SELECT SUM(oi.subtotal) FROM order_items AS oi WHERE oi.order_id = p_order_id), 0);
  UPDATE orders AS o SET total_amount = total WHERE o.id = p_order_id AND o.status = 'pending_payment';
  live := claim_view(p_order_id);
  IF live IS NULL THEN
    RETURN jsonb_build_object('success', false, 'data', NULL, 'error', jsonb_build_object('code', 'CLAIM_NOT_OPEN', 'message', 'that claim ran out of time mid-edit'));
  END IF;
  RETURN jsonb_build_object('success', true, 'data', live, 'error', NULL);
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;

-- ----------------------------------------------------------------------------
-- PART 3: FIX OWNER-ONLY FUNCTIONS
-- ----------------------------------------------------------------------------

-- 3.1: delete_category
CREATE OR REPLACE FUNCTION delete_category (p_category_id uuid, p_fallback_category_id uuid DEFAULT NULL)
RETURNS jsonb AS $$
<<block>>
DECLARE
  claims jsonb; email text; cat jsonb; fb jsonb;
  moved integer := 0; blocked integer := 0;
  sid uuid;
BEGIN
  claims := COALESCE(NULLIF(current_setting('request.jwt.claims', true), '')::jsonb, '{}');
  email := COALESCE(claims ->> 'email', '');
  IF email = '' THEN RETURN jsonb_build_object('success', false, 'data', NULL, 'error', jsonb_build_object('code', 'OWNER_SESSION_REQUIRED', 'message', 'menu changes need a signed-in owner session')); END IF;
  IF roster_role_of(email) <> 'owner' THEN RETURN jsonb_build_object('success', false, 'data', NULL, 'error', jsonb_build_object('code', 'NOT_OWNER', 'message', 'this action needs an active owner on the staff roster')); END IF;
  sid := (SELECT r.store_id FROM staff_roster AS r WHERE r.email = block.email AND r.active = true LIMIT 1);
  IF sid IS NULL THEN RETURN jsonb_build_object('success', false, 'data', NULL, 'error', jsonb_build_object('code', 'STORE_CONTEXT_REQUIRED', 'message', 'this owner session carries no store - re-sign-in from the branch you own')); END IF;
  cat := (SELECT jsonb_build_object('category_id', c.id, 'name', c.name) FROM categories AS c WHERE c.id = p_category_id AND c.store_id = sid);
  IF cat IS NULL THEN RETURN jsonb_build_object('success', false, 'data', NULL, 'error', jsonb_build_object('code', 'CATEGORY_NOT_FOUND', 'message', 'that category is not on the menu')); END IF;
  IF p_fallback_category_id IS NOT NULL THEN
    fb := (SELECT jsonb_build_object('found', true) FROM categories AS c WHERE c.id = p_fallback_category_id AND c.store_id = sid);
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
  DELETE FROM categories AS c WHERE c.id = p_category_id AND c.store_id = sid;
  RETURN jsonb_build_object('success', true, 'data', cat || jsonb_build_object('items_moved', moved, 'items_deleted', CASE WHEN p_fallback_category_id IS NULL THEN moved ELSE 0 END, 'fallback_category_id', p_fallback_category_id), 'error', NULL);
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;

-- 3.2: create_menu_item
CREATE OR REPLACE FUNCTION create_menu_item (category_id uuid, name text, description text, image_url text, sizes_and_prices jsonb, is_available boolean)
RETURNS jsonb AS $$
<<block>>
DECLARE
  claims jsonb; email text; cat jsonb; el jsonb; new_id uuid;
  sid uuid;
BEGIN
  claims := COALESCE(NULLIF(current_setting('request.jwt.claims', true), '')::jsonb, '{}');
  email := COALESCE(claims ->> 'email', '');
  IF email = '' THEN RETURN jsonb_build_object('success', false, 'data', NULL, 'error', jsonb_build_object('code', 'OWNER_SESSION_REQUIRED', 'message', 'menu changes need a signed-in owner session')); END IF;
  IF roster_role_of(email) <> 'owner' THEN RETURN jsonb_build_object('success', false, 'data', NULL, 'error', jsonb_build_object('code', 'NOT_OWNER', 'message', 'this action needs an active owner on the staff roster')); END IF;
  sid := (SELECT r.store_id FROM staff_roster AS r WHERE r.email = block.email AND r.active = true LIMIT 1);
  IF sid IS NULL THEN RETURN jsonb_build_object('success', false, 'data', NULL, 'error', jsonb_build_object('code', 'STORE_CONTEXT_REQUIRED', 'message', 'this owner session carries no store - re-sign-in from the branch you own')); END IF;
  cat := (SELECT jsonb_build_object('found', true) FROM categories AS c WHERE c.id = category_id AND c.store_id = sid);
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
  IF NOT cap_allows(sid) THEN
    RETURN jsonb_build_object('success', false, 'data', NULL, 'error', jsonb_build_object('code', 'MENU_LIMIT_REACHED', 'message', 'this branch is on the starter plan and has reached its menu limit'));
  END IF;
  new_id := gen_random_uuid();
  INSERT INTO menu_items (id, category_id, name, description, image_url, sizes_and_prices, is_available, store_id, updated_at)
    VALUES (new_id, category_id, TRIM(name), COALESCE(description, ''), COALESCE(image_url, ''), sizes_and_prices, COALESCE(is_available, true), sid, now());
  RETURN jsonb_build_object('success', true, 'data', jsonb_build_object('menu_item_id', new_id), 'error', NULL);
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;

-- 3.3: update_menu_item
CREATE OR REPLACE FUNCTION update_menu_item (p_menu_item_id uuid, p_name text DEFAULT '', p_description text DEFAULT '', p_image_url text DEFAULT '', p_sizes_and_prices jsonb DEFAULT NULL, p_is_available boolean DEFAULT NULL)
RETURNS jsonb AS $$
<<block>>
DECLARE
  claims jsonb; email text; current jsonb; patched jsonb;
  sid uuid; gate text;
BEGIN
  claims := COALESCE(NULLIF(current_setting('request.jwt.claims', true), '')::jsonb, '{}');
  email := COALESCE(claims ->> 'email', '');
  IF email = '' THEN RETURN jsonb_build_object('success', false, 'data', NULL, 'error', jsonb_build_object('code', 'OWNER_SESSION_REQUIRED', 'message', 'menu changes need a signed-in owner session')); END IF;
  IF roster_role_of(email) <> 'owner' THEN RETURN jsonb_build_object('success', false, 'data', NULL, 'error', jsonb_build_object('code', 'NOT_OWNER', 'message', 'this action needs an active owner on the staff roster')); END IF;
  sid := (SELECT r.store_id FROM staff_roster AS r WHERE r.email = block.email AND r.active = true LIMIT 1);
  IF sid IS NULL THEN RETURN jsonb_build_object('success', false, 'data', NULL, 'error', jsonb_build_object('code', 'STORE_CONTEXT_REQUIRED', 'message', 'this owner session carries no store - re-sign-in from the branch you own')); END IF;
  current := (SELECT jsonb_build_object('name', m.name, 'description', m.description, 'image_url', m.image_url,
                                        'sizes_and_prices', m.sizes_and_prices, 'is_available', m.is_available)
               FROM menu_items AS m WHERE m.id = p_menu_item_id);
  IF current IS NULL THEN RETURN jsonb_build_object('success', false, 'data', NULL, 'error', jsonb_build_object('code', 'MENU_ITEM_NOT_FOUND', 'message', 'that item is not on the menu')); END IF;
  gate := starter_write_gate(p_menu_item_id, p_name, p_description, p_sizes_and_prices, p_image_url);
  IF gate = 'TIER_REQUIRED' THEN
    RETURN jsonb_build_object('success', false, 'data', NULL, 'error', jsonb_build_object('code', 'TIER_REQUIRED', 'message', 'this branch is on the starter plan - only availability can be changed here'));
  END IF;
  IF NULLIF(TRIM(COALESCE(p_name, '')), '') IS NOT NULL
     AND LENGTH(TRIM(p_name)) > 120 THEN RETURN jsonb_build_object('success', false, 'data', NULL, 'error', jsonb_build_object('code', 'INVALID_ITEM_NAME', 'message', 'item name must be 1-120 characters')); END IF;
  IF p_sizes_and_prices IS NOT NULL AND (jsonb_typeof(p_sizes_and_prices) <> 'array' OR jsonb_array_length(p_sizes_and_prices) < 1) THEN RETURN jsonb_build_object('success', false, 'data', NULL, 'error', jsonb_build_object('code', 'INVALID_SIZES', 'message', 'sizes_and_prices must be a non-empty array or null to keep')); END IF;
  UPDATE menu_items AS m
    SET name = COALESCE(NULLIF(TRIM(COALESCE(p_name, '')), ''), m.name),
        description = CASE WHEN COALESCE(p_description, '') = '' THEN m.description ELSE p_description END,
        image_url = CASE WHEN COALESCE(p_image_url, '') = '' THEN m.image_url ELSE p_image_url END,
        sizes_and_prices = COALESCE(p_sizes_and_prices, m.sizes_and_prices),
        is_available = COALESCE(p_is_available, m.is_available),
        updated_at = now()
    WHERE m.id = p_menu_item_id AND (SELECT store_id FROM menu_items WHERE id = p_menu_item_id) = sid;
  patched := (SELECT jsonb_build_object('menu_item_id', m.id, 'category_id', m.category_id, 'name', m.name,
                                        'description', m.description, 'image_url', m.image_url,
                                        'sizes_and_prices', m.sizes_and_prices, 'is_available', m.is_available)
               FROM menu_items AS m WHERE m.id = p_menu_item_id);
  RETURN jsonb_build_object('success', true, 'data', patched, 'error', NULL);
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;

-- 3.4: sales_report
CREATE OR REPLACE FUNCTION sales_report (from_time timestamptz, to_time timestamptz, grain text)
RETURNS jsonb AS $$
<<block>>
DECLARE
  claims jsonb; email text; fmt text;
  rows jsonb := '[]'::jsonb;
  sid uuid;
BEGIN
  claims := COALESCE(NULLIF(current_setting('request.jwt.claims', true), '')::jsonb, '{}');
  email := COALESCE(claims ->> 'email', '');
  IF email = '' THEN RETURN jsonb_build_object('success', false, 'data', NULL, 'error', jsonb_build_object('code', 'OWNER_SESSION_REQUIRED', 'message', 'this report needs a signed-in owner session')); END IF;
  IF roster_role_of(email) <> 'owner' THEN RETURN jsonb_build_object('success', false, 'data', NULL, 'error', jsonb_build_object('code', 'NOT_OWNER', 'message', 'this report needs an active owner on the staff roster')); END IF;
  sid := (SELECT r.store_id FROM staff_roster AS r WHERE r.email = block.email AND r.active = true LIMIT 1);
  IF sid IS NULL THEN RETURN jsonb_build_object('success', false, 'data', NULL, 'error', jsonb_build_object('code', 'STORE_CONTEXT_REQUIRED', 'message', 'this owner session carries no store - re-sign-in from the branch you own')); END IF;
  IF tier_gate(sid, 'pro') <> 'OK' THEN RETURN jsonb_build_object('success', false, 'data', NULL, 'error', jsonb_build_object('code', 'TIER_REQUIRED', 'message', 'sales reports are a pro-plan feature')); END IF;
  IF grain NOT IN ('daily', 'monthly', 'yearly') THEN RETURN jsonb_build_object('success', false, 'data', NULL, 'error', jsonb_build_object('code', 'INVALID_GRAIN', 'message', 'grain must be daily, monthly or yearly')); END IF;
  fmt := CASE grain WHEN 'yearly' THEN 'YYYY-MM' ELSE 'YYYY-MM-DD' END;
  IF grain = 'daily' THEN
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
              WHERE o.status = 'served' AND o.store_id = sid AND o.paid_at >= from_time AND o.paid_at <= to_time), '[]'::jsonb);
  ELSE
    rows := COALESCE((SELECT jsonb_agg(jsonb_build_object(
                  'label', g.label, 'cups', g.cups, 'cash_received', g.cash, 'orders', g.cnt)
                ORDER BY g.label ASC)
              FROM (SELECT s.label AS label, SUM(s.cups) AS cups, SUM(s.cash) AS cash, COUNT(1) AS cnt
                    FROM (SELECT to_char(o.paid_at, fmt) AS label,
                          COALESCE((SELECT SUM(oi.quantity) FROM order_items AS oi WHERE oi.order_id = o.id), 0) AS cups,
                          o.total_amount AS cash
                          FROM orders AS o
                          WHERE o.status = 'served' AND o.store_id = sid AND o.paid_at >= from_time AND o.paid_at <= to_time) AS s
                    GROUP BY s.label) AS g),
            '[]'::jsonb);
  END IF;
  RETURN jsonb_build_object('success', true, 'data', jsonb_build_object('grain', grain, 'rows', rows), 'error', NULL);
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;

-- 3.5: turnover_stats
CREATE OR REPLACE FUNCTION turnover_stats (from_time timestamptz, to_time timestamptz)
RETURNS jsonb AS $$
<<block>>
DECLARE
  claims jsonb; email text; cnt integer := 0;
  avg_s integer := 0; p95_s integer := 0; peak_hours jsonb := '[]'::jsonb;
  sid uuid;
BEGIN
  claims := COALESCE(NULLIF(current_setting('request.jwt.claims', true), '')::jsonb, '{}');
  email := COALESCE(claims ->> 'email', '');
  IF email = '' THEN RETURN jsonb_build_object('success', false, 'data', NULL, 'error', jsonb_build_object('code', 'OWNER_SESSION_REQUIRED', 'message', 'menu changes need a signed-in owner session')); END IF;
  IF roster_role_of(email) <> 'owner' THEN RETURN jsonb_build_object('success', false, 'data', NULL, 'error', jsonb_build_object('code', 'NOT_OWNER', 'message', 'this action needs an active owner on the staff roster')); END IF;
  sid := (SELECT r.store_id FROM staff_roster AS r WHERE r.email = block.email AND r.active = true LIMIT 1);
  IF sid IS NULL THEN RETURN jsonb_build_object('success', false, 'data', NULL, 'error', jsonb_build_object('code', 'STORE_CONTEXT_REQUIRED', 'message', 'this owner session carries no store - re-sign-in from the branch you own')); END IF;
  IF tier_gate(sid, 'pro') <> 'OK' THEN RETURN jsonb_build_object('success', false, 'data', NULL, 'error', jsonb_build_object('code', 'TIER_REQUIRED', 'message', 'turnover analytics are a pro-plan feature')); END IF;
  cnt := COALESCE((SELECT COUNT(*) FROM orders AS o WHERE o.status = 'served' AND o.store_id = sid AND o.paid_at >= from_time AND o.paid_at <= to_time), 0);
  avg_s := COALESCE((SELECT AVG(o.fulfillment_time_seconds)::int FROM orders AS o WHERE o.status = 'served' AND o.store_id = sid AND o.paid_at >= from_time AND o.paid_at <= to_time), 0);
  p95_s := COALESCE((SELECT o.fulfillment_time_seconds FROM orders AS o
                     WHERE o.status = 'served' AND o.store_id = sid AND o.paid_at >= from_time AND o.paid_at <= to_time
                     ORDER BY o.fulfillment_time_seconds ASC OFFSET FLOOR(cnt * 0.95)::int LIMIT 1), 0);
  peak_hours := COALESCE((SELECT jsonb_agg(jsonb_build_object('hour', t.hour, 'orders', t.orders) ORDER BY t.hour ASC)
                            FROM (SELECT EXTRACT(HOUR FROM o.created_at)::int AS hour, COUNT(*) AS orders
                                  FROM orders AS o WHERE o.status = 'served' AND o.store_id = sid AND o.paid_at >= from_time AND o.paid_at <= to_time
                                  GROUP BY EXTRACT(HOUR FROM o.created_at)::int) AS t),
                          '[]'::jsonb);
  RETURN jsonb_build_object('success', true, 'data', jsonb_build_object('sample_size', cnt, 'avg_fulfillment_seconds', avg_s, 'p95_fulfillment_seconds', p95_s, 'peak_hours', peak_hours), 'error', NULL);
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;

-- 3.6: create_category
CREATE OR REPLACE FUNCTION create_category (name text, display_order integer)
RETURNS jsonb AS $$
<<block>>
DECLARE
  claims jsonb; email text; new_id uuid;
  sid uuid;
BEGIN
  claims := COALESCE(NULLIF(current_setting('request.jwt.claims', true), '')::jsonb, '{}');
  email := COALESCE(claims ->> 'email', '');
  IF email = '' THEN RETURN jsonb_build_object('success', false, 'data', NULL, 'error', jsonb_build_object('code', 'OWNER_SESSION_REQUIRED', 'message', 'menu changes need a signed-in owner session')); END IF;
  IF roster_role_of(email) <> 'owner' THEN RETURN jsonb_build_object('success', false, 'data', NULL, 'error', jsonb_build_object('code', 'NOT_OWNER', 'message', 'this action needs an active owner on the staff roster')); END IF;
  sid := (SELECT r.store_id FROM staff_roster AS r WHERE r.email = block.email AND r.active = true LIMIT 1);
  IF sid IS NULL THEN RETURN jsonb_build_object('success', false, 'data', NULL, 'error', jsonb_build_object('code', 'STORE_CONTEXT_REQUIRED', 'message', 'this owner session carries no store - re-sign-in from the branch you own')); END IF;
  IF COALESCE(TRIM(name), '') = '' OR LENGTH(TRIM(name)) > 80 THEN RETURN jsonb_build_object('success', false, 'data', NULL, 'error', jsonb_build_object('code', 'INVALID_CATEGORY_NAME', 'message', 'category name must be 1-80 characters')); END IF;
  new_id := gen_random_uuid();
  INSERT INTO categories (id, name, display_order, store_id, updated_at) VALUES (new_id, TRIM(name), COALESCE(display_order, 0), sid, now());
  RETURN jsonb_build_object('success', true, 'data', jsonb_build_object('category_id', new_id), 'error', NULL);
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;

-- 3.7: reorder_categories
CREATE OR REPLACE FUNCTION reorder_categories (new_order jsonb)
RETURNS jsonb AS $$
<<block>>
DECLARE
  claims jsonb; email text; raw text; target uuid; touched integer := 0;
  sid uuid;
BEGIN
  claims := COALESCE(NULLIF(current_setting('request.jwt.claims', true), '')::jsonb, '{}');
  email := COALESCE(claims ->> 'email', '');
  IF email = '' THEN RETURN jsonb_build_object('success', false, 'data', NULL, 'error', jsonb_build_object('code', 'OWNER_SESSION_REQUIRED', 'message', 'menu changes need a signed-in owner session')); END IF;
  IF roster_role_of(email) <> 'owner' THEN RETURN jsonb_build_object('success', false, 'data', NULL, 'error', jsonb_build_object('code', 'NOT_OWNER', 'message', 'this action needs an active owner on the staff roster')); END IF;
  sid := (SELECT r.store_id FROM staff_roster AS r WHERE r.email = block.email AND r.active = true LIMIT 1);
  IF sid IS NULL THEN RETURN jsonb_build_object('success', false, 'data', NULL, 'error', jsonb_build_object('code', 'STORE_CONTEXT_REQUIRED', 'message', 'this owner session carries no store - re-sign-in from the branch you own')); END IF;
  IF jsonb_typeof(new_order) <> 'array' THEN RETURN jsonb_build_object('success', false, 'data', NULL, 'error', jsonb_build_object('code', 'INVALID_ORDER', 'message', 'new_order must be an array of category uuids')); END IF;
  FOR idx IN 0 .. jsonb_array_length(new_order) - 1 LOOP
    raw := COALESCE(new_order ->> idx, '');
    IF raw !~ '^[0-9a-fA-F-]{36}$' THEN RETURN jsonb_build_object('success', false, 'data', NULL, 'error', jsonb_build_object('code', 'INVALID_ORDER', 'message', 'every entry must be a category uuid')); END IF;
    target := raw::uuid;
    UPDATE categories AS c SET display_order = idx WHERE c.id = target AND c.store_id = sid;
    touched := touched + 1;
  END LOOP;
  RETURN jsonb_build_object('success', true, 'data', jsonb_build_object('reordered', touched), 'error', NULL);
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;
