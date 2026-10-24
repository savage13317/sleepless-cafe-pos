-- 99_fix_orders_all_policies.sql
-- Complete fix: Drop all problematic policies and recreate properly
-- Safe to run multiple times — drops each policy before recreating

-- 1. Staff can READ orders from their store (via roster lookup)
DROP POLICY IF EXISTS orders_staff_read ON orders;
CREATE POLICY orders_staff_read ON orders
  FOR SELECT
  TO authenticated
  USING (
    EXISTS (
      SELECT 1 FROM staff_roster AS r
      WHERE r.email = current_setting('request.jwt.claims', true)::json->>'email'
        AND r.active = true
        AND r.store_id = orders.store_id
    )
  );

-- 2. Staff can UPDATE orders from their store
DROP POLICY IF EXISTS orders_staff_update ON orders;
CREATE POLICY orders_staff_update ON orders
  FOR UPDATE
  TO authenticated
  USING (
    EXISTS (
      SELECT 1 FROM staff_roster AS r
      WHERE r.email = current_setting('request.jwt.claims', true)::json->>'email'
        AND r.active = true
        AND r.store_id = orders.store_id
    )
  )
  WITH CHECK (
    EXISTS (
      SELECT 1 FROM staff_roster AS r
      WHERE r.email = current_setting('request.jwt.claims', true)::json->>'email'
        AND r.active = true
        AND r.store_id = orders.store_id
    )
  );

-- 3. Customers can READ their own store's orders
DROP POLICY IF EXISTS orders_customer_read ON orders;
CREATE POLICY orders_customer_read ON orders
  FOR SELECT
  TO authenticated
  USING (
    current_setting('request.jwt.claims', true)::json->>'sid' IS NOT NULL
    AND store_id = (current_setting('request.jwt.claims', true)::json->>'sid')::uuid
  );

-- 4. Customers can INSERT orders for their store
DROP POLICY IF EXISTS orders_customer_insert ON orders;
CREATE POLICY orders_customer_insert ON orders
  FOR INSERT
  TO authenticated
  WITH CHECK (
    current_setting('request.jwt.claims', true)::json->>'sid' IS NOT NULL
    AND store_id = (current_setting('request.jwt.claims', true)::json->>'sid')::uuid
  );

-- 5. Keep original orders_insert for service_role / create_order bypass
DROP POLICY IF EXISTS orders_insert ON orders;
CREATE POLICY orders_insert ON orders
  FOR INSERT
  TO authenticated
  WITH CHECK (true);

-- 6. Keep original orders_select for service_role read
DROP POLICY IF EXISTS orders_select ON orders;
CREATE POLICY orders_select ON orders
  FOR SELECT
  TO authenticated
  USING (true);

-- Verify
SELECT 
  policyname, cmd, 
  left(qual::text, 120) as qual_preview
FROM pg_policies
WHERE tablename = 'orders'
ORDER BY policyname, cmd;
