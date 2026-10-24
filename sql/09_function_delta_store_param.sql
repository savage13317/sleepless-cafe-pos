-- ============================================================================
-- DELTA: Fix create_order to accept store_id from client for anonymous users
-- 
-- PROBLEM: create_order() uses jwt_store_id() which returns NULL for anon users
-- without a store-bearing JWT. Supabase switched to ECC signing, so we can't
-- mint HS256 store-bearing JWTs locally.
--
-- SOLUTION: Pass store_id as an optional 3rd parameter to create_order().
-- The client (menu.html) reads ?store= from URL and passes it.
-- Fallback to flagship UUID if not provided (backward compatible).
-- ============================================================================

-- Update create_order to accept optional store_id parameter
CREATE OR REPLACE FUNCTION create_order (
  customer_name text,
  items jsonb,
  store_id_param uuid DEFAULT NULL
)
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
  -- Use passed store_id_param if provided, otherwise fall back to JWT or flagship
  sid := COALESCE(store_id_param, jwt_store_id(), '00000000-0000-0000-8333-000000000001'::uuid);
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

  -- Generate a unique 5-digit code
  new_order_id := gen_random_uuid();
  FOR attempt IN 1 .. 12 LOOP
    code_uuid := gen_random_uuid();
    new_code := lpad((('x' || SUBSTR(code_uuid::text, 1, 8))::bit(32)::bigint % 100000)::text, 5, '0');
    BEGIN
      INSERT INTO orders (id, code, customer_name, status, total_amount, store_id)
      VALUES (new_order_id, new_code, cname, 'pending_payment', total, sid);
      inserted := true;
      EXIT;
    EXCEPTION WHEN SQLSTATE '23505' THEN NULL; -- code collision, draw another
    END;
  END LOOP;
  IF NOT inserted THEN
    RETURN jsonb_build_object('success', false, 'data', NULL, 'error', jsonb_build_object('code', 'CODE_EXHAUSTED', 'message', 'no free code left, please retry'));
  END IF;

  -- Insert order items
  FOR idx IN 0 .. jsonb_array_length(resolved) - 1 LOOP
    INSERT INTO order_items (order_id, menu_item_id, item_name, size, unit_price, quantity, subtotal)
    VALUES (new_order_id, (resolved -> idx ->> 'menu_item_id')::uuid, (resolved -> idx ->> 'item_name'), (resolved -> idx ->> 'size'), (resolved -> idx ->> 'unit_price')::numeric, (resolved -> idx ->> 'quantity')::int, (resolved -> idx ->> 'subtotal')::numeric);
  END LOOP;

  RETURN jsonb_build_object('success', true, 'data', jsonb_build_object('order_id', new_order_id::text, 'code', new_code, 'total', total), 'error', NULL);
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;
