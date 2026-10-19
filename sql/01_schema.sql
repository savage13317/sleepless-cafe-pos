-- ============================================================================
-- 01_schema.sql :: PHASE 1 - DATABASE STRUCTURE (Supabase / PostgreSQL)
-- ============================================================================
-- APPLY ORDER: 01_schema.sql -> 02 -> 03 -> 04 -> 05  (never out of order;
--            02+ assume these exact names, types and indexes already exist)
--
-- CORE INVARIANT:
--   orders = live unpaid claims (still inside their <= 60 min window)
--          + complete history of paid sales
--   There is NO "expired" and NO "cancelled" status value. Expiry and voiding
--   are physical DELETEs, never status transitions - so the paid history can
--   never be polluted by abandoned claims and the live set stays small.
--
-- PHASE 1 GATE:
--   order_items carries ON DELETE CASCADE against orders, so deleting an
--   order (expiry / void) is the single mechanism that removes its line items.
--   Every later phase may only ever remove an order, never its items alone.
--
-- TIME: every timestamp column is timestamptz, which PostgreSQL stores as UTC
--   internally; all writers must send explicit UTC (or explicit offsets).
-- ============================================================================

-- ----------------------------------------------------------------------------
-- categories: display grouping only, ordered by hand (display_order)
-- ----------------------------------------------------------------------------
CREATE TABLE categories
(
  id uuid NOT NULL PRIMARY KEY DEFAULT gen_random_uuid(),
  name text NOT NULL CHECK (length(trim(name)) BETWEEN 1 AND 80),
  display_order integer NOT NULL DEFAULT 0,
  created_at timestamptz NOT NULL DEFAULT now()
);

-- ----------------------------------------------------------------------------
-- menu_items: immutable-ish catalogue; prices live in one jsonb array so a
--   size change is one atomic write instead of a per-size row rewrite.
-- ----------------------------------------------------------------------------
CREATE TABLE menu_items
(
  id uuid NOT NULL PRIMARY KEY DEFAULT gen_random_uuid(),
  category_id uuid NOT NULL REFERENCES categories (id) ON DELETE RESTRICT,
  name text NOT NULL CHECK (length(trim(name)) BETWEEN 1 AND 120),
  description text DEFAULT '',
  image_url text DEFAULT '',
  sizes_and_prices jsonb NOT NULL
    CHECK (
      CASE jsonb_typeof(sizes_and_prices)
      WHEN 'array' THEN jsonb_array_length(sizes_and_prices) >= 1
      ELSE false
      END
    ),
  is_available boolean NOT NULL DEFAULT true,
  created_at timestamptz NOT NULL DEFAULT now()
);

-- ON DELETE RESTRICT is the PostgreSQL "reject" behaviour: deleting a
-- category that still has menu_items pointing at it raises an error rather than
-- silently orphaning them. (ON DELETE REFERENCE would be the opposite - it skips
-- the check and leaves a dangling FK - so RESTRICT is deliberate here.) delete_category
-- in sql/02_functions.sql must reassign or delete the items first, then drop the category.

-- ----------------------------------------------------------------------------
-- orders: one row per claim. code is the human-readable 5-digit claim code.
-- ----------------------------------------------------------------------------
CREATE TABLE orders
(
  id uuid NOT NULL PRIMARY KEY DEFAULT gen_random_uuid(),
  code varchar(5) NOT NULL UNIQUE CHECK (code ~ '^[0-9]{5}$'),
  customer_name text NOT NULL CHECK (length(trim(customer_name)) BETWEEN 1 AND 100),
  status text NOT NULL DEFAULT 'pending_payment'
    CHECK (status IN ('pending_payment', 'paid', 'preparing', 'served')),
  total_amount numeric(10,2) NOT NULL DEFAULT 0 CHECK (total_amount >= 0),
  created_at timestamptz NOT NULL DEFAULT now(),
  expires_at timestamptz NOT NULL DEFAULT now() + interval '60 minutes',
  paid_at timestamptz,
  served_at timestamptz,
  fulfillment_time_seconds integer CHECK (fulfillment_time_seconds >= 0),

  -- lifecycle is monotonic and each timestamp proves the stage before it
  CHECK (status = 'pending_payment' OR paid_at IS NOT NULL),
  CHECK (served_at IS NULL OR status = 'served'),
  CHECK (fulfillment_time_seconds IS NULL OR served_at IS NOT NULL)
);

-- paid_at / served_at stay nullable on purpose: NULL means "has not happened
-- yet" for a live claim, and the CHECKs above make NULL impossible once the
-- status has moved past that stage. fulfillment_time_seconds is derived
-- (served_at - paid_at) and only exists for completed sales.

-- ----------------------------------------------------------------------------
-- order_items: the line items. CASCADE here IS the Phase 1 gate - see header.
-- ----------------------------------------------------------------------------
CREATE TABLE order_items
(
  id uuid NOT NULL PRIMARY KEY DEFAULT gen_random_uuid(),
  order_id uuid NOT NULL REFERENCES orders (id) ON DELETE CASCADE,
  menu_item_id uuid NOT NULL REFERENCES menu_items (id),
  item_name text NOT NULL,
  size text NOT NULL,
  unit_price numeric(10,2) CHECK (unit_price >= 0),
  quantity integer NOT NULL CHECK (quantity >= 1),
  subtotal numeric(10,2) CHECK (subtotal >= 0 AND subtotal = unit_price * quantity)
);

-- item_name / size are copied from menu_items at order time (snapshot, not a
-- join): a later menu rename or price change must not rewrite past sales.
-- subtotal is stored and cross-checked so the paid total is auditable without
-- recomputation; numeric(10,2) x integer is exact, so equality never drifts.

-- ----------------------------------------------------------------------------
-- indexes: every hot path in later phases is one of these five queries
-- ----------------------------------------------------------------------------

-- status filter for the "what is outstanding" board
CREATE INDEX orders_status_idx ON orders (status);

-- expiry sweep + history listing, both scan created_at
CREATE INDEX orders_created_at_idx ON orders (created_at);

-- paid-sales history queries
CREATE INDEX orders_paid_at_idx ON orders (paid_at);

-- fulfillment / served-today queries
CREATE INDEX orders_served_at_idx ON orders (served_at);

-- the expiry sweep: only live unpaid claims matter, so the index is narrowed to
-- exactly that subset and stays tiny even as paid history grows unbounded
CREATE INDEX orders_live_pending_idx
  ON orders (status, expires_at)
  WHERE status = 'pending_payment';

-- deleting an order cascades to its items; that lookup must be indexed or the
-- cascade degrades to a full scan of order_items per deleted order
CREATE INDEX order_items_order_id_idx ON order_items (order_id);

-- ============================================================================
-- END 01_schema.sql
-- ============================================================================
