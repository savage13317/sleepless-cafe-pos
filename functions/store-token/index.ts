// ============================================================================
// functions/store-token/index.ts :: PHASE 9h+i — STORE-BEARING ANON TOKEN
//
// WHY THIS EXISTS
// ----------------------------------------------------------------------------
// Anon customers carry NO JWT, so jwt_store_id() returns NULL and the
// store-scoped RLS policy (sql/08_multitenant.sql) blocks every anon INSERT
// on orders:
//   orders_customer_insert_store  →  WITH CHECK ( jwt_store_id() IS NOT NULL … )
// Without a store-bearing token, create_order COALESCEs to the legacy flagship
// UUID and every customer order lands in flagship regardless of ?store=.
//
// This Edge Function mints a 5-minute HS256 JWT {role:'anon', sid:<uuid>, exp}
// for the branch identified by the slug query parameter. The caller (menu.html)
// attaches it as Authorization: Bearer <token> before createOrder(), so
// jwt_store_id() resolves to the correct store and the RLS policy admits the
// INSERT.
//
// SECRETS: SL_JWT_SECRET (the project JWT signing secret) lives ONLY in
// Edge-Function env (supabase secrets set, server-side). It is never in the
// repo, never in a browser. The publishable key is public by design.
//
// USAGE (from menu.html client):
//   POST {sbUrl}/functions/v1/store-token?slug=marcelas
//   Authorization: Bearer <publishable-key>
//   → { token: "eyJ...", storeId: "0000...0002" }
//
// The token is short-lived (5 min) to limit the window if a JWT is ever
// intercepted. A stale token is rejected by jwt_store_id() → NULL (exp passed).
// ============================================================================

// ---- 0. Read secrets from Edge-Function env only --------------------------
const sbUrl = Deno.env.get("SL_SB_URL");
const pubKey = Deno.env.get("SL_PUBLISHABLE_KEY");
const jwtSecret = Deno.env.get("SL_JWT_SECRET");

const missing =
  (!sbUrl ? "SL_SB_URL " : "") +
  (!pubKey ? "SL_PUBLISHABLE_KEY " : "") +
  (!jwtSecret ? "SL_JWT_SECRET" : "");
if (missing.trim().length > 0) {
  return new Response(
    JSON.stringify({
      success: false,
      data: null,
      error: { code: "ENV_MISSING", message: missing.trim() },
    }),
    { status: 500, headers: { "Content-Type": "application/json" } }
  );
}

// ---- 1. Helpers -----------------------------------------------------------
function base64urlEncode(data: Uint8Array): string {
  return btoa(String.fromCharCode(...data))
    .replace(/\+/g, "-")
    .replace(/\//g, "_")
    .replace(/=+$/, "");
}

function hexToUint8Array(hex: string): Uint8Array {
  const bytes = new Uint8Array(hex.length / 2);
  for (let i = 0; i < hex.length; i += 2) {
    bytes[i / 2] = parseInt(hex.slice(i, i + 2), 16);
  }
  return bytes;
}

async function signHmacSha256(key: Uint8Array, message: string): Promise<Uint8Array> {
  const cryptoKey = await crypto.subtle.importKey(
    "raw",
    key,
    { name: "HMAC", hash: "SHA-256" },
    false,
    ["sign"]
  );
  const signature = await crypto.subtle.sign("HMAC", cryptoKey, new TextEncoder().encode(message));
  return new Uint8Array(signature);
}

function createJwt(payload: Record<string, unknown>, secret: string): string {
  const header = base64urlEncode(new TextEncoder().encode(JSON.stringify({ alg: "HS256", typ: "JWT" })));
  const body = base64urlEncode(new TextEncoder().encode(JSON.stringify(payload)));
  const signingInput = `${header}.${body}`;
  const signature = base64urlEncode(
    // deno-lint-ignore no-explicit-any
    signHmacSha256(hexToUint8Array(secret), signingInput) as any
  );
  return `${signingInput}.${signature}`;
}

// ---- 2. Parse request -----------------------------------------------------
const url = new URL(Deno.requestHttp.server.url);
const slug = url.searchParams.get("slug");

if (!slug || typeof slug !== "string") {
  return new Response(
    JSON.stringify({
      success: false,
      data: null,
      error: { code: "MISSING_SLUG", message: "query param ?slug=<store-slug> is required" },
    }),
    { status: 400, headers: { "Content-Type": "application/json" } }
  );
}

// ---- 3. Look up store by slug ---------------------------------------------
const storeQuery = `${sbUrl}/rest/v1/stores?slug=eq.${encodeURIComponent(slug)}&select=id,is_open,tier,name`;
const storeRes = await Deno.fetch(storeQuery, {
  method: "GET",
  headers: {
    apikey: pubKey,
    Authorization: `Bearer ${pubKey}`,
    "Content-Type": "application/json",
  },
});

if (!storeRes.ok) {
  return new Response(
    JSON.stringify({
      success: false,
      data: null,
      error: { code: "STORE_LOOKUP_FAILED", message: "could not look up store" },
    }),
    { status: 502, headers: { "Content-Type": "application/json" } }
  );
}

const storeBody = (await storeRes.json()) as Array<{ id: string; is_open: boolean; tier: string; name: string }>;

if (!storeBody.length) {
  return new Response(
    JSON.stringify({
      success: false,
      data: null,
      error: { code: "STORE_NOT_FOUND", message: `no store with slug '${slug}'` },
    }),
    { status: 404, headers: { "Content-Type": "application/json" } }
  );
}

const store = storeBody[0];

if (!store.is_open) {
  return new Response(
    JSON.stringify({
      success: false,
      data: null,
      error: { code: "STORE_CLOSED", message: `branch '${slug}' is currently closed` },
    }),
    { status: 403, headers: { "Content-Type": "application/json" } }
  );
}

// ---- 4. Mint JWT ----------------------------------------------------------
const now = Math.floor(Date.now() / 1000);
const payload = {
  role: "anon" as const,
  sid: store.id,
  exp: now + 300, // 5 minutes
};

const token = createJwt(payload, jwtSecret);

// ---- 5. Return ------------------------------------------------------------
return new Response(
  JSON.stringify({
    success: true,
    data: { token, storeId: store.id, slug: slug, tier: store.tier, name: store.name },
    error: null,
  }),
  { status: 200, headers: { "Content-Type": "application/json" } }
);
