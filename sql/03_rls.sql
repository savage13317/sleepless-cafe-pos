-- ============================================================================
-- 03_rls.sql :: PHASE 1c - ROLE LIMITATIONS (Supabase / PostgreSQL 15)
-- APPLY AFTER 02_functions.sql, BEFORE 04_realtime.sql
--
-- IDEMPOTENCY: CREATE POLICY has no "IF NOT EXISTS" form, so this file is NOT
-- re-runnable as-is. To re-apply, uncomment the DROP block below once, then run
-- this file. (DROP ... IS * removes every policy for the table in one shot.)
--
-- DROP POLICY 'x' IS * FOR menu_items;
-- DROP POLICY 'x' IS * FOR categories;
-- DROP POLICY 'x' IS * FOR orders;
-- DROP POLICY 'x' IS * FOR order_items;
--
-- ROLES IN PLAY
--   anon          = api.js holding only the PUBLISHABLE key, no session. The
--                   service-role key is NEVER shipped to the browser, so the
--                   customer page is the anon role: it can only do what anon
--                   is allowed to do.
--   authenticated = anyone who passed Supabase Auth password login
--                   (cashier / kitchen / owner). role = 'authenticated'.
--                   Being signed in proves nothing about WHO they are.
--
-- WHY THE FUNCTIONS IN 02 WORK WITHOUT A TABLE POLICY
--   PostgreSQL evaluates RLS only for statements the client asks to run
--   directly (a raw GET/POST/PATCH/DELETE from the REST layer). Statements
--   inside a SQL function body are executed by the server on the function's
--   own behalf and are NOT filtered through the caller's table policies:
--   create_order can INSERT, confirm_payment / set_preparing / mark_served can
--   UPDATE, and purge_expired_orders / void_order can DELETE, even though anon
--   has no INSERT/UPDATE/DELETE policy that a page could exploit. That is the
--   whole security shape here: the table is the boundary, the functions are the
--   only doors, and no page ever writes `status`.
--
--   CONFIG.ownerEmails is an ALLOWLIST CHECK ONLY (a UI gate). RLS is the
--   security boundary. Owner menu-write functions (Phase 5) will require an
--   authenticated session - anon must never be able to write the menu.
--
-- NO POLICY IN THIS FILE LETS anon READ orders/order_items, so a customer can
-- never see paid or served history, nor any other customer's claim.
-- ============================================================================


-- ----------------------------------------------------------------------------
-- PUBLIC MENU READ (anon + authenticated). Menu writes are NOT granted to
-- anyone at the table level: a signed-in staff member must not be able to
-- rename or reprice the catalogue. Phase 5 owner functions do the writes.
-- ----------------------------------------------------------------------------
CREATE POLICY 'menu_read_public' FOR menu_items
  READING ( ( role = 'anon' ) OR ( role = 'authenticated' ) );

CREATE POLICY 'categories_read_public' FOR categories
  READING ( ( role = 'anon' ) OR ( role = 'authenticated' ) );

-- Deliberately absent: no INSERT / UPDATE / DELETE policy for menu_items or
-- categories. Default deny covers anon AND authenticated alike.


-- ----------------------------------------------------------------------------
-- ORDERS / ORDER_ITEMS - CUSTOMER (anon) WRITE DOOR
-- anon INSERT is allowed on both so create_order's INSERTs run for a customer
-- who has no session. anon READ is denied (see the read policies below), and
-- anon UPDATE / DELETE are denied outright: every status change happens inside
-- a function in 02, never by a page writing `status`.
-- ----------------------------------------------------------------------------
CREATE POLICY 'orders_customer_insert' FOR orders
  INSERTING ( role = 'anon' );

CREATE POLICY 'order_items_customer_insert' FOR order_items
  INSERTING ( role = 'anon' );


-- ----------------------------------------------------------------------------
-- ORDERS / ORDER_ITEMS - STAFF / OWNER READ (authenticated only)
-- The cashier and kitchen boards are authenticated sessions; anon is excluded
-- here, which is what keeps other customers' orders invisible to a customer.
-- ----------------------------------------------------------------------------
CREATE POLICY 'orders_staff_read' FOR orders
  READING ( role = 'authenticated' );

CREATE POLICY 'order_items_staff_read' FOR order_items
  READING ( role = 'authenticated' );


-- ----------------------------------------------------------------------------
-- NO UPDATE / DELETE POLICY EXISTS ANYWHERE IN THIS FILE.
-- That is the rule, not an oversight: orders transitions are exclusively
-- confirm_payment (pending_payment -> paid), set_preparing (paid -> preparing),
-- mark_served (paid|preparing -> served); removals are exclusively
-- purge_expired_orders (TTL) and void_order (fenced to pending_payment).
-- A signed-in staff member therefore has zero raw UPDATE/DELETE power: the
-- boards call functions, they never patch rows.
--
-- Summary of what is granted (nothing else is):
--   menu_items            READ  anon, authenticated
--   categories            READ  anon, authenticated
--   orders                INSERT anon        READ authenticated
--   order_items           INSERT anon        READ authenticated
--   all four tables       UPDATE none        DELETE none
-- ============================================================================
-- END 03_rls.sql
-- ============================================================================
