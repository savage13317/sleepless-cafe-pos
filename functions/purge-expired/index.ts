// ============================================================================
// functions/purge-expired/index.ts :: PHASE 8 (Gate B) - SERVER-SIDE TTL AUTHORITY
// Deployed via the supabase CLI convention: functions/purge-expired/index.ts
// (a Deno Deploy Edge Function; the entry point is the global Deno.serve, and
//  this file is dependency-free - Deno.env + Deno.fetch only, no imports).
//
// WHY THIS EXISTS AT ALL
// ----------------------------------------------------------------------------
// The claim window is 30 minutes and the DB owns it (sql/01_schema.sql:74,
// expires_at DEFAULT now() + interval '30 minutes'; MASTER_PLAN decision 8).
// Expiry is enforced by purge_expired_orders(), the ONLY DELETE path on orders
// (sql/02_functions.sql:232 CREATE OR REPLACE FUNCTION purge_expired_orders()
//  RETURNS jsonb; body :239 DELETE FROM orders WHERE status='pending_payment'
//  AND expires_at < now(); it CASCADEs the order_items children and returns
//  {success:true,data:{removed:<int>},error:null}).
//
// Expiry is TWO-PRONGED (MASTER_PLAN §1 note 2 / §5 / Gate B):
//   (a) LAZY, CLIENT-SIDE backstop - list_active_pending() and kitchen_queue()
//       each PERFORM purge_expired_orders() before they read (sql/02:262 and
//       :320), and cashier.html sweeps before it renders. That self-healing
//       sweep stays UNCHANGED: it is cheap and keeps a board correct the moment
//       any staff page opens. It is NOT the authority - it only fires when a
//       staff page happens to be open, so a claim can sit un-swept overnight.
//   (b) SERVER-SIDE AUTHORITY - THIS function. A Supabase Cron job (tools/cron/
//       purge-expired.json, every 15 min) POSTs to this Edge Function, so a
//       claim is physically deleted ON SCHEDULE EVEN WHEN NO STAFF PAGE IS OPEN.
//       GitHub Pages had no cron (Phase A); Phase B on Vercel adds the scheduled
//       server-side sweep Gate B requires ("Supabase Cron -> purge_expired_orders()
//       scheduled, server-side TTL, not client-only").
//
// SECURITY CONTRACT - read before editing, this is the whole point of the file
// ----------------------------------------------------------------------------
// purge_expired_orders() performs a DELETE, and RLS gates DELETE on orders to a
// real session only: sql/03_rls.sql:141 CREATE POLICY orders_staff_delete ON
// orders FOR DELETE TO authenticated USING ( status = 'pending_payment' ). The
// TO clause names `authenticated`, so the anon key and the service_role key are
// NOT permitted to DELETE - a service-role sweep is DENIED BY DESIGN. The only
// principal that can sweep is a genuine staff session carrying a real user JWT
// whose role is `authenticated`. That is exactly the boundary Gate A proved
// (anon/service cannot mutate orders; only a signed-in staff session can).
//
// So this function does NOT use the service-role key anywhere. It MINTS a real
// user JWT the same way the staff pages do (password grant, HANDOFF §1.5):
//   POST {sbUrl}/auth/v1/token?grant_type=password   (apikey = PUBLISHABLE key)
//   body {"email": <SL_STAFF_EMAIL>, "password": <SL_STAFF_PASSWORD>}
//   -> access_token is a real user JWT (role authenticated, email_confirmed).
// Then it calls the RPC with that JWT as the bearer:
//   POST {sbUrl}/rest/v1/rpc/purge_expired_orders    (Authorization: Bearer <jwt>)
// The /rpc/ path prefix is MANDATORY (HANDOFF §1.1 - bare /rest/v1/<fn> 404s
// PGRST205 "Could not find the table" on this project's gateway). No service-role
// key appears anywhere in this file.
//
// SECRETS: SL_STAFF_EMAIL / SL_STAFF_PASSWORD (plus the project URL and the
// publishable key) live ONLY in Edge-Function env (supabase secrets set, server-
// side). They are never in the repo, never in a browser, and the JWT/password are
// NEVER logged. The publishable key is public by design (it ships in a browser);
// the service-role/secret key is nowhere in this repo (HANDOFF §2).
//
// FAIL-LOUD: a missing env var or a failed auth/RPC call returns the repo's JSON
// error envelope {success:false,data:null,error:{code:...}} with HTTP 500. The
// cron treats a non-2xx as a visible failure; this NEVER silently reports success.
// On success it returns {success:true,data:{purged:<int>}} - the envelope standard
// every call site in the repo obeys (AGENTS.md, Error Handling & API Standards).
// ============================================================================

Deno.serve(async (_req) => {
  // ---- 0. Read secrets from Edge-Function env only (never from the request) --
  const sbUrl = Deno.env.get('SL_SB_URL');
  const pubKey = Deno.env.get('SL_PUBLISHABLE_KEY');
  const staffEmail = Deno.env.get('SL_STAFF_EMAIL');
  const staffPassword = Deno.env.get('SL_STAFF_PASSWORD');

  // Fail-loud on missing env. Report WHICH names are absent (names only, never
  // values) so the director can fix the secret without this ever echoing a
  // password or a JWT.
  const missing =
    (!sbUrl ? 'SL_SB_URL ' : '') +
    (!pubKey ? 'SL_PUBLISHABLE_KEY ' : '') +
    (!staffEmail ? 'SL_STAFF_EMAIL ' : '') +
    (!staffPassword ? 'SL_STAFF_PASSWORD' : '');
  if (missing.trim().length > 0) {
    return new Response(
      JSON.stringify({
        success: false,
        data: null,
        error: { code: 'ENV_MISSING', msg: missing.trim() },
      }),
      { status: 500, headers: { 'Content-Type': 'application/json' } },
    );
  }

  // ---- 1. Mint a REAL user JWT via the public password grant (no service key) -
  // Mirrors HANDOFF §1.5: password grant works once the user exists; the
  // publishable key is the apikey, the staff email/password come from env.
  let jwt: string | null = null;
  try {
    const authRes = await Deno.fetch(
      `${sbUrl}/auth/v1/token?grant_type=password`,
      {
        method: 'POST',
        headers: { 'Content-Type': 'application/json', apikey: pubKey },
        body: JSON.stringify({ email: staffEmail, password: staffPassword }),
      },
    );
    if (authRes.status === 200) {
      const authJson = JSON.parse(await authRes.text());
      jwt = authJson.access_token || null;
    }
  } catch {
    jwt = null; // swallow the throw, but do NOT swallow the failure - jwt stays null
  }
  if (jwt === null) {
    // Auth failure is loud: the sweep must not run on a bad/absent session, and
    // we never print the token or the password that caused it.
    return new Response(
      JSON.stringify({
        success: false,
        data: null,
        error: { code: 'AUTH_FAILED', msg: 'password grant did not return an access_token' },
      }),
      { status: 500, headers: { 'Content-Type': 'application/json' } },
    );
  }

  // ---- 2. Call the RPC with the real staff JWT as bearer ---------------------
  // RLS orders_staff_delete (sql/03:141, TO authenticated) admits this bearer and
  // would DENY an anon/service-role key here, which is the point of the contract.
  try {
    const rpcRes = await Deno.fetch(
      `${sbUrl}/rest/v1/rpc/purge_expired_orders`,
      {
        method: 'POST',
        headers: {
          'Content-Type': 'application/json',
          apikey: pubKey,
          Authorization: `Bearer ${jwt}`,
        },
        body: '{}', // no args; the fn takes none
      },
    );
    const raw = await rpcRes.text();
    if (rpcRes.status !== 200) {
      return new Response(
        JSON.stringify({
          success: false,
          data: null,
          error: { code: 'RPC_FAILED', msg: `purge_expired_orders HTTP ${rpcRes.status}` },
        }),
        { status: 500, headers: { 'Content-Type': 'application/json' } },
      );
    }
    // The SQL fn returns its OWN envelope {success,data:{removed},error}. Unwrap
    // the count and re-wrap in the repo envelope keyed `purged` (the fn's key is
    // `removed`; the Edge-Function contract the cron/director expects is `purged`).
    const env = JSON.parse(raw);
    const purged = env?.data?.removed ?? 0;
    return new Response(
      JSON.stringify({ success: true, data: { purged: purged }, error: null }),
      { status: 200, headers: { 'Content-Type': 'application/json' } },
    );
  } catch {
    // A transport/parse throw is a failure, not a silent zero-purge success.
    return new Response(
      JSON.stringify({
        success: false,
        data: null,
        error: { code: 'RPC_FAILED', msg: 'purge_expired_orders call threw' },
      }),
      { status: 500, headers: { 'Content-Type': 'application/json' } },
    );
  }
});
