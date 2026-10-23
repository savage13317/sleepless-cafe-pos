-- ============================================================================
-- 09_function_delta.sql :: PHASE 9d - THE MULTI-TENANT / MULTI-TIER FUNCTION DELTA
-- APPLY AFTER 01_schema.sql, 02_functions.sql, 03_rls.sql, 04_realtime.sql,
-- 05_seed.sql, 06_storage.sql, 07_staff_roster.sql, 08_multitenant.sql.
--
-- WHY THIS FILE EXISTS (completeness / re-runnability):
--   Phase 9d rewrote the BODIES of the Phase-1b/Phase-5 functions (sql/02) and of
--   staff_session/roster_add (sql/07) IN PLACE on the live database, WITHOUT
--   changing their signatures. sql/02 and sql/07 on disk are the PRE-9d originals.
--   A future repo re-run that replays 02/07 (CREATE OR REPLACE) would therefore
--   SILENTLY REVERT the store-scope + tier gating that 9d installed live. This file
--   is the authoritative capture of that delta: replaying 01->...->09 reproduces the
--   verified live state. It is idempotent (CREATE OR REPLACE, no DROP FUNCTION, no
--   signature change), so re-running it is a no-op on an already-9d database.
--
-- WHAT CHANGED (see MULTI_TENANT_SPEC.md §5.2): every body now reads the caller's
--   store from the JWT via jwt_store_id() (installed in 9c) and scopes its SELECTs/
--   INSERTs/UPDATEs to that store; tier boundaries call tier_gate()/cap_allways()/
--   starter_write_gate() (also 9c). NO signature changes, so api.js call sites are
--   untouched. Refusals keep the {success,data,error} envelope with a machine code
--   (TIER_REQUIRED / MENU_LIMIT_REACHED / STORE_MISMATCH / STORE_CONTEXT_REQUIRED).
--
-- OPTION-B NOTE (interim single-branch routing): anon customers carry NO sid, so
--   create_order COALESCEs jwt_store_id() to the LEGACY store uuid
--   00000000-0000-0000-8333-000000000001 (slug 'flagship'). With one branch this is
--   behaviourally identical to the pre-9d originals; the store axis only becomes
--   observable once a second store + a store-bearing anon token exists (9f/§4.3-A).
--
-- FUNCTIONS DELIBERATELY NOT REDEFINED HERE (no change needed):
--   claim_view, kitchen_queue, mark_served, set_preparing, void_order,
--   set_claim_item_qty - cross-store rows are already denied by the 9c store-scoped
--   RLS policies (orders_staff_read / order_items_staff_read|write), so their bodies
--   never see a foreign row. list_active_pending already filters expires_at >= now()
--   (§3.2 freshness) and is store-scoped by orders_staff_read, so it needs no edit.
-- ============================================================================


-- ----------------------------------------------------------------------------
-- create_order :: customer checkout (anon). Store comes from the JWT sid when
-- present; under option B an anon visitor has no sid, so COALESCE to the legacy
-- store. Every menu_item_id is resolved ONLY within that store, so a second
-- branch's item can never be planted into the legacy store's order.
-- ----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION create_order (customer_name text, items jsonb)
RETURNS jsonb AS $$
DECLARE
  cname text; row_el jsonb; mi_id text; sz text; qty_txt text; qty integer; menu_row jsonb;
  price numeric; resolved jsonb := '[]'::jsonb; total numeric := 0;
  new_order_id uuid; code_uuid uuid; new_code text; inserted boolean := false;
  sid uuid;
BEGIN
  cname := COALESCE(TRIM(customer_name), '');
  IF cname = '' OR LENGTH(cname) > 100 THEN
    RETURN jsonb_build_object('success', false, 'data', NULL, 'error', jsonb_build_object('code', 'INVALID_CUSTOMER_NAME', 'message', 'customer_name must be 1-100 characters'));
  END IF;
  IF jsonb_typeof(items) <> 'array' OR jsonb_array_length(items) = 0 THEN
    RETURN jsonb_build_object('success', false, 'data', NULL, 'error', jsonb_build_object('code', 'INVALID_ITEMS', 'message', 'items must be a non-empty array'));
  END IF;
  -- option B: anon customer has no sid -> legacy store; a store-bearing token wins
  sid := COALESCE(jwt_store_id(), '00000000-0000-0000-8333-000000000001'::uuid);
  -- resolve every line against the catalogue BEFORE anything is written, scoped to sid
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
                 FROM menu_items AS m WHERE m.id::text = mi_id AND m.is_available = true AND m.store_id = sid);
    IF menu_row IS NULL THEN
      RETURN jsonb_build_object('success', false, 'data', NULL, 'error', jsonb_build_object('code', 'MENU_ITEM_UNAVAILABLE', 'message', 'that item is not on the menu right now'));
    END IF;
    price := (SELECT (el ->> 'price')::numeric FROM jsonb_array_elements(menu_row -> 'sizes') AS el
              WHERE (el ->> 'size') = sz);
    IF price IS NULL THEN
      RETURN jsonb_build_object('success', false, 'data', NULL, 'error', jsonb_build_object('code', 'INVALID_SIZE', 'message', 'that size is not offered for this item'));
    END IF;
    resolved := resolved || jsonb_build_array(jsonb_build_object('menu_item_id', mi_id, 'item_name', menu_row -> 'name', 'size', sz, 'unit_price', price, 'quantity', qty, 'subtotal', price * qty));
    total := total + price * qty;
  END LOOP;

  new_order_id := gen_random_uuid();
  FOR attempt IN 1 .. 12 LOOP
    code_uuid := gen_random_uuid();
    new_code := lpad((('x' || SUBSTR(code_uuid::text, 1, 8))::bit(32)::bigint % 100000)::text, 5, '0');
    BEGIN
      INSERT INTO orders (id, code, customer_name, total_amount, store_id) VALUES (new_order_id, new_code, cname, total, sid);
      inserted := true;
      EXIT;
    EXCEPTION WHEN SQLSTATE '23505' THEN NULL; -- code collision, draw another
    END;
  END LOOP;
  IF NOT inserted THEN
    RETURN jsonb_build_object('success', false, 'data', NULL, 'error', jsonb_build_object('code', 'CODE_EXHAUSTED', 'message', 'no free code left, please retry'));
  END IF;
  INSERT INTO order_items (order_id, menu_item_id, item_name, size, unit_price, quantity, subtotal)
    SELECT new_order_id, (e ->> 'menu_item_id')::uuid, e ->> 'item_name', e ->> 'size',
           (e ->> 'unit_price')::numeric, (e ->> 'quantity')::int, (e ->> 'subtotal')::numeric
      FROM jsonb_array_elements(resolved) AS e;
  RETURN jsonb_build_object('success', true, 'data', jsonb_build_object('code', new_code, 'order_id', new_order_id, 'total', total, 'items_count', COALESCE((SELECT SUM((e ->> 'quantity')::int) FROM jsonb_array_elements(resolved) AS e), 0)), 'error', NULL);
END;
$$ LANGUAGE plpgsql;


-- ----------------------------------------------------------------------------
-- get_order_by_code :: cashier code lookup. Store-scoped lookup so a code that
-- belongs to another branch is not resolved here (belt over the 9c RLS suspend).
-- ----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION get_order_by_code (claim_code text)
RETURNS jsonb AS $$
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
  sid := jwt_store_id();
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
$$ LANGUAGE plpgsql;


-- ----------------------------------------------------------------------------
-- confirm_payment :: payment page. Store-scoped UPDATE + readback so a foreign
-- branch's code cannot be paid from this store's session.
-- ----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION confirm_payment (claim_code text)
RETURNS jsonb AS $$
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
  sid := jwt_store_id();
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
    RETURN jsonb_build_object('success', false, 'data', NULL, 'error', jsonb_build_object('code', 'ORDER_EXPIRED', 'message', 'This order''s time is up, please place a new one'));
  END IF;
  RETURN jsonb_build_object('success', true, 'data', row_o, 'error', NULL);
END;
$$ LANGUAGE plpgsql;


-- ----------------------------------------------------------------------------
-- add_claim_item :: cashier line add. The menu item must belong to the SAME store
-- as the claim (order.store_id), so a foreign branch's item cannot be injected.
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
  -- the item must live in the SAME store as the claim it is being added to
  menu_row := (SELECT jsonb_build_object('name', m.name, 'sizes', m.sizes_and_prices)
               FROM menu_items AS m WHERE m.id = p_menu_item_id AND m.is_available = true
               AND m.store_id = (SELECT o.store_id FROM orders AS o WHERE o.id = p_order_id));
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


-- ----------------------------------------------------------------------------
-- create_category :: owner menu builder. Category is planted in the caller's store
-- and stamped updated_at (the freshness signal §3.2 uses).
-- ----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION create_category (name text, display_order integer)
RETURNS jsonb AS $$
DECLARE
  claims jsonb; email text; new_id uuid;
  sid uuid;
BEGIN
  claims := COALESCE(NULLIF(current_setting('request.jwt.claims', true), '')::jsonb, '{}');
  email := COALESCE(claims ->> 'email', '');
  IF email = '' THEN RETURN jsonb_build_object('success', false, 'data', NULL, 'error', jsonb_build_object('code', 'OWNER_SESSION_REQUIRED', 'message', 'menu changes need a signed-in owner session')); END IF;
  IF roster_role_of(email) <> 'owner' THEN RETURN jsonb_build_object('success', false, 'data', NULL, 'error', jsonb_build_object('code', 'NOT_OWNER', 'message', 'this action needs an active owner on the staff roster')); END IF;
  sid := jwt_store_id();
  IF sid IS NULL THEN RETURN jsonb_build_object('success', false, 'data', NULL, 'error', jsonb_build_object('code', 'STORE_CONTEXT_REQUIRED', 'message', 'this owner session carries no store - re-sign-in from the branch you own')); END IF;
  IF COALESCE(TRIM(name), '') = '' OR LENGTH(TRIM(name)) > 80 THEN RETURN jsonb_build_object('success', false, 'data', NULL, 'error', jsonb_build_object('code', 'INVALID_CATEGORY_NAME', 'message', 'category name must be 1-80 characters')); END IF;
  new_id := gen_random_uuid();
  INSERT INTO categories (id, name, display_order, store_id, updated_at) VALUES (new_id, TRIM(name), COALESCE(display_order, 0), sid, now());
  RETURN jsonb_build_object('success', true, 'data', jsonb_build_object('category_id', new_id), 'error', NULL);
END;
$$ LANGUAGE plpgsql;


-- ----------------------------------------------------------------------------
-- reorder_categories :: only touches categories in the caller's store.
-- ----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION reorder_categories (new_order jsonb)
RETURNS jsonb AS $$
DECLARE
  claims jsonb; email text; raw text; target uuid; touched integer := 0;
  sid uuid;
BEGIN
  claims := COALESCE(NULLIF(current_setting('request.jwt.claims', true), '')::jsonb, '{}');
  email := COALESCE(claims ->> 'email', '');
  IF email = '' THEN RETURN jsonb_build_object('success', false, 'data', NULL, 'error', jsonb_build_object('code', 'OWNER_SESSION_REQUIRED', 'message', 'menu changes need a signed-in owner session')); END IF;
  IF roster_role_of(email) <> 'owner' THEN RETURN jsonb_build_object('success', false, 'data', NULL, 'error', jsonb_build_object('code', 'NOT_OWNER', 'message', 'this action needs an active owner on the staff roster')); END IF;
  sid := jwt_store_id();
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
$$ LANGUAGE plpgsql;


-- ----------------------------------------------------------------------------
-- delete_category :: every lookup and mutation is scoped to the caller's store,
-- so a foreign branch's category can never be reassigned or dropped here. The
-- MENU_ITEM_IN_USE backstop (order_items FK, SQLSTATE 23503) is unchanged.
-- ----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION delete_category (p_category_id uuid, p_fallback_category_id uuid DEFAULT NULL)
RETURNS jsonb AS $$
DECLARE
  claims jsonb; email text; cat jsonb; fb jsonb;
  moved integer := 0; blocked integer := 0;
  sid uuid;
BEGIN
  claims := COALESCE(NULLIF(current_setting('request.jwt.claims', true), '')::jsonb, '{}');
  email := COALESCE(claims ->> 'email', '');
  IF email = '' THEN RETURN jsonb_build_object('success', false, 'data', NULL, 'error', jsonb_build_object('code', 'OWNER_SESSION_REQUIRED', 'message', 'menu changes need a signed-in owner session')); END IF;
  IF roster_role_of(email) <> 'owner' THEN RETURN jsonb_build_object('success', false, 'data', NULL, 'error', jsonb_build_object('code', 'NOT_OWNER', 'message', 'this action needs an active owner on the staff roster')); END IF;
  sid := jwt_store_id();
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
$$ LANGUAGE plpgsql;


-- ----------------------------------------------------------------------------
-- create_menu_item :: planted in the caller's store; the category must belong to
-- that store; the 25-item cap (cap_allows, 9c) yields the human MENU_LIMIT_REACHED
-- copy. Pro stores are uncapped (cap_allows returns true).
-- ----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION create_menu_item (category_id uuid, name text, description text, image_url text, sizes_and_prices jsonb, is_available boolean)
RETURNS jsonb AS $$
DECLARE
  claims jsonb; email text; cat jsonb; el jsonb; new_id uuid;
  sid uuid;
BEGIN
  claims := COALESCE(NULLIF(current_setting('request.jwt.claims', true), '')::jsonb, '{}');
  email := COALESCE(claims ->> 'email', '');
  IF email = '' THEN RETURN jsonb_build_object('success', false, 'data', NULL, 'error', jsonb_build_object('code', 'OWNER_SESSION_REQUIRED', 'message', 'menu changes need a signed-in owner session')); END IF;
  IF roster_role_of(email) <> 'owner' THEN RETURN jsonb_build_object('success', false, 'data', NULL, 'error', jsonb_build_object('code', 'NOT_OWNER', 'message', 'this action needs an active owner on the staff roster')); END IF;
  sid := jwt_store_id();
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
$$ LANGUAGE plpgsql;


-- ----------------------------------------------------------------------------
-- update_menu_item :: starter_write_gate (9c) is the tier boundary: on a starter
-- store an owner may toggle availability only (name/description/image/sizes are
-- refused with TIER_REQUIRED); on a pro store every patch is allowed. updated_at
-- is stamped on every successful patch.
-- ----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION update_menu_item (p_menu_item_id uuid, p_name text DEFAULT '', p_description text DEFAULT '', p_image_url text DEFAULT '', p_sizes_and_prices jsonb DEFAULT NULL, p_is_available boolean DEFAULT NULL)
RETURNS jsonb AS $$
DECLARE
  claims jsonb; email text; current jsonb; patched jsonb;
  sid uuid; gate text;
BEGIN
  claims := COALESCE(NULLIF(current_setting('request.jwt.claims', true), '')::jsonb, '{}');
  email := COALESCE(claims ->> 'email', '');
  IF email = '' THEN RETURN jsonb_build_object('success', false, 'data', NULL, 'error', jsonb_build_object('code', 'OWNER_SESSION_REQUIRED', 'message', 'menu changes need a signed-in owner session')); END IF;
  IF roster_role_of(email) <> 'owner' THEN RETURN jsonb_build_object('success', false, 'data', NULL, 'error', jsonb_build_object('code', 'NOT_OWNER', 'message', 'this action needs an active owner on the staff roster')); END IF;
  sid := jwt_store_id();
  IF sid IS NULL THEN RETURN jsonb_build_object('success', false, 'data', NULL, 'error', jsonb_build_object('code', 'STORE_CONTEXT_REQUIRED', 'message', 'this owner session carries no store - re-sign-in from the branch you own')); END IF;
  current := (SELECT jsonb_build_object('name', m.name, 'description', m.description, 'image_url', m.image_url,
                                        'sizes_and_prices', m.sizes_and_prices, 'is_available', m.is_available)
               FROM menu_items AS m WHERE m.id = p_menu_item_id);
  IF current IS NULL THEN RETURN jsonb_build_object('success', false, 'data', NULL, 'error', jsonb_build_object('code', 'MENU_ITEM_NOT_FOUND', 'message', 'that item is not on the menu')); END IF;
  -- tier boundary: starter_write_gate resolves the item's store and refuses content
  -- edits (name/description/sizes/image) on a starter store.
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
    WHERE m.id = p_menu_item_id;
  patched := (SELECT jsonb_build_object('menu_item_id', m.id, 'category_id', m.category_id, 'name', m.name,
                                        'description', m.description, 'image_url', m.image_url,
                                        'sizes_and_prices', m.sizes_and_prices, 'is_available', m.is_available)
               FROM menu_items AS m WHERE m.id = p_menu_item_id);
  RETURN jsonb_build_object('success', true, 'data', patched, 'error', NULL);
END;
$$ LANGUAGE plpgsql;


-- ----------------------------------------------------------------------------
-- sales_summary / sales_report / turnover_stats :: Tier-2 analytics. tier_gate
-- (9c) refuses a starter-store owner with TIER_REQUIRED; every orders query is
-- scoped to the caller's store so a branch never sees another branch's sales.
-- ----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION sales_summary (from_time timestamptz, to_time timestamptz, grain text)
RETURNS jsonb AS $$
DECLARE
  claims jsonb; email text; fmt text;
  rev numeric := 0; cnt integer := 0; aov numeric := 0; buckets jsonb := '[]'::jsonb;
  sid uuid;
BEGIN
  claims := COALESCE(NULLIF(current_setting('request.jwt.claims', true), '')::jsonb, '{}');
  email := COALESCE(claims ->> 'email', '');
  IF email = '' THEN RETURN jsonb_build_object('success', false, 'data', NULL, 'error', jsonb_build_object('code', 'OWNER_SESSION_REQUIRED', 'message', 'menu changes need a signed-in owner session')); END IF;
  IF roster_role_of(email) <> 'owner' THEN RETURN jsonb_build_object('success', false, 'data', NULL, 'error', jsonb_build_object('code', 'NOT_OWNER', 'message', 'this action needs an active owner on the staff roster')); END IF;
  sid := jwt_store_id();
  IF sid IS NULL THEN RETURN jsonb_build_object('success', false, 'data', NULL, 'error', jsonb_build_object('code', 'STORE_CONTEXT_REQUIRED', 'message', 'this owner session carries no store - re-sign-in from the branch you own')); END IF;
  IF tier_gate(sid, 'pro') <> 'OK' THEN RETURN jsonb_build_object('success', false, 'data', NULL, 'error', jsonb_build_object('code', 'TIER_REQUIRED', 'message', 'sales analytics are a pro-plan feature')); END IF;
  IF grain NOT IN ('daily', 'monthly', 'yearly') THEN RETURN jsonb_build_object('success', false, 'data', NULL, 'error', jsonb_build_object('code', 'INVALID_GRAIN', 'message', 'grain must be daily, monthly or yearly')); END IF;
  fmt := CASE grain WHEN 'yearly' THEN 'YYYY' WHEN 'monthly' THEN 'YYYY-MM' ELSE 'YYYY-MM-DD' END;
  rev := COALESCE((SELECT SUM(o.total_amount) FROM orders AS o WHERE o.status = 'served' AND o.store_id = sid AND o.paid_at >= from_time AND o.paid_at <= to_time), 0);
  cnt := COALESCE((SELECT COUNT(*) FROM orders AS o WHERE o.status = 'served' AND o.store_id = sid AND o.paid_at >= from_time AND o.paid_at <= to_time), 0);
  aov := CASE WHEN cnt > 0 THEN ROUND(rev / cnt, 2) ELSE 0 END;
  buckets := COALESCE((SELECT jsonb_agg(jsonb_build_object('label', b.label, 'revenue', b.rev, 'count', b.cnt) ORDER BY b.label ASC)
                        FROM (SELECT to_char(o.paid_at, fmt) AS label, SUM(o.total_amount) AS rev, COUNT(*) AS cnt
                              FROM orders AS o WHERE o.status = 'served' AND o.store_id = sid AND o.paid_at >= from_time AND o.paid_at <= to_time
                              GROUP BY to_char(o.paid_at, fmt)) AS b),
                      '[]'::jsonb);
  RETURN jsonb_build_object('success', true, 'data', jsonb_build_object('revenue', rev, 'completed_count', cnt, 'aov', aov, 'grain', grain, 'buckets', buckets), 'error', NULL);
END;
$$ LANGUAGE plpgsql;

CREATE OR REPLACE FUNCTION sales_report (from_time timestamptz, to_time timestamptz, grain text)
RETURNS jsonb AS $$
DECLARE
  claims jsonb; email text; fmt text;
  rows jsonb := '[]'::jsonb;
  sid uuid;
BEGIN
  claims := COALESCE(NULLIF(current_setting('request.jwt.claims', true), '')::jsonb, '{}');
  email := COALESCE(claims ->> 'email', '');
  IF email = '' THEN RETURN jsonb_build_object('success', false, 'data', NULL, 'error', jsonb_build_object('code', 'OWNER_SESSION_REQUIRED', 'message', 'this report needs a signed-in owner session')); END IF;
  IF roster_role_of(email) <> 'owner' THEN RETURN jsonb_build_object('success', false, 'data', NULL, 'error', jsonb_build_object('code', 'NOT_OWNER', 'message', 'this report needs an active owner on the staff roster')); END IF;
  sid := jwt_store_id();
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
$$ LANGUAGE plpgsql;

CREATE OR REPLACE FUNCTION turnover_stats (from_time timestamptz, to_time timestamptz)
RETURNS jsonb AS $$
DECLARE
  claims jsonb; email text; cnt integer := 0;
  avg_s integer := 0; p95_s integer := 0; peak_hours jsonb := '[]'::jsonb;
  sid uuid;
BEGIN
  claims := COALESCE(NULLIF(current_setting('request.jwt.claims', true), '')::jsonb, '{}');
  email := COALESCE(claims ->> 'email', '');
  IF email = '' THEN RETURN jsonb_build_object('success', false, 'data', NULL, 'error', jsonb_build_object('code', 'OWNER_SESSION_REQUIRED', 'message', 'menu changes need a signed-in owner session')); END IF;
  IF roster_role_of(email) <> 'owner' THEN RETURN jsonb_build_object('success', false, 'data', NULL, 'error', jsonb_build_object('code', 'NOT_OWNER', 'message', 'this action needs an active owner on the staff roster')); END IF;
  sid := jwt_store_id();
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
$$ LANGUAGE plpgsql;


-- ============================================================================
-- PHASE 9d DELTA FOR sql/07 (staff roster) -- staff_session + roster_add.
-- staff_roster.store_id FK was added in 9a; these bodies now carry the store axis
-- so the frontend (staff_session) learns store_id + tier, and roster_add plants
-- new staff in the caller's store and refuses cross-store adds.
-- ============================================================================

-- ----------------------------------------------------------------------------
-- staff_session :: returns the caller's roster row PLUS store_id + tier so the
-- frontend can gate its own surface (tier) and scope it (store_id).
-- ----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION staff_session ()
RETURNS jsonb AS $$
DECLARE
  claims_email text;
  row_r jsonb;
BEGIN
  claims_email := jwt_claims_email();
  IF claims_email = '' THEN
    RETURN jsonb_build_object('success', false, 'data', NULL, 'error', jsonb_build_object('code', 'STAFF_NOT_REGISTERED', 'message', 'no roster identity for this session - register the staff member first'));
  END IF;
  row_r := (SELECT jsonb_build_object('email', r.email, 'display_name', r.display_name, 'role', r.role, 'active', r.active, 'store_id', r.store_id, 'tier', store_tier_of(r.store_id)) FROM staff_roster AS r WHERE r.email = claims_email);
  IF row_r IS NULL THEN
    RETURN jsonb_build_object('success', false, 'data', NULL, 'error', jsonb_build_object('code', 'STAFF_NOT_REGISTERED', 'message', 'this email is not on the staff roster'));
  END IF;
  IF (row_r ->> 'active')::text <> 'true' THEN
    RETURN jsonb_build_object('success', false, 'data', NULL, 'error', jsonb_build_object('code', 'STAFF_NOT_REGISTERED', 'message', 'this staff member is suspended'));
  END IF;
  UPDATE staff_roster AS r SET last_seen_at = now() WHERE r.email = claims_email;
  row_r := (SELECT jsonb_build_object('email', r.email, 'display_name', r.display_name, 'role', r.role, 'active', r.active, 'last_seen_at', r.last_seen_at, 'store_id', r.store_id, 'tier', store_tier_of(r.store_id)) FROM staff_roster AS r WHERE r.email = claims_email);
  RETURN jsonb_build_object('success', true, 'data', row_r, 'error', NULL);
END;
$$ LANGUAGE plpgsql;


-- ----------------------------------------------------------------------------
-- roster_add :: OWNER-gated. New staff is planted in the CALLER's store (jwt_store_id).
-- Tier gate: cashier/kitchen may only be added on a PRO store (tier_gate). Cross-check:
-- the owner's own roster store must equal jwt_store_id() or the add is refused STORE_MISMATCH.
-- ----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION roster_add (p_email text, p_display_name text, p_role text, p_created_password text)
RETURNS jsonb AS $$
DECLARE
  claims_email text;
  caller_id uuid;
  caller_store uuid;
  new_id uuid;
  dup jsonb;
  sid uuid;
BEGIN
  claims_email := jwt_claims_email();
  IF claims_email = '' THEN
    RETURN jsonb_build_object('success', false, 'data', NULL, 'error', jsonb_build_object('code', 'OWNER_SESSION_REQUIRED', 'message', 'adding staff needs a signed-in owner session'));
  END IF;
  IF roster_role_of(claims_email) <> 'owner' THEN
    RETURN jsonb_build_object('success', false, 'data', NULL, 'error', jsonb_build_object('code', 'NOT_OWNER', 'message', 'only an active owner may add staff'));
  END IF;
  sid := jwt_store_id();
  IF sid IS NULL THEN
    RETURN jsonb_build_object('success', false, 'data', NULL, 'error', jsonb_build_object('code', 'STORE_CONTEXT_REQUIRED', 'message', 'this owner session carries no store - re-sign-in from the branch you own'));
  END IF;
  IF p_email IS NULL OR p_email !~ '^[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}$' THEN
    RETURN jsonb_build_object('success', false, 'data', NULL, 'error', jsonb_build_object('code', 'INVALID_EMAIL', 'message', 'email must be a valid email (format only)'));
  END IF;
  IF COALESCE(TRIM(p_display_name), '') = '' OR LENGTH(TRIM(p_display_name)) > 60 THEN
    RETURN jsonb_build_object('success', false, 'data', NULL, 'error', jsonb_build_object('code', 'INVALID_DISPLAY_NAME', 'message', 'display_name must be 1-60 characters'));
  END IF;
  IF p_role NOT IN ('owner', 'cashier', 'kitchen') THEN
    RETURN jsonb_build_object('success', false, 'data', NULL, 'error', jsonb_build_object('code', 'INVALID_ROLE', 'message', 'role must be owner, cashier or kitchen'));
  END IF;
  -- tier gate: cashier/kitchen stations are a pro-plan feature
  IF p_role IN ('cashier', 'kitchen') AND tier_gate(sid, 'pro') <> 'OK' THEN
    RETURN jsonb_build_object('success', false, 'data', NULL, 'error', jsonb_build_object('code', 'TIER_REQUIRED', 'message', 'cashier and kitchen staff are a pro-plan feature'));
  END IF;
  dup := (SELECT jsonb_build_object('found', true) FROM staff_roster AS r WHERE r.email = p_email);
  IF dup IS NOT NULL THEN
    RETURN jsonb_build_object('success', false, 'data', NULL, 'error', jsonb_build_object('code', 'ROSTER_EXISTS', 'message', 'that email is already on the roster'));
  END IF;
  caller_id := (SELECT r.id FROM staff_roster AS r WHERE r.email = claims_email);
  caller_store := (SELECT r.store_id FROM staff_roster AS r WHERE r.email = claims_email);
  -- cross-check: the owner's own store must match the session's store axis
  IF caller_store IS NOT NULL AND caller_store <> sid THEN
    RETURN jsonb_build_object('success', false, 'data', NULL, 'error', jsonb_build_object('code', 'STORE_MISMATCH', 'message', 'this owner belongs to a different branch than the session store'));
  END IF;
  new_id := gen_random_uuid();
  INSERT INTO staff_roster (id, email, display_name, role, active, added_by, store_id)
    VALUES (new_id, p_email, TRIM(p_display_name), p_role, true, caller_id, sid);
  RETURN jsonb_build_object('success', true, 'data', jsonb_build_object('roster_id', new_id, 'email', p_email, 'display_name', TRIM(p_display_name), 'role', p_role, 'store_id', sid, 'created_password', p_created_password, 'note', 'copy this password to the new employee; it is shown once and never stored'), 'error', NULL);
END;
$$ LANGUAGE plpgsql;

-- ============================================================================
-- END 09_function_delta.sql
-- ============================================================================
