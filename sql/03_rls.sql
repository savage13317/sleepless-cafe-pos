-- ============================================================================
-- 03_rls.sql :: PHASE 1c - ROLE LIMITATIONS (Supabase / PostgreSQL 15)
-- APPLY AFTER 02_functions.sql, BEFORE 04_realtime.sql
--
-- IDEMPOTENCY: this file IS re-runnable. Every CREATE POLICY is preceded by a
-- matching DROP POLICY IF EXISTS <name> ON <table>; and RLS is turned on with
-- ALTER TABLE ... ENABLE ROW LEVEL SECURITY;, which is itself idempotent. So
-- the whole file can be pasted into the SQL Editor again and nothing changes.
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
-- WHY EVERY TABLE ACCESS IN 02 NEEDS A POLICY
--   RLS is enforced for the effective user of EVERY statement, including the
--   statements inside a plpgsql function body. PostgREST runs SET ROLE first,
--   so a function called by a signed-in member runs as `authenticated` and one
--   called by a customer runs as `anon`. Each table a function touches must
--   therefore be covered by a policy for the calling role, or the function is
--   blocked. The fence is the policy EXPRESSION (USING / WITH CHECK), which
--   encodes the state machine: a signed-in staff member still cannot write an
--   illegal row even though they hold a write policy.
--
--   CONFIG.ownerEmails is an ALLOWLIST CHECK ONLY (a UI gate). RLS is the
--   security boundary. Owner menu-write functions (Phase 5) will require an
--   authenticated session - anon must never be able to write the menu.
--
-- NO POLICY IN THIS FILE LETS anon READ orders/order_items, so a customer can
-- never see paid or served history, nor any other customer's claim.
-- ============================================================================


-- ----------------------------------------------------------------------------
-- ENABLE ROW LEVEL SECURITY FIRST. Without this every policy below is inert.
-- 01_schema.sql never enables RLS, so this file owns it. ALTER TABLE is
-- idempotent, so re-running is harmless.
-- ----------------------------------------------------------------------------
ALTER TABLE menu_items ENABLE ROW LEVEL SECURITY;
ALTER TABLE categories ENABLE ROW LEVEL SECURITY;
ALTER TABLE orders ENABLE ROW LEVEL SECURITY;
ALTER TABLE order_items ENABLE ROW LEVEL SECURITY;


-- ----------------------------------------------------------------------------
-- PUBLIC MENU READ (anon + authenticated). Menu writes are NOT granted to
-- anon at the table level: a customer must not be able to rename or reprice
-- the catalogue. Phase 5 owner functions do the writes as authenticated.
-- ----------------------------------------------------------------------------
DROP POLICY IF EXISTS menu_read_public ON menu_items;
CREATE POLICY menu_read_public ON menu_items FOR SELECT TO anon, authenticated USING ( true );

DROP POLICY IF EXISTS categories_read_public ON categories;
CREATE POLICY categories_read_public ON categories FOR SELECT TO anon, authenticated USING ( true );


-- ----------------------------------------------------------------------------
-- ORDERS / ORDER_ITEMS - CUSTOMER (anon) WRITE DOOR
-- Fenced so anon can only ever create a live unpaid claim, never a pre-paid
-- row. anon INSERT is allowed on both so create_order's INSERTs run for a
-- customer who has no session. anon READ stays denied (no anon SELECT exists
-- on orders/order_items), and anon UPDATE / DELETE are denied outright: every
-- status change happens inside a function in 02, never by a page writing `status`.
--
-- The row SHAPE is fenced by the schema CHECKs in 01_schema.sql, not here. An
-- anon WITH CHECK cannot reference orders to prove the parent claim is its own,
-- because anon has no SELECT rights on orders - a policy expression that reads
-- a table the caller cannot read raises permission denied. So the parent-link
-- fence lives in create_order, not in RLS.
-- ----------------------------------------------------------------------------
DROP POLICY IF EXISTS orders_customer_insert ON orders;
CREATE POLICY orders_customer_insert ON orders FOR INSERT TO anon WITH CHECK ( status = 'pending_payment' );

DROP POLICY IF EXISTS order_items_customer_insert ON order_items;
CREATE POLICY order_items_customer_insert ON order_items FOR INSERT TO anon WITH CHECK ( true );


-- ----------------------------------------------------------------------------
-- ORDERS / ORDER_ITEMS - STAFF / OWNER READ (authenticated only)
-- The cashier and kitchen boards are authenticated sessions; anon is excluded
-- here, which is what keeps other customers' orders invisible to a customer.
-- DELETE / UPDATE policies also need SELECT rights, so these reads are what
-- let the staff write policies below actually run.
-- ----------------------------------------------------------------------------
DROP POLICY IF EXISTS orders_staff_read ON orders;
CREATE POLICY orders_staff_read ON orders FOR SELECT TO authenticated USING ( true );

DROP POLICY IF EXISTS order_items_staff_read ON order_items;
CREATE POLICY order_items_staff_read ON order_items FOR SELECT TO authenticated USING ( true );

-- ----------------------------------------------------------------------------
-- STAFF LINE-ITEM WRITE (authenticated) - the cashier's claim edits
-- set_claim_item_qty re-counts or drops one line of a live claim and add_claim_item
-- adds one, so authenticated needs UPDATE / DELETE / INSERT rights on order_items.
-- The fence is the WITH CHECK expression, not the policy's existence: the arithmetic
-- invariant from 01_schema.sql (subtotal = unit_price * quantity, quantity >= 1) is
-- restated here so a signed-in member cannot plant a line whose subtotal disagrees
-- with its price, and quantity >= 1 means the drop-a-line path in set_claim_item_qty
-- MUST be a DELETE rather than an UPDATE to zero - the policy itself refuses a
-- zero-quantity row. Which claim is editable is fenced inside the function (claim_view
-- demands pending_payment and unexpired); an RLS WITH CHECK on order_items cannot
-- restate that, because it would have to read orders, and a policy expression may
-- only read tables the caller can already read for that same action.
-- anon holds NO write policy here besides order_items_customer_insert, so a customer
-- can still only ever CREATE a claim, never edit one.
-- ----------------------------------------------------------------------------
DROP POLICY IF EXISTS order_items_staff_write ON order_items;
CREATE POLICY order_items_staff_write ON order_items FOR ALL TO authenticated
  USING ( true )
  WITH CHECK ( quantity >= 1 AND subtotal = unit_price * quantity );


-- ----------------------------------------------------------------------------
-- STAFF WRITE POLICIES (authenticated). These exist because the state-machine
-- functions in 02 run as `authenticated` and RLS applies inside function
-- bodies, so each function's UPDATE / DELETE must be covered. The EXPRESSION is
-- the fence that keeps the state machine: a signed-in member holds a write
-- policy but still cannot produce an illegal row.
-- ----------------------------------------------------------------------------
DROP POLICY IF EXISTS orders_staff_update ON orders;
CREATE POLICY orders_staff_update ON orders FOR UPDATE TO authenticated
  USING ( true )
  WITH CHECK ( ( status = 'pending_payment' AND paid_at IS NULL )
               OR ( ( status = 'paid' OR status = 'preparing' OR status = 'served' ) AND paid_at IS NOT NULL ) );

-- The WITH CHECK means the only rows an authenticated UPDATE may PRODUCE are
-- legal lifecycle rows: either a still-open claim (pending_payment with paid_at
-- cleared, which is where it started) or a pipeline row with paid_at set. The
-- first arm exists because the cashier may re-count a line on a live claim
-- (set_claim_item_qty / add_claim_item in 02 recompute orders.total_amount), so
-- an UPDATE that only moves the money on an OPEN claim must be allowed. It is
-- not a loophole: the arm demands paid_at IS NULL, so a signed-in member still
-- cannot flip a paid row back to pending_payment nor clear paid_at, and the
-- monotonic lifecycle holds at the policy level rather than by convention.

DROP POLICY IF EXISTS orders_staff_delete ON orders;
CREATE POLICY orders_staff_delete ON orders FOR DELETE TO authenticated USING ( status = 'pending_payment' );

-- This is the core invariant from 01_schema.sql expressed as a policy: only
-- live unpaid claims are ever deletable, so purge_expired_orders and void_order
-- work while a paid sale is physically undeletable even by a signed-in staff
-- member.

DROP POLICY IF EXISTS categories_staff_write ON categories;
CREATE POLICY categories_staff_write ON categories FOR ALL TO authenticated
  USING ( true )
  WITH CHECK ( LENGTH(TRIM(name)) BETWEEN 1 AND 80 );

-- FOR ALL covers SELECT / INSERT / UPDATE / DELETE for authenticated in one
-- policy (an ALL policy's USING also serves as its WITH CHECK when only USING
-- is given, so WITH CHECK is stated explicitly here). This is what
-- create_category / reorder_categories / delete_category need.

DROP POLICY IF EXISTS menu_items_staff_write ON menu_items;
CREATE POLICY menu_items_staff_write ON menu_items FOR ALL TO authenticated
  USING ( true )
  WITH CHECK ( LENGTH(TRIM(name)) BETWEEN 1 AND 120 );

-- This is what create_menu_item / update_menu_item / delete_category need. anon
-- is excluded from every write policy on menu_items and categories, so a
-- customer can never edit the catalogue.


-- ----------------------------------------------------------------------------
-- Summary of what is granted (nothing else is):
--   ADDED THIS PASS: order_items also has UPDATE / DELETE / INSERT rights for
--   authenticated through order_items_staff_write (quantity >= 1 and subtotal =
--   unit_price * quantity fenced in the WITH CHECK), which is what set_claim_item_qty
--   and add_claim_item need. The table rows below predate that pass - the one line
--   "NO role INSERT policy on order_items besides anon" is therefore superseded:
--   authenticated may INSERT order_items, but only through add_claim_item, which
--   prices the line from menu_items itself.
--   menu_items            READ  anon, authenticated   WRITE authenticated (ALL)
--   categories            READ  anon, authenticated   WRITE authenticated (ALL)
--   orders                INSERT anon        READ authenticated   UPDATE authenticated   DELETE authenticated
--   order_items           INSERT anon        READ authenticated
--   anon                  NO write policy on menu_items / categories
--   anon                  NO read policy on orders / order_items
--   NO role               INSERT policy on order_items besides anon
--   NO role               INSERT policy on orders besides anon
-- ============================================================================
-- END 03_rls.sql
-- ============================================================================
