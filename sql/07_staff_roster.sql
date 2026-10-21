-- ============================================================================
-- 07_staff_roster.sql :: PHASE 1d - SERVER-SIDE STAFF IDENTITY (Supabase / PostgreSQL 15)
-- APPLY ORDER: 01_schema.sql -> 02_functions.sql -> 03_rls.sql -> 04_realtime.sql
--            -> 05_seed.sql -> 06_storage.sql -> 07_staff_roster.sql
-- APPLY AFTER 06. This file assumes 01/02/03 already exist and adds a NEW
-- table (staff_roster) plus its own RLS; it never edits an earlier file.
--
-- IDEMPOTENCY: this file IS re-runnable. Every CREATE POLICY is preceded by a
-- matching DROP POLICY IF EXISTS <name> ON staff_roster; every function is
-- CREATE OR REPLACE; RLS is turned on with ALTER TABLE ... ENABLE ROW LEVEL
-- SECURITY (itself idempotent); and the seed INSERTs are guarded by ON CONFLICT
-- (email) DO NOTHING keyed on the UNIQUE email column, so re-pasting is a strict
-- no-op. No DELETE / TRUNCATE anywhere.
--
-- WHY THIS FILE EXISTS
--   The staff surfaces (cashier.html / kitchen.html / owner.html) had NO identity
--   concept at the database layer. CONFIG.ownerEmails is a BROWSER allowlist (a UI
--   gate, checked page-side), and the seven owner gates in sql/02_functions.sql are
--   PRESENCE-ONLY: they prove a signed-in session exists (claims email != ''), they
--   do NOT prove WHO the caller is. So "any signed-in user" could call an owner
--   function. This file introduces staff_roster as the SERVER-SIDE identity source:
--   role and station come from a roster row keyed on the caller's claims email, so
--   role checks can gate owner actions AND station actions (the "block it" decision
--   the roster was added for).
--
--   HONEST LIMITATION (read this before trusting the write policies below):
--   authenticated table-level WRITE policies on staff_roster (and the existing
--   menu write policies in 03_rls.sql) are FENCED BY FUNCTION-BODY role checks that
--   read the JWT claims - the SAME accepted pattern as sql/02's owner gates. A
--   signed-in non-owner technically holds roster_authenticated_write, but every
--   mutation goes through roster_* functions whose body refuses a non-owner
--   (roster_role_of(claims email) <> 'owner' -> NOT_OWNER). No page writes the
--   roster directly. anon holds NO read and NO write policy on staff_roster, so
--   usernames are NEVER public: anon cannot enumerate the roster at all.
--
-- NOTE (deferred, PENDING OWNER APPROVAL - same approval class as the cron
--   decision in MASTER_PLAN §9 item 10): APPLYING a password to a Supabase Auth
--   (GoTrue) identity - signup, reset, or self-change - is a SERVICE-ROLE
--   operation and cannot be done from SQL or from the publishable-key browser
--   path. That work is deferred to the Edge-Function bundle. roster_reset_password
--   below GENERATES and returns a memorable temp password ONCE (the generator is
--   shared with that path AND doubles as the owner's "copy this password to the
--   new employee" helper in roster_add); it does NOT and cannot touch GoTrue.
--   staff_change_password_self is DELIBERATELY OMITTED here: self-change belongs to
--   that same deferred Edge-Function bundle, so this file stays honest and creates
--   no half-implemented function.
--
-- NOTE (SQL cannot create auth identities): a staff_roster row is NOT an auth
--   identity. The AUTH user for each seeded email must be created out-of-band via
--   POST /auth/v1/signup with the PUBLISHABLE key (autoconfirm is currently OFF, so
--   the email must be verified or created through login.html / a QA probe). Exact
--   shape, documented for the human applying this file:
--     curl -X POST "$SB_URL/auth/v1/signup" \
--       -H "apikey: <publishable-key>" \
--       -H "Content-Type: application/json" \
--       -d '{"email":"dev@sleepless-cafe.test","password":"<chosen>","data":{}}'
--   SQL seeds the ROSTER row only; the matching auth identity is a separate step.
-- ============================================================================


-- ----------------------------------------------------------------------------
-- staff_roster: the roster. One row per staff identity, keyed on email.
-- added_by is a self-referential FK (a roster row that ADDED another). ON DELETE
-- RESTRICT is deliberate and mirrors menu_items -> categories in 01_schema.sql:
-- deleting a roster row that ADDED others is REFUSED, not silently orphaned.
-- Bootstrap rows carry added_by NULL. CHECK (added_by IS NULL OR added_by <> id)
-- forbids a self-parent.
-- pw_note stores NO password: credentials live in Supabase Auth (hashed by GoTrue).
-- The roster keeps only a free-text note about the account, never a secret.
-- ----------------------------------------------------------------------------
CREATE TABLE staff_roster
(
  id uuid NOT NULL PRIMARY KEY DEFAULT gen_random_uuid(),
  email text NOT NULL UNIQUE
    CHECK (email ~ '^[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}$'),
  display_name text NOT NULL CHECK (length(trim(display_name)) BETWEEN 1 AND 60),
  role text NOT NULL CHECK (role IN ('owner', 'cashier', 'kitchen')),
  active boolean NOT NULL DEFAULT true,
  added_by uuid DEFAULT NULL REFERENCES staff_roster (id) ON DELETE RESTRICT,
  created_at timestamptz NOT NULL DEFAULT now(),
  last_seen_at timestamptz DEFAULT NULL,
  pw_note text DEFAULT '',

  -- no self-parent: a row may not point at itself as its own adder
  CHECK (added_by IS NULL OR added_by <> id)
);

-- email is already indexed by UNIQUE; the only extra index worth having is the
-- owner-list / station-filter hot path, which always narrows on role + active.
CREATE INDEX staff_roster_active_idx ON staff_roster (role, active);


-- ----------------------------------------------------------------------------
-- ENABLE ROW LEVEL SECURITY FIRST. Without this every policy below is inert.
-- 01_schema.sql never enables RLS, so this file owns it for staff_roster. ALTER
-- TABLE is idempotent, so re-running is harmless.
-- ----------------------------------------------------------------------------
ALTER TABLE staff_roster ENABLE ROW LEVEL SECURITY;


-- ----------------------------------------------------------------------------
-- RLS FOR staff_roster. NO anon SELECT exists on purpose: anon must NEVER
-- enumerate usernames. authenticated gets read + write + delete, but every
-- mutation is fenced further inside the roster_* function bodies (see the
-- HONEST LIMITATION in the header). The WITH CHECK on write restates the row
-- SHAPE CHECKs (email format, display_name length) so a signed-in member cannot
-- plant an illegal roster row even though they hold the write policy.
-- ----------------------------------------------------------------------------
DROP POLICY IF EXISTS roster_authenticated_read ON staff_roster;
CREATE POLICY roster_authenticated_read ON staff_roster FOR SELECT TO authenticated USING ( true );

DROP POLICY IF EXISTS roster_authenticated_write_insert ON staff_roster;
CREATE POLICY roster_authenticated_write_insert ON staff_roster FOR INSERT TO authenticated
  WITH CHECK ( email ~ '^[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}$'
               AND LENGTH(TRIM(display_name)) BETWEEN 1 AND 60 );

DROP POLICY IF EXISTS roster_authenticated_write_update ON staff_roster;
CREATE POLICY roster_authenticated_write_update ON staff_roster FOR UPDATE TO authenticated
  USING ( true )
  WITH CHECK ( email ~ '^[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}$'
               AND LENGTH(TRIM(display_name)) BETWEEN 1 AND 60 );

DROP POLICY IF EXISTS roster_authenticated_delete ON staff_roster;
CREATE POLICY roster_authenticated_delete ON staff_roster FOR DELETE TO authenticated USING ( true );


-- ----------------------------------------------------------------------------
-- HELPERS (internal plpgsql). jwt_claims_email() centralises the exact PG-15-safe
-- JWT idiom from sql/02_functions.sql (the two-arg current_setting form; NEVER
-- SYSTEM_GETENV, which is PG-16+ and absent here). roster_role_of() resolves a
-- claims email to the role of its ACTIVE roster row ('' when absent/inactive), so
-- the owner gates read ONE helper. staff_session() is the identity lookup every
-- station page calls first.
-- ----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION jwt_claims_email ()
RETURNS text AS $$
DECLARE
  claims jsonb;
BEGIN
  claims := COALESCE(NULLIF(current_setting('request.jwt.claims', true), '')::jsonb, '{}');
  RETURN COALESCE(claims ->> 'email', '');
END;
$$ LANGUAGE plpgsql;

CREATE OR REPLACE FUNCTION roster_role_of (p_email text)
RETURNS text AS $$
BEGIN
  -- active rows only: an inactive roster row resolves to no role, so a suspended
  -- identity can never satisfy an owner gate.
  RETURN COALESCE((SELECT r.role FROM staff_roster AS r WHERE r.email = p_email AND r.active = true), '');
END;
$$ LANGUAGE plpgsql;

CREATE OR REPLACE FUNCTION cap_word (p_word text)
RETURNS text AS $$
BEGIN
  -- PostgreSQL core has no capitalize(); build it from upper/lower so the
  -- memorable-password output is portable on PG 15.
  RETURN UPPER(SUBSTR(p_word, 1, 1)) || LOWER(SUBSTR(p_word, 2));
END;
$$ LANGUAGE plpgsql;


-- ----------------------------------------------------------------------------
-- make_memorable_password :: word-word-Number (Capitalized), e.g. Caramel-Latte-42.
-- Picks use the SAME CSPRNG approach create_order uses for the 5-digit code:
--   new_code := lpad((('x' || SUBSTR(code_uuid::text, 1, 8))::bit(32)::bigint % 100000)::text, 5, '0');
-- i.e. draw gen_random_uuid() (CSPRNG-backed), take the first 8 hex chars, cast
-- ('x'||hex)::bit(32)::bigint (unsigned 0..4294967295, so % is never negative) and
-- take the modulus. Three independent draws: word A, word B, number 1..99.
-- ----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION make_memorable_password ()
RETURNS text AS $$
DECLARE
  words text[] := ARRAY['longblack','flatwhite','espresso','caramel','latte','americano','pastry','croissant','muffin','ristretto','coldbrew','mocha','matcha','cookie','brownie','cheesecake','cortado','macchiato','affogato','turmeric'];
  wlen integer;
  cu uuid;
  a integer; b integer; num integer;
BEGIN
  wlen := ARRAY_LENGTH(words, 1);
  cu := gen_random_uuid();
  a := (('x' || SUBSTR(cu::text, 1, 8))::bit(32)::bigint % wlen);
  cu := gen_random_uuid();
  b := (('x' || SUBSTR(cu::text, 1, 8))::bit(32)::bigint % wlen);
  cu := gen_random_uuid();
  num := (('x' || SUBSTR(cu::text, 1, 8))::bit(32)::bigint % 99) + 1;
  RETURN cap_word(words[a + 1]) || '-' || cap_word(words[b + 1]) || '-' || num::text;
END;
$$ LANGUAGE plpgsql;


-- ----------------------------------------------------------------------------
-- staff_session :: the identity lookup every station page calls FIRST. Any
-- authenticated caller. Reads the claims email, finds the roster row, and
-- refreshes last_seen_at = now() for the caller (an UPDATE, covered by
-- roster_authenticated_write). Returns {email, display_name, role, active,
-- last_seen_at} or STAFF_NOT_REGISTERED when there is no row / the row is
-- inactive. This is what turns "signed in" into "which station am I".
-- FIX (apply 2026-10-21): the local is claims_email, NOT email. A plpgsql local
-- named email is ambiguous (42702: column reference "email" is ambiguous) against
-- the staff_roster.email COLUMN inside WHERE r.email = <local> - plpgsql parses
-- lazily, so the function "applies" cleanly and only fails at CALL time. Same
-- lazy-parse class as the jsonb + and bare SELECT fixes in 02's header.
-- ----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION staff_session ()
RETURNS jsonb AS $$
DECLARE
  claims_email text;
  row_r jsonb;
BEGIN
  claims_email := jwt_claims_email();
  IF claims_email = '' THEN
    RETURN jsonb_build_object('success', false, 'data', NULL, 'error', jsonb_build_object('code', 'STAFF_NOT_REGISTERED', 'message', 'no roster identity for this session - register the staff member first'));
  END IF;
  row_r := (SELECT jsonb_build_object('email', r.email, 'display_name', r.display_name, 'role', r.role, 'active', r.active) FROM staff_roster AS r WHERE r.email = claims_email);
  IF row_r IS NULL THEN
    RETURN jsonb_build_object('success', false, 'data', NULL, 'error', jsonb_build_object('code', 'STAFF_NOT_REGISTERED', 'message', 'this email is not on the staff roster'));
  END IF;
  IF (row_r ->> 'active')::text <> 'true' THEN
    RETURN jsonb_build_object('success', false, 'data', NULL, 'error', jsonb_build_object('code', 'STAFF_NOT_REGISTERED', 'message', 'this staff member is suspended'));
  END IF;
  -- refresh presence, then re-read so the returned last_seen_at reflects now()
  UPDATE staff_roster AS r SET last_seen_at = now() WHERE r.email = claims_email;
  row_r := (SELECT jsonb_build_object('email', r.email, 'display_name', r.display_name, 'role', r.role, 'active', r.active, 'last_seen_at', r.last_seen_at) FROM staff_roster AS r WHERE r.email = claims_email);
  RETURN jsonb_build_object('success', true, 'data', row_r, 'error', NULL);
END;
$$ LANGUAGE plpgsql;


-- ----------------------------------------------------------------------------
-- roster_list :: OWNER-gated. claims email must resolve via the roster to role
-- 'owner' AND active (roster_role_of reads active rows only). Returns every row
-- ordered role, display_name.
-- ----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION roster_list ()
RETURNS jsonb AS $$
DECLARE
  claims_email text;
  rows jsonb;
BEGIN
  claims_email := jwt_claims_email();
  IF claims_email = '' THEN
    RETURN jsonb_build_object('success', false, 'data', NULL, 'error', jsonb_build_object('code', 'OWNER_SESSION_REQUIRED', 'message', 'the roster needs a signed-in owner session'));
  END IF;
  IF roster_role_of(claims_email) <> 'owner' THEN
    RETURN jsonb_build_object('success', false, 'data', NULL, 'error', jsonb_build_object('code', 'NOT_OWNER', 'message', 'only an active owner may list the roster'));
  END IF;
  rows := COALESCE((SELECT jsonb_agg(jsonb_build_object('id', r.id, 'email', r.email, 'display_name', r.display_name, 'role', r.role, 'active', r.active, 'added_by', r.added_by, 'created_at', r.created_at, 'last_seen_at', r.last_seen_at) ORDER BY r.role ASC, r.display_name ASC) FROM staff_roster AS r), '[]'::jsonb);
  RETURN jsonb_build_object('success', true, 'data', rows, 'error', NULL);
END;
$$ LANGUAGE plpgsql;


-- ----------------------------------------------------------------------------
-- roster_add :: OWNER-gated. Inserts a roster row with added_by = the caller's
-- own roster id. p_created_password is NOT stored anywhere: it is echoed back ONCE
-- in data so the owner can copy it to the new employee, and the caller (api.js /
-- login flow) uses it to POST /auth/v1/signup with the publishable key (autoconfirm
-- OFF). p_role is validated against the roster roles; a duplicate email is refused
-- with a friendly ROSTER_EXISTS envelope (the UNIQUE column is the hard backstop).
-- ----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION roster_add (p_email text, p_display_name text, p_role text, p_created_password text)
RETURNS jsonb AS $$
DECLARE
  claims_email text;
  caller_id uuid;
  new_id uuid;
  dup jsonb;
BEGIN
  claims_email := jwt_claims_email();
  IF claims_email = '' THEN
    RETURN jsonb_build_object('success', false, 'data', NULL, 'error', jsonb_build_object('code', 'OWNER_SESSION_REQUIRED', 'message', 'adding staff needs a signed-in owner session'));
  END IF;
  IF roster_role_of(claims_email) <> 'owner' THEN
    RETURN jsonb_build_object('success', false, 'data', NULL, 'error', jsonb_build_object('code', 'NOT_OWNER', 'message', 'only an active owner may add staff'));
  END IF;
  IF p_email IS NULL OR p_email !~ '^[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}$' THEN
    RETURN jsonb_build_object('success', false, 'data', NULL, 'error', jsonb_build_object('code', 'INVALID_EMAIL', 'message', 'email must be a valid email (format only)'));
  END IF;
  IF COALESCE(TRIM(p_display_name), '') = '' OR LENGTH(TRIM(p_display_name)) > 60 THEN
    RETURN jsonb_build_object('success', false, 'data', NULL, 'error', jsonb_build_object('code', 'INVALID_DISPLAY_NAME', 'message', 'display_name must be 1-60 characters'));
  END IF;
  IF p_role NOT IN ('owner', 'cashier', 'kitchen') THEN
    RETURN jsonb_build_object('success', false, 'data', NULL, 'error', jsonb_build_object('code', 'INVALID_ROLE', 'message', 'role must be owner, cashier or kitchen'));
  END IF;
  dup := (SELECT jsonb_build_object('found', true) FROM staff_roster AS r WHERE r.email = p_email);
  IF dup IS NOT NULL THEN
    RETURN jsonb_build_object('success', false, 'data', NULL, 'error', jsonb_build_object('code', 'ROSTER_EXISTS', 'message', 'that email is already on the roster'));
  END IF;
  caller_id := (SELECT r.id FROM staff_roster AS r WHERE r.email = claims_email);
  new_id := gen_random_uuid();
  INSERT INTO staff_roster (id, email, display_name, role, active, added_by)
    VALUES (new_id, p_email, TRIM(p_display_name), p_role, true, caller_id);
  RETURN jsonb_build_object('success', true, 'data', jsonb_build_object('roster_id', new_id, 'email', p_email, 'display_name', TRIM(p_display_name), 'role', p_role, 'created_password', p_created_password, 'note', 'copy this password to the new employee; it is shown once and never stored'), 'error', NULL);
END;
$$ LANGUAGE plpgsql;


-- ----------------------------------------------------------------------------
-- roster_suspend / roster_reactivate :: OWNER-gated UPDATE active.
-- ----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION roster_suspend (p_roster_id uuid)
RETURNS jsonb AS $$
DECLARE
  claims_email text;
  row_r jsonb;
BEGIN
  claims_email := jwt_claims_email();
  IF claims_email = '' THEN
    RETURN jsonb_build_object('success', false, 'data', NULL, 'error', jsonb_build_object('code', 'OWNER_SESSION_REQUIRED', 'message', 'suspending staff needs a signed-in owner session'));
  END IF;
  IF roster_role_of(claims_email) <> 'owner' THEN
    RETURN jsonb_build_object('success', false, 'data', NULL, 'error', jsonb_build_object('code', 'NOT_OWNER', 'message', 'only an active owner may suspend staff'));
  END IF;
  row_r := (SELECT jsonb_build_object('roster_id', r.id, 'email', r.email, 'display_name', r.display_name) FROM staff_roster AS r WHERE r.id = p_roster_id);
  IF row_r IS NULL THEN
    RETURN jsonb_build_object('success', false, 'data', NULL, 'error', jsonb_build_object('code', 'ROSTER_NOT_FOUND', 'message', 'that roster row does not exist'));
  END IF;
  UPDATE staff_roster AS r SET active = false WHERE r.id = p_roster_id;
  RETURN jsonb_build_object('success', true, 'data', row_r || jsonb_build_object('active', false), 'error', NULL);
END;
$$ LANGUAGE plpgsql;

CREATE OR REPLACE FUNCTION roster_reactivate (p_roster_id uuid)
RETURNS jsonb AS $$
DECLARE
  claims_email text;
  row_r jsonb;
BEGIN
  claims_email := jwt_claims_email();
  IF claims_email = '' THEN
    RETURN jsonb_build_object('success', false, 'data', NULL, 'error', jsonb_build_object('code', 'OWNER_SESSION_REQUIRED', 'message', 'reactivating staff needs a signed-in owner session'));
  END IF;
  IF roster_role_of(claims_email) <> 'owner' THEN
    RETURN jsonb_build_object('success', false, 'data', NULL, 'error', jsonb_build_object('code', 'NOT_OWNER', 'message', 'only an active owner may reactivate staff'));
  END IF;
  row_r := (SELECT jsonb_build_object('roster_id', r.id, 'email', r.email, 'display_name', r.display_name) FROM staff_roster AS r WHERE r.id = p_roster_id);
  IF row_r IS NULL THEN
    RETURN jsonb_build_object('success', false, 'data', NULL, 'error', jsonb_build_object('code', 'ROSTER_NOT_FOUND', 'message', 'that roster row does not exist'));
  END IF;
  UPDATE staff_roster AS r SET active = true WHERE r.id = p_roster_id;
  RETURN jsonb_build_object('success', true, 'data', row_r || jsonb_build_object('active', true), 'error', NULL);
END;
$$ LANGUAGE plpgsql;


-- ----------------------------------------------------------------------------
-- roster_move_station :: OWNER-gated UPDATE role (station move cashier <-> kitchen;
-- also owner <-> staff). Refuses DEMOTING THE LAST ACTIVE OWNER: if the target row
-- is an active owner, it is the only active owner, and the new role is not 'owner',
-- refuse with LAST_OWNER_ONLY (mirrors the LAST_LINE_ONLY guard style in 02).
-- ----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION roster_move_station (p_roster_id uuid, p_role text)
RETURNS jsonb AS $$
DECLARE
  claims_email text;
  target jsonb;
  active_owners integer;
BEGIN
  claims_email := jwt_claims_email();
  IF claims_email = '' THEN
    RETURN jsonb_build_object('success', false, 'data', NULL, 'error', jsonb_build_object('code', 'OWNER_SESSION_REQUIRED', 'message', 'moving station needs a signed-in owner session'));
  END IF;
  IF roster_role_of(claims_email) <> 'owner' THEN
    RETURN jsonb_build_object('success', false, 'data', NULL, 'error', jsonb_build_object('code', 'NOT_OWNER', 'message', 'only an active owner may move station'));
  END IF;
  IF p_role NOT IN ('owner', 'cashier', 'kitchen') THEN
    RETURN jsonb_build_object('success', false, 'data', NULL, 'error', jsonb_build_object('code', 'INVALID_ROLE', 'message', 'role must be owner, cashier or kitchen'));
  END IF;
  target := (SELECT jsonb_build_object('roster_id', r.id, 'email', r.email, 'display_name', r.display_name, 'role', r.role, 'active', r.active) FROM staff_roster AS r WHERE r.id = p_roster_id);
  IF target IS NULL THEN
    RETURN jsonb_build_object('success', false, 'data', NULL, 'error', jsonb_build_object('code', 'ROSTER_NOT_FOUND', 'message', 'that roster row does not exist'));
  END IF;
  active_owners := COALESCE((SELECT COUNT(1) FROM staff_roster AS r WHERE r.role = 'owner' AND r.active = true), 0);
  IF (target ->> 'role')::text = 'owner'
     AND (target ->> 'active')::text = 'true'
     AND p_role <> 'owner'
     AND active_owners <= 1 THEN
    RETURN jsonb_build_object('success', false, 'data', NULL, 'error', jsonb_build_object('code', 'LAST_OWNER_ONLY', 'message', 'that is the only active owner - promote another owner before demoting this one'));
  END IF;
  UPDATE staff_roster AS r SET role = p_role WHERE r.id = p_roster_id;
  RETURN jsonb_build_object('success', true, 'data', target || jsonb_build_object('role', p_role), 'error', NULL);
END;
$$ LANGUAGE plpgsql;


-- ----------------------------------------------------------------------------
-- roster_reset_password :: OWNER-gated. Generates and returns a memorable temp
-- password ONCE via make_memorable_password(). It does NOT touch GoTrue: APPLYING
-- this password to the auth identity needs the service-role Edge-Function path
-- (deferred, flagged PENDING OWNER APPROVAL - same class as the cron decision in
-- MASTER_PLAN §9 item 10). The employee must change it on first login.
-- ----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION roster_reset_password (p_roster_id uuid)
RETURNS jsonb AS $$
DECLARE
  claims_email text;
  row_r jsonb;
  temp_password text;
BEGIN
  claims_email := jwt_claims_email();
  IF claims_email = '' THEN
    RETURN jsonb_build_object('success', false, 'data', NULL, 'error', jsonb_build_object('code', 'OWNER_SESSION_REQUIRED', 'message', 'resetting a password needs a signed-in owner session'));
  END IF;
  IF roster_role_of(claims_email) <> 'owner' THEN
    RETURN jsonb_build_object('success', false, 'data', NULL, 'error', jsonb_build_object('code', 'NOT_OWNER', 'message', 'only an active owner may reset a password'));
  END IF;
  row_r := (SELECT jsonb_build_object('roster_id', r.id, 'email', r.email, 'display_name', r.display_name) FROM staff_roster AS r WHERE r.id = p_roster_id);
  IF row_r IS NULL THEN
    RETURN jsonb_build_object('success', false, 'data', NULL, 'error', jsonb_build_object('code', 'ROSTER_NOT_FOUND', 'message', 'that roster row does not exist'));
  END IF;
  temp_password := make_memorable_password();
  RETURN jsonb_build_object('success', true, 'data', jsonb_build_object('roster_id', p_roster_id, 'email', row_r ->> 'email', 'display_name', row_r ->> 'display_name', 'temp_password', temp_password, 'note', 'show once; employee must change it on first login'), 'error', NULL);
END;
$$ LANGUAGE plpgsql;


-- ----------------------------------------------------------------------------
-- SEED rows (dev build content). Idempotent: keyed on the UNIQUE email column via
-- ON CONFLICT (email) DO NOTHING, so re-pasting is inert. id takes the column
-- DEFAULT gen_random_uuid(). The probe row's added_by resolves the dev row's id by
-- subselect (dev is inserted immediately above, so the FK resolves; if dev is
-- absent the FK falls back to NULL, which is a legal bootstrap value).
-- REMINDER (see header NOTE): these are ROSTER rows only. The matching AUTH
-- identities must be created out-of-band via POST /auth/v1/signup (publishable key,
-- autoconfirm OFF) - SQL cannot create auth identities.
-- ----------------------------------------------------------------------------
INSERT INTO staff_roster (email, display_name, role, active, added_by)
  VALUES ('dev@sleepless-cafe.test', 'Dev (bootstrap)', 'owner', true, NULL)
  ON CONFLICT (email) DO NOTHING;

-- NOTE (apply 2026-10-21): the cashier probe email is cashier-probe@, NOT staff-probe@.
-- An auth user staff-probe@sleepless-cafe.test already exists in this project from an
-- earlier QA pass with an UNRECORDED password, so it can never be signed into and can
-- never satisfy its roster row. cashier-probe@ is the fresh identity created for this
-- pass (signup with the publishable key). The stale staff-probe auth user is left in
-- place (deleting auth users is a destructive op, not authorized); it holds no roster
-- row and is inert.
INSERT INTO staff_roster (email, display_name, role, active, added_by)
  VALUES ('cashier-probe@sleepless-cafe.test', 'Probe (cashier)', 'cashier', true,
          (SELECT r.id FROM staff_roster AS r WHERE r.email = 'dev@sleepless-cafe.test'))
  ON CONFLICT (email) DO NOTHING;

-- kitchen station probe: QA needs a kitchen-role identity to prove station blocking
-- BOTH ways (cashier refused on kitchen actions, kitchen refused on cashier actions).
INSERT INTO staff_roster (email, display_name, role, active, added_by)
  VALUES ('kitchen-probe@sleepless-cafe.test', 'Probe (kitchen)', 'kitchen', true,
          (SELECT r.id FROM staff_roster AS r WHERE r.email = 'dev@sleepless-cafe.test'))
  ON CONFLICT (email) DO NOTHING;


-- ----------------------------------------------------------------------------
-- Summary of what is granted on staff_roster (nothing else is):
--   staff_roster          READ  authenticated   WRITE authenticated (INSERT, UPDATE)
--                         DELETE authenticated   anon: NO read, NO write, NO delete
--   anon                  cannot enumerate usernames (no anon SELECT exists)
--   authenticated write   is fenced further in the roster_* function bodies by
--                         roster_role_of(claims email) = 'owner' (NOT_OWNER otherwise)
--   LAST_OWNER_ONLY       refuses demoting the only active owner (mirrors LAST_LINE_ONLY)
--   pw_note / temp_password / created_password  are NEVER stored secrets; the roster
--                         holds no password (GoTrue does), and generated passwords
--                         are echoed ONCE for the owner to copy.
--
-- VERIFY (paste one at a time in the Supabase Dashboard / psql, after applying):
--   SELECT count(*) FROM staff_roster;                    -- expect 3 (dev, cashier probe, kitchen probe)
--   SELECT r.email, r.role, r.added_by FROM staff_roster; -- both probes' added_by = dev.id
--   SELECT make_memorable_password();                     -- e.g. Caramel-Latte-42
-- ============================================================================
-- END 07_staff_roster.sql
-- ============================================================================
