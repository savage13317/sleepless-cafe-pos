-- ============================================================================
-- 10_marcelas_store.sql :: PHASE 9g - SECOND STORE (branch) + ITS CATALOGUE
-- APPLY AFTER 01_schema.sql, 02_functions.sql, 03_rls.sql, 04_realtime.sql,
--            05_seed.sql, 06_storage.sql, 07_staff_roster.sql,
--            08_multitenant.sql, 09_function_delta.sql.
--
-- WHAT THIS FILE DOES
--   Bootstraps the second branch, "Marcela's B&B Restaurant" (slug `marcelas`),
--   and seeds its own 4-category / 10-item catalogue. It writes NO other store's
--   rows and mutates NO existing row: three INSERT statements, nothing else.
--
-- IDEMPOTENT: re-running is a strict no-op. Every row is keyed on a FIXED literal
--   UUID (never gen_random_uuid()) and every INSERT ends ON CONFLICT (id) DO
--   NOTHING. No DELETE, no TRUNCATE, no DROP anywhere in this file - it can never
--   wipe real data.
--
-- THE store_id TRAP: menu_items / categories / orders / staff_roster all carry
--   store_id with a CONSTANT default = the legacy flagship uuid
--   00000000-0000-0000-8333-000000000001. Omitting store_id here would silently
--   plant Marcela's breakfast menu inside Sleepless Cafe. store_id is therefore
--   passed EXPLICITLY on every single row below.
--
-- UUID SPACE (legacy pattern: categories 1111..., menu_items 2222...):
--   categories  33333333-3333-3333-8333-0000000000NN
--   menu_items  44444444-4444-4444-8333-0000000000NN   (NN = 01..)
--   store       00000000-0000-0000-8333-000000000002   (flagship is ..0001)
--
-- ORDER MATTERS: the store row first (store_id FKs point at it), then categories,
--   then menu_items (category_id FKs point at Marcela's own categories).
--
-- APOSTROPHE TRAP: the store name contains an apostrophe, so the SQL literal
--   doubles it - 'Marcela''s B&B Restaurant'. A bare apostrophe 400s the query.
--
-- tier = 'starter' is deliberate: flagship is 'pro', so the tier axis stays
--   observable, and a starter store keeps its seeded items under the 25-item
--   cap in cap_allows(). image_url stays '' until Storage upload lands.
--   sizes_and_prices keys are exactly "size" and "price" - create_order in
--   02_functions.sql reads those two keys and nothing else. Prices are PHP (₱).
-- ============================================================================


-- ----------------------------------------------------------------------------
-- THE STORE ROW. slug is what a QR code carries (menu.html?store=marcelas);
-- id is what every table keys on. timezone passes the stores CHECK regex.
-- ----------------------------------------------------------------------------
INSERT INTO stores (id, slug, name, city, timezone, is_open, tier)
  VALUES ('00000000-0000-0000-8333-000000000002', 'marcelas', 'Marcela''s B&B Restaurant', 'Gamay, Northern Samar', 'Asia/Manila', true, 'starter')
  ON CONFLICT (id) DO NOTHING;


-- ----------------------------------------------------------------------------
-- categories (display_order 1..4)
-- ----------------------------------------------------------------------------
INSERT INTO categories (id, name, display_order, store_id, updated_at)
VALUES
  ('33333333-3333-3333-8333-000000000001', 'Silog & Longsilog', 1, '00000000-0000-0000-8333-000000000002', now()),
  ('33333333-3333-3333-8333-000000000002', 'Rice Meals',        2, '00000000-0000-0000-8333-000000000002', now()),
  ('33333333-3333-3333-8333-000000000003', 'Soups & Ulam',      3, '00000000-0000-0000-8333-000000000002', now()),
  ('33333333-3333-3333-8333-000000000004', 'Drinks & Merienda', 4, '00000000-0000-0000-8333-000000000002', now())
  ON CONFLICT (id) DO NOTHING;


-- ----------------------------------------------------------------------------
-- menu_items :: Silog & Longsilog (3) - the B&B breakfast plate
-- ----------------------------------------------------------------------------
INSERT INTO menu_items (id, category_id, name, description, image_url, sizes_and_prices, is_available, store_id, updated_at)
VALUES
  ('44444444-4444-4444-8333-000000000001', '33333333-3333-3333-8333-000000000001',
   'Longsilog Tapsilog', 'Full three-piece plate: seasoned pork, fried rice and a sunny egg.', '',
   '[{"size":"Regular","price":210},{"size":"Sharing","price":380}]', true,
   '00000000-0000-0000-8333-000000000002', now()),
  ('44444444-4444-4444-8333-000000000002', '33333333-3333-3333-8333-000000000001',
   'Tosilog Combo', 'The smaller room-service plate with a glass of calamansi juice.', '',
   '[{"size":"Single","price":150},{"size":"Regular","price":210}]', true,
   '00000000-0000-0000-8333-000000000002', now()),
  ('44444444-4444-4444-8333-000000000003', '33333333-3333-3333-8333-000000000001',
   'Kappa Rice Silog', 'Steamed rice cake alongside a longsilog egg and meat side.', '',
   '[{"size":"Small","price":120},{"size":"Regular","price":180}]', true,
   '00000000-0000-0000-8333-000000000002', now())
  ON CONFLICT (id) DO NOTHING;

-- ----------------------------------------------------------------------------
-- menu_items :: Rice Meals (3) - the counter bowls
-- ----------------------------------------------------------------------------
INSERT INTO menu_items (id, category_id, name, description, image_url, sizes_and_prices, is_available, store_id, updated_at)
VALUES
  ('44444444-4444-4444-8333-000000000004', '33333333-3333-3333-8333-000000000002',
   'Chicken Adobo Rice', 'Vinegar-and-soy chicken stew ladled over plain rice.', '',
   '[{"size":"Regular","price":180},{"size":"Large","price":260}]', true,
   '00000000-0000-0000-8333-000000000002', now()),
  ('44444444-4444-4444-8333-000000000005', '33333333-3333-3333-8333-000000000002',
   'Pork Sisig Plate', 'Spicy minced pork with a calamansi wedge, built on rice.', '',
   '[{"size":"Regular","price":220},{"size":"Large","price":300}]', true,
   '00000000-0000-0000-8333-000000000002', now()),
  ('44444444-4444-4444-8333-000000000006', '33333333-3333-3333-8333-000000000002',
   'Tuna Melt Rice Bowl', 'Flaked tuna melt over garlic rice, the house B&B bowl.', '',
   '[{"size":"Regular","price":190},{"size":"Large","price":270}]', true,
   '00000000-0000-0000-8333-000000000002', now())
  ON CONFLICT (id) DO NOTHING;

-- ----------------------------------------------------------------------------
-- menu_items :: Soups & Ulam (2) - the midday ulam table
-- ----------------------------------------------------------------------------
INSERT INTO menu_items (id, category_id, name, description, image_url, sizes_and_prices, is_available, store_id, updated_at)
VALUES
  ('44444444-4444-4444-8333-000000000007', '33333333-3333-3333-8333-000000000003',
   'Sinigawad Broth', 'Tamarind broth with pork ribs and the three vegetables.', '',
   '[{"size":"Bowl","price":240},{"size":"Pot","price":620}]', true,
   '00000000-0000-0000-8333-000000000002', now()),
  ('44444444-4444-4444-8333-000000000008', '33333333-3333-3333-8333-000000000003',
   'Kareo Ulam', 'Slow-cooked mung stew, the ulam plate served before noon.', '',
   '[{"size":"Plate","price":160},{"size":"Bowl","price":240}]', true,
   '00000000-0000-0000-8333-000000000002', now())
  ON CONFLICT (id) DO NOTHING;

-- ----------------------------------------------------------------------------
-- menu_items :: Drinks & Merienda (2) - coffee hour and the 4pm break
-- ----------------------------------------------------------------------------
INSERT INTO menu_items (id, category_id, name, description, image_url, sizes_and_prices, is_available, store_id, updated_at)
VALUES
  ('44444444-4444-4444-8333-000000000009', '33333333-3333-3333-8333-000000000004',
   'Barley Coffee', 'House barley brew, no coffee bean anywhere in it.', '',
   '[{"size":"Small","price":90},{"size":"Regular","price":120}]', true,
   '00000000-0000-0000-8333-000000000002', now()),
  ('44444444-4444-4444-8333-000000000010', '33333333-3333-3333-8333-000000000004',
   'Puto Steamer', 'Six steamed rice cakes with a banana cue for dipping.', '',
   '[{"size":"Six","price":130},{"size":"Dozen","price":250}]', true,
   '00000000-0000-0000-8333-000000000002', now())
  ON CONFLICT (id) DO NOTHING;


-- ============================================================================
-- VERIFY (call-tests, not syntax checks - paste one at a time)
-- ----------------------------------------------------------------------------
-- SELECT s.slug, s.tier,
--        (SELECT count(*) FROM categories WHERE store_id = s.id),
--        (SELECT count(*) FROM menu_items  WHERE store_id = s.id)
--   FROM stores ORDER BY slug;                    -- expect flagship 5/14 AND marcelas 4/10
--
-- POST /rest/v1/rpc/resolve_store        {"p_slug":"marcelas"}
-- POST /rest/v1/rpc/menu_for_store      {"p_store_id":"00000000-0000-0000-8333-000000000002"}
-- POST /rest/v1/rpc/categories_for_store{"p_store_id":"00000000-0000-0000-8333-000000000002"}
--   -- uuid-arg bodies must come from a FILE (--data-binary @file.json), inline
--   -- escaped JSON raises PGRST102.
-- ============================================================================
