-- ============================================================================
-- 05_seed.sql :: PHASE 1e - STARTER MENU (dev build content)
-- ============================================================================
-- APPLY LAST, after 04_realtime.sql. Idempotent: re-running must not duplicate
-- rows. Every insert is keyed on FIXED literal UUIDs and guarded by
-- ON CONFLICT (id) DO NOTHING, so a second run is a strict no-op.
-- No DELETE, no TRUNCATE anywhere in this file - it can never wipe real data.
-- Prices are PHP (₱). image_url stays '' until Storage upload lands in Phase 5.
-- sizes_and_prices keys are exactly "size" and "price" - create_order in
-- 02_functions.sql reads those two keys and nothing else.
-- ============================================================================

-- ----------------------------------------------------------------------------
-- categories (display_order 1..4)
-- ----------------------------------------------------------------------------
INSERT INTO categories (id, name, display_order)
VALUES
  ('11111111-1111-1111-8333-000000000001', 'Coffee',     1),
  ('11111111-1111-1111-8333-000000000002', 'Non-Coffee', 2),
  ('11111111-1111-1111-8333-000000000003', 'Pastries',   3),
  ('11111111-1111-1111-8333-000000000004', 'Desserts',   4)
  ON CONFLICT (id) DO NOTHING;

-- ----------------------------------------------------------------------------
-- menu_items :: Coffee (4)
-- ----------------------------------------------------------------------------
INSERT INTO menu_items (id, category_id, name, description, image_url, sizes_and_prices, is_available)
VALUES
  ('22222222-2222-2222-8333-000000000001', '11111111-1111-1111-8333-000000000001',
   'Espresso', 'A single ristretto shot pulled short and syrupy.', '',
   '[{"size":"Single","price":90},{"size":"Double","price":120}]', true),
  ('22222222-2222-2222-8333-000000000002', '11111111-1111-1111-8333-000000000001',
   'Long Black', 'Double shot topped up with hot water, served black.', '',
   '[{"size":"Regular","price":120},{"size":"Large","price":150}]', true),
  ('22222222-2222-2222-8333-000000000003', '11111111-1111-1111-8333-000000000001',
   'Flat White', 'Ristretto base under a thin skin of steamed milk.', '',
   '[{"size":"Regular","price":130},{"size":"Large","price":160}]', true),
  ('22222222-2222-2222-8333-000000000004', '11111111-1111-1111-8333-000000000001',
   'Caramel Latte', 'Latte finished with salted caramel over the foam.', '',
   '[{"size":"Regular","price":140},{"size":"Large","price":170},{"size":"Iced","price":180}]', true)
  ON CONFLICT (id) DO NOTHING;

-- ----------------------------------------------------------------------------
-- menu_items :: Non-Coffee (3)
-- ----------------------------------------------------------------------------
INSERT INTO menu_items (id, category_id, name, description, image_url, sizes_and_prices, is_available)
VALUES
  ('22222222-2222-2222-8333-000000000005', '11111111-1111-1111-8333-000000000002',
   'Hot Chocolate', 'Dark drinking chocolate, no coffee anywhere in it.', '',
   '[{"size":"Regular","price":130},{"size":"Large","price":160}]', true),
  ('22222222-2222-2222-8333-000000000006', '11111111-1111-1111-8333-000000000002',
   'Matcha Latte', 'Stone-ground green tea whisked into steamed milk.', '',
   '[{"size":"Regular","price":140},{"size":"Large","price":170}]', true),
  ('22222222-2222-2222-8333-000000000007', '11111111-1111-1111-8333-000000000002',
   'Iced Lemon Tea', 'Brewed black tea over ice with a squeeze of lemon.', '',
   '[{"size":"Regular","price":110},{"size":"Large","price":140}]', true)
  ON CONFLICT (id) DO NOTHING;

-- ----------------------------------------------------------------------------
-- menu_items :: Pastries (3)
-- ----------------------------------------------------------------------------
INSERT INTO menu_items (id, category_id, name, description, image_url, sizes_and_prices, is_available)
VALUES
  ('22222222-2222-2222-8333-000000000008', '11111111-1111-1111-8333-000000000003',
   'Butter Croissant', 'Laminated in the house, baked fresh at 5am.', '',
   '[{"size":"Single","price":95},{"size":"Two-Pack","price":180}]', true),
  ('22222222-2222-2222-8333-000000000009', '11111111-1111-1111-8333-000000000003',
   'Cinnamon Roll', 'Soft enriched dough swirled with cinnamon sugar.', '',
   '[{"size":"Regular","price":110},{"size":"Large","price":145}]', true),
  ('22222222-2222-2222-8333-000000000010', '11111111-1111-1111-8333-000000000003',
   'Blueberry Muffin', 'Bursting with baked blueberries, lemon-crumb top.', '',
   '[{"size":"Regular","price":105},{"size":"Large","price":135}]', true)
  ON CONFLICT (id) DO NOTHING;

-- ----------------------------------------------------------------------------
-- menu_items :: Desserts (2)
-- ----------------------------------------------------------------------------
INSERT INTO menu_items (id, category_id, name, description, image_url, sizes_and_prices, is_available)
VALUES
  ('22222222-2222-2222-8333-000000000011', '11111111-1111-1111-8333-000000000004',
   'Basque Cheesecake', 'Burnt-top cheesecake, cut into thick wedges.', '',
   '[{"size":"Slice","price":180},{"size":"Whole","price":950}]', true),
  ('22222222-2222-2222-8333-000000000012', '11111111-1111-1111-8333-000000000004',
   'Affogato', 'Vanilla gelato drowned in a shot of espresso.', '',
   '[{"size":"Single","price":160},{"size":"Double","price":210}]', true)
  ON CONFLICT (id) DO NOTHING;

-- ============================================================================
-- VERIFY (paste one at a time in the Supabase Dashboard / psql)
-- ----------------------------------------------------------------------------
-- SELECT count(*) FROM categories;                     -- expect 4
-- SELECT count(*) FROM menu_items;                     -- expect 12
-- SELECT jsonb_pretty((SELECT sizes_and_prices FROM menu_items WHERE name = 'Flat White'));
-- ============================================================================
