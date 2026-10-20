-- ===========================================================================
-- sql/06_storage.sql — Phase 5: menu-photo Storage ACLs.
--
-- Bucket: `menu-images` (PUBLIC, created once in the Dashboard "Files -> New
-- bucket" dialog; 50 MB default object size, no MIME restriction).
--
-- WHY THIS FILE EXISTS
--   Creating a bucket is not enough. Supabase Storage is now backed by the
--   `storage` namespace (tables `storage.bucket` + `storage.objects`) and those
--   tables have RLS enabled, so an upload with no matching policy fails:
--       POST /storage/v1/object/menu-images/<slug>  ->  403 AccessDenied
--       { "message": "new row violates row-level security policy" }
--   Probed live on this project (anon, publishable key only).
--
-- DESIGN (matches the comment above uploadImage in assets/api.js)
--   * anon (publishable key, no user session) can NEVER write objects.
--   * authenticated (anyone who passed Supabase Auth password login — cashier,
--     kitchen, owner) may write objects in `menu-images` ONLY.
--   * The bucket is public, so the object is readable without a session through
--     `${sbUrl}/storage/v1/object/public/menu-images/<slug>` — which is exactly
--     the URL stored in `menu_items.image_url` and rendered by <img> tags on
--     menu.html / cashier.html / owner.html.
--   * `assets/api.js` sends `Authorization: Bearer <access_token>` on the upload
--     (HEADERS.Authorization is swapped by setSessionToken), so the browser
--     upload runs as the `authenticated` Postgres role, never as anon.
--
-- NOTE: `bucket_id` is the column the Dashboard's own policy builder prefilters
--   on ("Adding new policy to menu-images" -> `bucket_id = 'menu-images'`).
--   UPDATE needs a SELECT policy to see the existing row (Postgres RLS rule),
--   hence the select policy below.
-- ===========================================================================

-- Idempotent: drop-then-create so this file can be re-pasted after an edit.
-- Policy names live per-table; keep them unique across the file.

-- 1. read (needed for x-upsert overwrite of an existing slug)
DROP POLICY IF EXISTS "Menu photos readable by signed-in staff" ON storage.objects;
CREATE POLICY "Menu photos readable by signed-in staff"
ON storage.objects FOR SELECT
TO authenticated
USING ( bucket_id = 'menu-images' );

-- 2. write (new photo)
DROP POLICY IF EXISTS "Menu photos writable by signed-in staff" ON storage.objects;
CREATE POLICY "Menu photos writable by signed-in staff"
ON storage.objects FOR INSERT
TO authenticated
WITH CHECK ( bucket_id = 'menu-images' );

-- 3. write (re-upload of the same slug, x-upsert)
DROP POLICY IF EXISTS "Menu photos editable by signed-in staff" ON storage.objects;
CREATE POLICY "Menu photos editable by signed-in staff"
ON storage.objects FOR UPDATE
TO authenticated
USING ( bucket_id = 'menu-images' )
WITH CHECK ( bucket_id = 'menu-images' );

-- 4. write (cleanup of a stale test object)
DROP POLICY IF EXISTS "Menu photos deletable by signed-in staff" ON storage.objects;
CREATE POLICY "Menu photos deletable by signed-in staff"
ON storage.objects FOR DELETE
TO authenticated
USING ( bucket_id = 'menu-images' );

-- ---------------------------------------------------------------------------
-- BUCKET LISTING (optional, deliberately NOT granted)
--   GET /storage/v1/bucket with the publishable key returns [] because anon has
--   no SELECT policy on storage.bucket. That is fine: nothing in this app lists
--   buckets — the bucket name is a constant in assets/api.js. Do not add an
--   anon policy here unless a page needs it.
--
-- VERIFICATION (run after pasting this file, from assets/api.js' transport):
--   1. signed-in owner uploads  -> 200/201, then
--      GET `${sbUrl}/storage/v1/object/public/menu-images/<slug>`  -> 200 image
--   2. anon upload attempt      -> still 403 AccessDenied (proves the ACL)
-- ---------------------------------------------------------------------------

-- ===========================================================================
-- APPLIED LIVE (this project, via the Dashboard Storage policy builder — the
-- SQL Editor's Monaco editor never initialised in this browser, so the
-- builder UI was used instead; it emits the same grants, with its own
-- auto-suffixed policy names).
--
-- Live policy rows on `storage.objects`, all filtered by bucket_id = 'menu-images':
--   menu_images_upload                 INSERT     authenticated
--   menu_images_staff_rw_1xs2w12_0     DELETE     authenticated
--   menu_images_staff_rw_1xs2w12_1     SELECT     authenticated
--   menu_images_update_1xs2w12_0       UPDATE     authenticated
--   menu_images_update_1xs2w12_1       SELECT     authenticated
--
--   The builder writes `USING (bucket_id = 'menu-images')` for every operation
--   (no separate WITH CHECK), which is equivalent to the four grants above for
--   this single-bucket project. If you re-paste this file, it replaces the
--   builder rows with the hand-written names — do not run both sets at once.
--
-- Live evidence (owner session bearer = role `authenticated`, sub e5db228e-…):
--   POST /storage/v1/object/menu-images/zz_probe2.png   (no x-upsert) -> 200
--        { "Key": "menu-images/zz_probe2.png", "Id": "cf206835-…" }
--   POST …/zz_probe2.png  with x-upsert: true, BEFORE update policy -> 403
--        { "message": "new row violates row-level security policy" }
--   POST …/zz_probe2.png  with x-upsert: true, AFTER  update policy -> 200
--   GET  /storage/v1/object/public/menu-images/zz_probe2.png          -> 200 (70 B)
--   DELETE /storage/v1/object/menu-images/zz_probe2.png               -> 200 "Successfully deleted"
--   POST /storage/v1/object/menu-images/zz_anon.png  (publishable key only) -> 403
--        { "statusCode": "403", "code": "AccessDenied" }
-- ===========================================================================
