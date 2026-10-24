-- Fix roster_role_of to be SECURITY DEFINER
-- This function MUST be SECURITY DEFINER to bypass RLS when looking up staff membership
-- The original sql/07_staff_roster.sql declared it as SECURITY DEFINER, but it appears
-- the function was recreated without this attribute during the multi-tenant migration.

CREATE OR REPLACE FUNCTION roster_role_of (p_email text)
RETURNS text AS $$
BEGIN
  -- SECURITY DEFINER: bypasses RLS so kitchen_queue / cashier_queue / staff_session
  -- can look up staff membership even when the caller's JWT has no store_id and
  -- the authenticated RLS policy would otherwise return zero rows.
  RETURN COALESCE((SELECT r.role FROM staff_roster AS r WHERE r.email = p_email AND r.active = true), '');
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;
