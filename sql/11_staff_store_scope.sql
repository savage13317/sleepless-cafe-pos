-- ============================================================================
-- 11_staff_store_scope.sql :: PHASE 9k — STAFF REALTIME STORE SCOPING
-- APPLY AFTER 08_multitenant.sql
--
-- PROBLEM: Staff users (kitchen, cashier, owner) sign in via Supabase Auth
-- (email/password), NOT via the Edge Function. Their JWT has no `sid` claim,
-- so jwt_store_id() returns NULL, and the RLS policy
--   jwt_store_id() IS NOT NULL AND store_id = jwt_store_id()
-- DENIES ALL reads for staff users.
--
-- SOLUTION: Add a fallback to the RLS policies — if jwt_store_id() is NULL,
-- look up the caller's store_id from staff_roster (by email). This keeps
-- store-bearing tokens as the primary path and uses roster as the fallback.
--
-- Also adds roster_store_of(email) helper function.
-- ============================================================================

-- ----------------------------------------------------------------------------
-- roster_store_of :: return the active store_id for a staff email, or NULL
-- ----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION roster_store_of (p_email text)
RETURNS uuid AS $$
  /* SECURITY DEFINER — bypasses RLS so jwt_store_id_or_roster() can look up
     the caller's store even when the authenticated RLS policy returns zero rows. */
BEGIN
  RETURN (SELECT r.store_id FROM staff_roster AS r
          WHERE r.email = p_email AND r.active = true
          LIMIT 1);
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;

-- ----------------------------------------------------------------------------
-- jwt_store_id_or_roster :: primary path = JWT sid; fallback = staff_roster
-- Used in RLS policies to handle both Edge Function tokens and Auth sessions.
-- ----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION jwt_store_id_or_roster ()
RETURNS uuid AS $$
DECLARE
  sid uuid;
  email text;
  rstore uuid;
BEGIN
  sid := jwt_claim('sid');
  IF sid IS NOT NULL THEN RETURN sid; END IF;
  email := jwt_claims_email();
  IF email = '' THEN RETURN NULL; END IF;
  rstore := roster_store_of(email);
  RETURN rstore;
END;
$$ LANGUAGE plpgsql;

-- ----------------------------------------------------------------------------
-- UPDATE RLS POLICIES: replace jwt_store_id() with jwt_store_id_or_roster()
-- These DROP+RECREATE the policies from 08_multitenant.sql
-- ----------------------------------------------------------------------------

-- orders SELECT for staff
DROP POLICY IF EXISTS orders_staff_read_store ON orders;
CREATE POLICY orders_staff_read_store ON orders FOR SELECT TO authenticated
  USING ( jwt_store_id_or_roster() IS NOT NULL AND store_id = jwt_store_id_or_roster() );

-- orders UPDATE for staff (mark_served, set_preparing, void_order)
DROP POLICY IF EXISTS orders_staff_update_store ON orders;
CREATE POLICY orders_staff_update_store ON orders FOR UPDATE TO authenticated
  USING ( jwt_store_id_or_roster() IS NOT NULL AND store_id = jwt_store_id_or_roster() )
  WITH CHECK ( jwt_store_id_or_roster() IS NOT NULL
               AND store_id = jwt_store_id_or_roster() );

-- order_items SELECT for staff
DROP POLICY IF EXISTS order_items_staff_read_store ON order_items;
CREATE POLICY order_items_staff_read_store ON order_items FOR SELECT TO authenticated
  USING ( jwt_store_id_or_roster() IS NOT NULL
          AND (SELECT o.store_id FROM orders AS o WHERE o.id = order_id) = jwt_store_id_or_roster() );

-- order_items UPDATE/INSERT/DELETE for staff
DROP POLICY IF EXISTS order_items_staff_write_store ON order_items;
CREATE POLICY order_items_staff_write_store ON order_items FOR ALL TO authenticated
  USING ( jwt_store_id_or_roster() IS NOT NULL
          AND (SELECT o.store_id FROM orders AS o WHERE o.id = order_id) = jwt_store_id_or_roster() )
  WITH CHECK ( jwt_store_id_or_roster() IS NOT NULL
               AND (SELECT o.store_id FROM orders AS o WHERE o.id = order_id) = jwt_store_id_or_roster()
               AND quantity >= 1
               AND subtotal = unit_price * quantity );

-- orders INSERT for staff (cashier creating orders with claim codes)
-- This policy should only allow staff to insert orders for THEIR store
DROP POLICY IF EXISTS orders_staff_insert ON orders;
DROP POLICY IF EXISTS orders_staff_insert_store ON orders;
CREATE POLICY orders_staff_insert_store ON orders FOR INSERT TO authenticated
  WITH CHECK ( jwt_store_id_or_roster() IS NOT NULL
               AND store_id = jwt_store_id_or_roster() );
