-- ============================================================================
-- 08_multitenant.sql :: PHASE 9 - MULTI-TENANT (store_id) + TIER GATING LAYER
-- APPLY ORDER: 01 -> 02 -> 03 -> 04 -> 05 -> 06 -> 07 -> 08 (this file LAST)
--
-- !!! FILES ONLY - NOTHING HERE HAS BEEN APPLIED LIVE. Applying it is a human-
--     authorized step. Read MULTI_TENANT_SPEC.md §6 (PHASE ORDER) BEFORE pasting
--     anything: the schema block is safe to apply today, the store-scoped
--     policies are not (they break the current single store until identities
--     carry a store claim).
--
-- WHY THIS FILE EXISTS
--   The live system is single-store: every table is global, and sql/03_rls.sql
--   grants every authenticated caller `USING ( true )` on orders / order_items /
--   menu_items / categories. Correct for one cafe, WRONG for many: a signed-in
--   member of branch A could read and mutate branch B. This file adds the
--   isolation axis (store_id) and the subscription axis (stores.tier) WITHOUT
--   rewriting sql/02_functions.sql, so the existing store keeps working the
--   moment the schema block is applied.
--
-- THE ADDITIVE TRICK (what keeps current operations unbroken)
--   store_id is added with a CONSTANT default = the legacy store's UUID. A
--   constant default is filled cheaply on a non-empty table, every existing row
--   lands in the legacy store, and every function in sql/02 keeps INSERTing
--   into the right store without a single line change. Cross-store ROUTING
--   (store_id as a parameter) is a later phase; isolation is not.
--
-- VERIFIED FACTS THIS FILE MUST OBEY (from HANDOFF.md §1 - do not "fix" these)
--   * RLS is inert until ALTER TABLE ... ENABLE ROW LEVEL SECURITY; 01 never
--     enables it, so this file owns it for `stores` only (03 owns the rest).
--   * PostgREST SET ROLEs first, so RLS applies inside every plpgsql body.
--   * A policy expression may only read tables the caller can already read
--     for that same action. anon holds NO SELECT on orders, which is why the
--     anon INSERT policy below stays shape-only.
--   * DELETE / UPDATE policies also need SELECT rights.
--   * INSERT policies accept ONLY WITH CHECK (adding USING raises 42601).
--   * `FOR` takes ONE keyword - `FOR INSERT, UPDATE` raises 42601.
--   * FK integrity checks and ON DELETE CASCADE child removals BYPASS RLS.
--   * The SQL Editor runs as root and bypasses RLS - never use an Editor
--     result as evidence of what anon / authenticated can see. Probe over REST.
--   * SYSTEM_GETENV is PG 16+ (42883); the JWT idiom is the two-arg
--     COALESCE(NULLIF(current_setting('request.jwt.claims', true), '')::jsonb, '{}').
--   * A plpgsql local named `email` is ambiguous (42702) against a column of
--     that name - helpers here never shadow a column name.
--   * A signature-changing CREATE OR REPLACE needs a DROP FUNCTION first
--     (42P13 cannot change name of input parameter).
--   * `orders` is ALREADY a member of the supabase_realtime publication
--     (applied 2026-10-19). Never re-run the ALTER line as a "fix".
--
-- RE-RUN SAFETY: the SCHEMA block below runs ONCE. A second paste raises
--   "column already exists", and a multi-statement group aborts atomically on
--   that error, so the DB is left untouched - retries are safe, but do not
--   re-paste the schema block expecting it to be a no-op. Everything after it
--   (policies, functions) IS idempotent: every CREATE POLICY is preceded by a
--   DROP POLICY IF EXISTS of its own name, and every function is CREATE OR
--   REPLACE. No DELETE / TRUNCATE / DROP TABLE anywhere in this file.
-- ============================================================================


-- ----------------------------------------------------------------------------
-- THE LEGACY STORE. One row per branch. `slug` is what a QR code carries
-- (menu.html?store=<slug>); `id` is what every table keys on.
--
-- THE LEGACY UUID IS FIXED ON PURPOSE: it is the value store_id defaults to,
-- so it must be stable across the whole migration. Replace the literal ONCE,
-- before the first paste of this file, and record it in HANDOFF.md - a second
-- paste with a different literal would create a second store and orphan the
-- first one's data.
-- ----------------------------------------------------------------------------
CREATE TABLE stores
(
  id uuid NOT NULL PRIMARY KEY DEFAULT gen_random_uuid(),
  slug text NOT NULL UNIQUE
    CHECK (slug ~ '^[a-z0-9](-?[a-z0-9]){2,30}$'),
  name text NOT NULL CHECK (length(trim(name)) BETWEEN 1 AND 80),
  city text DEFAULT '',
  timezone text NOT NULL DEFAULT 'UTC'
    CHECK (timezone ~ '^[A-Za-z_]+(/[A-Za-z_]+)?$'),
  is_open boolean NOT NULL DEFAULT true,

  -- the subscription axis. text + CHECK matches the existing 01 style
  -- (categories.name, orders.status); see the ENUM note at the foot of this
  -- file for why an ENUM type is NOT used here.
  tier text NOT NULL DEFAULT 'starter' CHECK (tier IN ('starter', 'pro')),

  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz DEFAULT NULL
);

-- the public directory: a customer resolving a slug reads exactly one row here.
CREATE INDEX stores_slug_lookup_idx ON stores (slug);
-- the owner's "my stores" list narrows on tier (analytics gating reads it).
CREATE INDEX stores_tier_idx ON stores (tier);

-- Seed the legacy store. The id literal MUST match the store_id defaults below.
INSERT INTO stores (id, slug, name, city, tier)
  VALUES ('00000000-0000-0000-8333-000000000001', 'flagship', 'Sleepless Cafe', 'Home', 'starter')
  ON CONFLICT (slug) DO NOTHING;

ALTER TABLE stores ENABLE ROW LEVEL SECURITY;


-- ----------------------------------------------------------------------------
-- store_id on every relational table.
--
-- DEFAULT is a CONSTANT literal, so PostgreSQL fills existing rows without
-- rewriting the table. REFERENCES stores (id) ON DELETE RESTRICT mirrors menu_items
-- -> categories in 01: deleting a store that still holds orders is REFUSED, not
-- silently orphaned - the branch must be emptied (or voided) first.
-- ----------------------------------------------------------------------------
ALTER TABLE menu_items
  ADD COLUMN store_id uuid NOT NULL
    DEFAULT '00000000-0000-0000-8333-000000000001'
    REFERENCES stores (id) ON DELETE RESTRICT;

ALTER TABLE categories
  ADD COLUMN store_id uuid NOT NULL
    DEFAULT '00000000-0000-0000-8333-000000000001'
    REFERENCES stores (id) ON DELETE RESTRICT;

ALTER TABLE orders
  ADD COLUMN store_id uuid NOT NULL
    DEFAULT '00000000-0000-0000-8333-000000000001'
    REFERENCES stores (id) ON DELETE RESTRICT;

-- staff_roster gains the store axis: a staff identity belongs to ONE branch.
ALTER TABLE staff_roster
  ADD COLUMN store_id uuid NOT NULL
    DEFAULT '00000000-0000-0000-8333-000000000001'
    REFERENCES stores (id) ON DELETE RESTRICT;

-- order_items deliberately gets NO store_id column: an item's branch is its
-- parent claim's branch, and a second column could drift out of agreement with
-- it. The FK (order_id -> orders, ON DELETE CASCADE) already ties them, and the
-- policies below derive the branch from the parent instead. Only the audit
-- timestamp is added.
ALTER TABLE order_items ADD COLUMN created_at timestamptz NOT NULL DEFAULT now();
ALTER TABLE menu_items ADD COLUMN updated_at timestamptz DEFAULT NULL;
ALTER TABLE categories ADD COLUMN updated_at timestamptz DEFAULT NULL;


-- ----------------------------------------------------------------------------
-- INDEXES. The hot paths in 02 narrow on (store_id, status) and (store_id,
-- expires_at); the partial index stays tiny even as paid history grows, exactly
-- as orders_live_pending_idx does today - it is only widened by one column.
-- ----------------------------------------------------------------------------
CREATE INDEX orders_store_status_idx ON orders (store_id, status);
CREATE INDEX orders_store_live_idx
  ON orders (store_id, expires_at)
  WHERE status = 'pending_payment';
CREATE INDEX menu_items_store_idx ON menu_items (store_id, is_available);
CREATE INDEX categories_store_idx ON categories (store_id, display_order);
CREATE INDEX staff_roster_store_idx ON staff_roster (store_id, role, active);


-- ----------------------------------------------------------------------------
-- JWT STORE CONTEXT. Every store-scoped policy below calls this helper, which
-- reads NO table - so a policy expression can never recurse into another policy
-- over the same table (the trap a roster-derived store lookup would hit:
-- roster_authenticated_read -> staff_store_id() -> SELECT staff_roster ->
-- roster_authenticated_read -> ...). The store axis therefore travels IN the
-- token; staff_roster.store_id stays the authoritative server-side record and
-- the function bodies cross-check the two (STORE_MISMATCH).
--
-- Two claim shapes, both supported:
--   sid                 - a short-lived customer token minted server-side
--                         (role: anon) when a QR is scanned.
--   user_metadata.sid   - a Supabase Auth identity whose signup POST carried
--                         {"data":{"sid":"<store uuid>"}}; GoTrue nests the
--                         `data` object under user_metadata in the JWT.
-- The regex guard is deliberate: casting a malformed claim raises, and a policy
-- that raises denies the row - but it also turns a typo into an opaque 500
-- rather than an honest empty result.
-- ----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION jwt_store_id ()
RETURNS uuid AS $$
DECLARE
  claims jsonb;
  sid text;
BEGIN
  claims := COALESCE(NULLIF(current_setting('request.jwt.claims', true), '')::jsonb, '{}');
  sid := COALESCE(claims ->> 'sid', claims -> 'user_metadata' ->> 'sid', '');
  IF sid !~ '^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$' THEN
    RETURN NULL;
  END IF;
  RETURN sid::uuid;
END;
$$ LANGUAGE plpgsql;

-- the caller's tier, read from the store its token names. stores is readable by
-- anon (public directory) and by authenticated (own store), so both can call
-- this; the value is only advisory for anon - the hard gates live in the
-- authenticated function bodies.
CREATE OR REPLACE FUNCTION store_tier_of (p_store_id uuid)
RETURNS text AS $$
BEGIN
  RETURN COALESCE((SELECT s.tier FROM stores AS s WHERE s.id = p_store_id), '');
END;
$$ LANGUAGE plpgsql;

-- the Tier 1 hard cap, as a callable so a POLICY can use it. The count lives in
-- a function rather than inline in the policy because an unqualified `store_id`
-- inside a policy's subquery would resolve to the SUBQUERY's alias (the same
-- ambiguity class as the `email` local in 07) and silently become a tautology.
-- An unknown store means "refuse", which is the safe direction.
CREATE OR REPLACE FUNCTION cap_allows (p_store_id uuid)
RETURNS boolean AS $$
DECLARE
  live integer;
BEGIN
  IF store_tier_of(p_store_id) = 'pro' THEN
    RETURN true;
  END IF;
  IF store_tier_of(p_store_id) = '' THEN
    RETURN false;
  END IF;
  live := COALESCE((SELECT COUNT(1) FROM menu_items AS m WHERE m.store_id = p_store_id), 0);
  RETURN live < 25;
END;
$$ LANGUAGE plpgsql;

-- the tier boundary, as a callable. Every Tier 2 RPC calls this FIRST; the
-- frontend hiding a tab is cosmetic, this is the enforcement (see §5 in the
-- spec for the function delta that wires it in).
CREATE OR REPLACE FUNCTION tier_gate (p_store_id uuid, p_need text)
RETURNS text AS $$
DECLARE
  t text;
BEGIN
  t := store_tier_of(p_store_id);
  IF t = '' THEN RETURN 'STORE_UNKNOWN'; END IF;
  IF p_need = 'pro' AND t <> 'pro' THEN RETURN 'TIER_REQUIRED'; END IF;
  RETURN 'OK';
END;
$$ LANGUAGE plpgsql;

-- Tier 1 owner surface: availability toggles ONLY. A Tier 1 caller that tries
-- to rename or reprice is refused here, so the Starter owner can flip In Stock /
-- Out of Stock and nothing else. (Phase 9d folds this call into update_menu_item's
-- body; it is stated here as the contract.)
CREATE OR REPLACE FUNCTION starter_write_gate (p_menu_item_id uuid, p_name text, p_description text, p_sizes jsonb, p_image text)
RETURNS text AS $$
DECLARE
  sid uuid;
BEGIN
  sid := (SELECT m.store_id FROM menu_items AS m WHERE m.id = p_menu_item_id);
  IF store_tier_of(sid) = 'pro' THEN RETURN 'OK'; END IF;
  IF COALESCE(p_name, '') <> '' OR COALESCE(p_description, '') <> ''
     OR p_sizes IS NOT NULL OR COALESCE(p_image, '') <> '' THEN
    RETURN 'TIER_REQUIRED';
  END IF;
  RETURN 'OK';
END;
$$ LANGUAGE plpgsql;


-- ----------------------------------------------------------------------------
-- PUBLIC STORE DIRECTORY. anon may read OPEN stores so a visitor can resolve a
-- slug; it never reads a closed or hidden store. authenticated additionally
-- reads its own store even when is_open = false (the owner's dashboard has to
-- see a temporarily closed branch).
-- ----------------------------------------------------------------------------
DROP POLICY IF EXISTS stores_read_public ON stores;
CREATE POLICY stores_read_public ON stores FOR SELECT TO anon
  USING ( is_open = true );

DROP POLICY IF EXISTS stores_staff_read ON stores;
CREATE POLICY stores_staff_read ON stores FOR SELECT TO authenticated
  USING ( jwt_store_id() IS NOT NULL AND store_id = jwt_store_id() );


-- ----------------------------------------------------------------------------
-- MENU / CATEGORY READ - CUSTOMER (anon), now store-scoped.
--
-- BEFORE (03_rls.sql): USING ( true ) on menu_items and categories. For one
--   store that is the whole point - the catalogue is public commercial data.
--   For many stores it is a CROSS-TENANT LEAK: a raw GET /rest/v1/menu_items
--   with only the publishable key returns every branch's catalogue.
-- AFTER: the row must belong to the store the token names, and only available
--   items are visible. An anon request that carries NO sid claim (the plain
--   publishable key) resolves to NULL and therefore reads NOTHING.
--
-- !!! PHASE 9c, NOT 9a. These policies only work once a customer request carries
--   a store token (see MULTI_TENANT_SPEC §4). Applying them before that step
--   makes menu.html read an empty catalogue for every visitor - which is why
--   they are in a separate section from the schema block above.
--
-- is_available = true here is the "active menu items" requirement: a hidden
--   item is invisible to a customer even inside the right store.
-- ----------------------------------------------------------------------------
DROP POLICY IF EXISTS menu_read_public ON menu_items;      -- retire 03's broad read
DROP POLICY IF EXISTS menu_read_store_anon ON menu_items;
CREATE POLICY menu_read_store_anon ON menu_items FOR SELECT TO anon
  USING ( jwt_store_id() IS NOT NULL
          AND store_id = jwt_store_id()
          AND is_available = true );

DROP POLICY IF EXISTS categories_read_public ON categories;
DROP POLICY IF EXISTS categories_read_store_anon ON categories;
CREATE POLICY categories_read_store_anon ON categories FOR SELECT TO anon
  USING ( jwt_store_id() IS NOT NULL AND store_id = jwt_store_id() );

-- authenticated keeps the menu readable across its own store (the owner's
-- builder needs hidden items too, so no is_available clause here).
DROP POLICY IF EXISTS menu_read_store_auth ON menu_items;
CREATE POLICY menu_read_store_auth ON menu_items FOR SELECT TO authenticated
  USING ( jwt_store_id() IS NOT NULL AND store_id = jwt_store_id() );

DROP POLICY IF EXISTS categories_read_store_auth ON categories;
CREATE POLICY categories_read_store_auth ON categories FOR SELECT TO authenticated
  USING ( jwt_store_id() IS NOT NULL AND store_id = jwt_store_id() );


-- ----------------------------------------------------------------------------
-- MENU WRITES - store-scoped AND tier-capped.
--
-- The cap has TWO layers, and both are needed:
--   * cap_allows(store_id) in the policy is the HARD backstop - it holds even
--     for a caller that bypasses the RPC (a direct POST /rest/v1/menu_items).
--   * create_menu_item's body (Phase 9d, see MULTI_TENANT_SPEC §5) restates it
--     so the refusal arrives as MENU_LIMIT_REACHED human copy, not a raw FK/RLS
--     error. RLS alone cannot produce that copy.
-- WITH CHECK restates the row SHAPE CHECKs from 01 so a signed-in member cannot
-- plant an illegal row even though they hold the write policy.
-- ----------------------------------------------------------------------------
DROP POLICY IF EXISTS menu_items_staff_write ON menu_items;
DROP POLICY IF EXISTS menu_items_staff_write_store ON menu_items;
CREATE POLICY menu_items_staff_write_store ON menu_items FOR ALL TO authenticated
  USING ( jwt_store_id() IS NOT NULL AND store_id = jwt_store_id() )
  WITH CHECK ( jwt_store_id() IS NOT NULL
               AND store_id = jwt_store_id()
               AND LENGTH(TRIM(name)) BETWEEN 1 AND 120
               AND cap_allows(store_id) );

DROP POLICY IF EXISTS categories_staff_write ON categories;
DROP POLICY IF EXISTS categories_staff_write_store ON categories;
CREATE POLICY categories_staff_write_store ON categories FOR ALL TO authenticated
  USING ( jwt_store_id() IS NOT NULL AND store_id = jwt_store_id() )
  WITH CHECK ( jwt_store_id() IS NOT NULL
               AND store_id = jwt_store_id()
               AND LENGTH(TRIM(name)) BETWEEN 1 AND 80 );


-- ----------------------------------------------------------------------------
-- ORDERS / ORDER_ITEMS - CUSTOMER WRITE DOOR, store-scoped.
-- anon may still only ever CREATE a live unpaid claim, and now only inside the
-- store its token names. anon holds NO SELECT on orders (unchanged from 03), so
-- a customer still cannot see paid history or another customer's claim.
-- ----------------------------------------------------------------------------
DROP POLICY IF EXISTS orders_customer_insert ON orders;
DROP POLICY IF EXISTS orders_customer_insert_store ON orders;
CREATE POLICY orders_customer_insert_store ON orders FOR INSERT TO anon
  WITH CHECK ( jwt_store_id() IS NOT NULL
               AND store_id = jwt_store_id()
               AND status = 'pending_payment' );

DROP POLICY IF EXISTS order_items_customer_insert ON order_items;
DROP POLICY IF EXISTS order_items_customer_insert_store ON order_items;
CREATE POLICY order_items_customer_insert_store ON order_items FOR INSERT TO anon
  WITH CHECK ( true );
-- order_items carries no store_id column (it inherits through orders), so the
-- anon fence here stays shape-only; the parent-link fence lives in create_order,
-- exactly as 03_rls.sql documents.

-- ----------------------------------------------------------------------------
-- ORDERS / ORDER_ITEMS - STAFF READ/WRITE, store-scoped.
-- This is the headline change: 03's USING ( true ) becomes "own store only".
-- DELETE / UPDATE need SELECT rights, so the SELECT policy above is what lets
-- the two below run at all.
--
-- order_items has no store_id column, so its fence DERIVES the branch from the
-- parent claim. The comparison is written subquery-first against jwt_store_id()
-- rather than `store_id = (...)`, because an unqualified `store_id` here would
-- resolve to the subquery's alias and become a tautology.
-- order_items CAN reference orders in its policy expression: authenticated holds
-- SELECT on orders for the same action (orders_staff_read_store), which is the
-- rule 03 warns about ("a policy expression may only read tables the caller can
-- already read for that same action"). anon holds no SELECT on orders, which is
-- why the anon INSERT policy above stays shape-only.
-- ----------------------------------------------------------------------------
DROP POLICY IF EXISTS orders_staff_read ON orders;
DROP POLICY IF EXISTS orders_staff_read_store ON orders;
CREATE POLICY orders_staff_read_store ON orders FOR SELECT TO authenticated
  USING ( jwt_store_id() IS NOT NULL AND store_id = jwt_store_id() );

DROP POLICY IF EXISTS order_items_staff_read ON order_items;
DROP POLICY IF EXISTS order_items_staff_read_store ON order_items;
CREATE POLICY order_items_staff_read_store ON order_items FOR SELECT TO authenticated
  USING ( jwt_store_id() IS NOT NULL
          AND (SELECT o.store_id FROM orders AS o WHERE o.id = order_id) = jwt_store_id() );

DROP POLICY IF EXISTS order_items_staff_write ON order_items;
DROP POLICY IF EXISTS order_items_staff_write_store ON order_items;
CREATE POLICY order_items_staff_write_store ON order_items FOR ALL TO authenticated
  USING ( jwt_store_id() IS NOT NULL
          AND (SELECT o.store_id FROM orders AS o WHERE o.id = order_id) = jwt_store_id() )
  WITH CHECK ( jwt_store_id() IS NOT NULL
               AND (SELECT o.store_id FROM orders AS o WHERE o.id = order_id) = jwt_store_id()
               AND quantity >= 1
               AND subtotal = unit_price * quantity );

DROP POLICY IF EXISTS orders_staff_update ON orders;
DROP POLICY IF EXISTS orders_staff_update_store ON orders;
CREATE POLICY orders_staff_update_store ON orders FOR UPDATE TO authenticated
  USING ( jwt_store_id() IS NOT NULL AND store_id = jwt_store_id() )
  WITH CHECK ( jwt_store_id() IS NOT NULL
               AND store_id = jwt_store_id()
               AND ( ( status = 'pending_payment' AND paid_at IS NULL )
                     OR ( ( status = 'paid' OR status = 'preparing' OR status = 'served' )
                          AND paid_at IS NOT NULL ) ) );

DROP POLICY IF EXISTS orders_staff_delete ON orders;
DROP POLICY IF EXISTS orders_staff_delete_store ON orders;
CREATE POLICY orders_staff_delete_store ON orders FOR DELETE TO authenticated
  USING ( jwt_store_id() IS NOT NULL AND store_id = jwt_store_id() AND status = 'pending_payment' );
-- The core invariant survives: only live unpaid claims are deletable, so a paid
-- sale stays physically undeletable - now also per-branch.


-- ----------------------------------------------------------------------------
-- TIER IS NOT SELF-SERVABLE. An owner must not be able to flip their own store
-- to 'pro' for free, and RLS is the boundary that makes that true.
--
-- PostgreSQL cannot compare "old tier vs new tier" in one expression, so the
-- pin is TWO policies, one per tier value: USING pins the row being edited and
-- WITH CHECK pins the row being produced. A tier CHANGE would have to satisfy
-- USING (tier='starter') AND WITH CHECK (tier='pro') at once, which no policy
-- allows - so authenticated may edit name / city / is_open / timezone forever,
-- and may never change tier.
-- ----------------------------------------------------------------------------
DROP POLICY IF EXISTS stores_owner_update_starter ON stores;
CREATE POLICY stores_owner_update_starter ON stores FOR UPDATE TO authenticated
  USING ( jwt_store_id() IS NOT NULL AND store_id = jwt_store_id() AND tier = 'starter' )
  WITH CHECK ( jwt_store_id() IS NOT NULL
               AND store_id = jwt_store_id()
               AND tier = 'starter'
               AND LENGTH(TRIM(name)) BETWEEN 1 AND 80 );

DROP POLICY IF EXISTS stores_owner_update_pro ON stores;
CREATE POLICY stores_owner_update_pro ON stores FOR UPDATE TO authenticated
  USING ( jwt_store_id() IS NOT NULL AND store_id = jwt_store_id() AND tier = 'pro' )
  WITH CHECK ( jwt_store_id() IS NOT NULL
               AND store_id = jwt_store_id()
               AND tier = 'pro'
               AND LENGTH(TRIM(name)) BETWEEN 1 AND 80 );

-- The tier flip itself belongs to the server side only. service_role is the
-- role PostgREST SETs for the SECRET key, which is never shipped to a browser
-- (HANDOFF §2), so this policy is reachable only from Edge Function / server
-- tooling. There is deliberately NO anon INSERT and no authenticated INSERT on
-- stores: creating a branch is a provisioning decision, not a browser action.
DROP POLICY IF EXISTS stores_service_insert ON stores;
CREATE POLICY stores_service_insert ON stores FOR INSERT TO service_role
  WITH CHECK ( slug IS NOT NULL AND tier IN ('starter', 'pro') );

DROP POLICY IF EXISTS stores_service_update ON stores;
CREATE POLICY stores_service_update ON stores FOR UPDATE TO service_role
  USING ( true )
  WITH CHECK ( tier IN ('starter', 'pro') AND slug IS NOT NULL );

DROP POLICY IF EXISTS stores_service_delete ON stores;
CREATE POLICY stores_service_delete ON stores FOR DELETE TO service_role
  USING ( true );


-- ----------------------------------------------------------------------------
-- ROSTER READ/WRITE, store-scoped. A staff identity belongs to one branch, so
-- an owner of store A can no longer enumerate or edit store B's roster. anon
-- still holds NO policy at all on staff_roster (07), so usernames stay
-- unenumerable.
-- ----------------------------------------------------------------------------
DROP POLICY IF EXISTS roster_authenticated_read ON staff_roster;
DROP POLICY IF EXISTS roster_authenticated_read_store ON staff_roster;
CREATE POLICY roster_authenticated_read_store ON staff_roster FOR SELECT TO authenticated
  USING ( jwt_store_id() IS NOT NULL AND store_id = jwt_store_id() );

DROP POLICY IF EXISTS roster_authenticated_write_insert ON staff_roster;
DROP POLICY IF EXISTS roster_authenticated_write_insert_store ON staff_roster;
CREATE POLICY roster_authenticated_write_insert_store ON staff_roster FOR INSERT TO authenticated
  WITH CHECK ( jwt_store_id() IS NOT NULL
               AND store_id = jwt_store_id()
               AND email ~ '^[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}$'
               AND LENGTH(TRIM(display_name)) BETWEEN 1 AND 60 );

DROP POLICY IF EXISTS roster_authenticated_write_update ON staff_roster;
DROP POLICY IF EXISTS roster_authenticated_write_update_store ON staff_roster;
CREATE POLICY roster_authenticated_write_update_store ON staff_roster FOR UPDATE TO authenticated
  USING ( jwt_store_id() IS NOT NULL AND store_id = jwt_store_id() )
  WITH CHECK ( jwt_store_id() IS NOT NULL
               AND store_id = jwt_store_id()
               AND email ~ '^[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}$'
               AND LENGTH(TRIM(display_name)) BETWEEN 1 AND 60 );

DROP POLICY IF EXISTS roster_authenticated_delete ON staff_roster;
DROP POLICY IF EXISTS roster_authenticated_delete_store ON staff_roster;
CREATE POLICY roster_authenticated_delete_store ON staff_roster FOR DELETE TO authenticated
  USING ( jwt_store_id() IS NOT NULL AND store_id = jwt_store_id() );


-- ----------------------------------------------------------------------------
-- SLUG -> STORE RESOLUTION (the customer entry path). anon-callable, so a
-- visitor holding only the publishable key can find their branch. A closed or
-- unknown slug answers STORE_NOT_FOUND with no id, so a closed branch cannot be
-- probed for its catalogue.
-- ----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION resolve_store (p_slug text)
RETURNS jsonb AS $$
DECLARE
  row_s jsonb;
BEGIN
  row_s := (SELECT jsonb_build_object('id', s.id, 'slug', s.slug, 'name', s.name,
                                      'tier', s.tier, 'is_open', s.is_open)
            FROM stores AS s WHERE s.slug = p_slug AND s.is_open = true);
  IF row_s IS NULL THEN
    RETURN jsonb_build_object('success', false, 'data', NULL,
      'error', jsonb_build_object('code', 'STORE_NOT_FOUND',
        'message', 'that branch is not open right now'));
  END IF;
  RETURN jsonb_build_object('success', true, 'data', row_s, 'error', NULL);
END;
$$ LANGUAGE plpgsql;

-- The catalogue for one branch, as ONE call. This is the shape the customer
-- page should cache per visit; it is store-scoped by the anon policies above,
-- so the caller's token must carry the matching sid claim.
CREATE OR REPLACE FUNCTION menu_for_store (p_store_id uuid)
RETURNS jsonb AS $$
DECLARE
  rows jsonb;
BEGIN
  rows := COALESCE((SELECT jsonb_agg(jsonb_build_object(
                       'id', m.id, 'name', m.name, 'description', m.description,
                       'image_url', m.image_url, 'sizes_and_prices', m.sizes_and_prices,
                       'category_id', m.category_id)
                     ORDER BY m.name ASC)
              FROM menu_items AS m WHERE m.store_id = p_store_id AND m.is_available = true),
              '[]'::jsonb);
  RETURN jsonb_build_object('success', true, 'data', rows, 'error', NULL);
END;
$$ LANGUAGE plpgsql;

CREATE OR REPLACE FUNCTION categories_for_store (p_store_id uuid)
RETURNS jsonb AS $$
DECLARE
  rows jsonb;
BEGIN
  rows := COALESCE((SELECT jsonb_agg(jsonb_build_object('id', c.id, 'name', c.name,
                                                        'display_order', c.display_order)
                                   ORDER BY c.display_order ASC)
                    FROM categories AS c WHERE c.store_id = p_store_id), '[]'::jsonb);
  RETURN jsonb_build_object('success', true, 'data', rows, 'error', NULL);
END;
$$ LANGUAGE plpgsql;


-- ----------------------------------------------------------------------------
-- PER-BRANCH TTL SWEEP. Same mechanism as purge_expired_orders in 02 (a
-- physical DELETE, covered by orders_staff_delete_store, cascading to
-- order_items). Narrowed to one branch so a multi-store sweep costs one
-- indexed slice per store instead of one global scan.
-- ----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION purge_expired_orders_store (p_store_id uuid)
RETURNS jsonb AS $$
DECLARE
  n integer;
BEGIN
  n := COALESCE((SELECT COUNT(1) FROM orders AS o
                 WHERE o.store_id = p_store_id
                   AND o.status = 'pending_payment'
                   AND o.expires_at < now()), 0);
  IF n = 0 THEN
    RETURN jsonb_build_object('success', true, 'data', jsonb_build_object('purged', 0), 'error', NULL);
  END IF;
  DELETE FROM orders AS o
    WHERE o.store_id = p_store_id AND o.status = 'pending_payment' AND o.expires_at < now();
  RETURN jsonb_build_object('success', true,
    'data', jsonb_build_object('purged', n, 'store_id', p_store_id), 'error', NULL);
END;
$$ LANGUAGE plpgsql;

-- All-branch sweep for the cron job: one DELETE over the partial index, no
-- per-store loop. Kept separate so the cron artifact in tools/cron/ can call
-- exactly one RPC.
CREATE OR REPLACE FUNCTION purge_expired_orders_all ()
RETURNS jsonb AS $$
DECLARE
  n_before integer; n_after integer;
BEGIN
  n_before := COALESCE((SELECT COUNT(1) FROM orders AS o
                        WHERE o.status = 'pending_payment' AND o.expires_at < now()), 0);
  DELETE FROM orders AS o
    WHERE o.status = 'pending_payment' AND o.expires_at < now();
  n_after := COALESCE((SELECT COUNT(1) FROM orders AS o
                       WHERE o.status = 'pending_payment' AND o.expires_at < now()), 0);
  RETURN jsonb_build_object('success', true,
    'data', jsonb_build_object('purged', n_before - n_after), 'error', NULL);
END;
$$ LANGUAGE plpgsql;


-- ----------------------------------------------------------------------------
-- OPTIONAL: analytics ledger. NOT required by the current analytics - sales_summary
-- / sales_report / turnover_stats in 02 derive everything from orders, which is
-- cheaper and already correct. Add this ONLY if you want a per-event audit trail
-- (e.g. a paid plan's export, or a per-store daily rollup cache). It costs a
-- write per event, so it is deliberately commented OUT rather than half-live.
--
-- CREATE TABLE analytics_logs
-- (
--   id uuid NOT NULL PRIMARY KEY DEFAULT gen_random_uuid(),
--   store_id uuid NOT NULL DEFAULT '00000000-0000-0000-8333-000000000001'
--     REFERENCES stores (id) ON DELETE CASCADE,
--   event text NOT NULL CHECK (event IN ('claim_created','claim_paid','claim_served','claim_voided','claim_expired')),
--   order_id uuid DEFAULT NULL,
--   amount numeric(10,2) DEFAULT 0,
--   created_at timestamptz NOT NULL DEFAULT now()
-- );
-- CREATE INDEX analytics_logs_store_idx ON analytics_logs (store_id, created_at);
-- ALTER TABLE analytics_logs ENABLE ROW LEVEL SECURITY;
-- (then one SELECT policy TO authenticated USING (jwt_store_id() = store_id), and
--  an INSERT policy only if a function, not a page, writes it.)
-- ============================================================================
-- END 08_multitenant.sql
-- ============================================================================
