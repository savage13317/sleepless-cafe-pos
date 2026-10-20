/* ===========================================================================
   assets/api.js — browser transport for the SQL state machine (sql/02_functions.sql).
   Dependency-free: talks to the Supabase REST surface with fetch, no supabase-js
   here (that CDN ESM is only loaded in realtime.js, Phase 4).

   THE ONE ENVELOPE (SOP standard) — every exported function returns exactly
   { success:boolean, data:any, error:null|{code:string,message:string} }
   and NEVER throws. Pages map error.code to their own copy; they never render
   a stack trace.
   =========================================================================== */

import { CONFIG } from './config.js';

const NET_MSG = "We can't reach the cafe right now. Check your connection and try again.";

const HEADERS = {
  apikey: CONFIG.sbKey,
  Authorization: `Bearer ${CONFIG.sbKey}`,
  'Content-Type': 'application/json',
  Accept: 'application/json',
};
let SESSION = null;               // staff bearer or null (anon)

/* --- staff session door ---------------------------------------------------
   RLS (sql/03_rls.sql) denies anon READ of orders / order_items on purpose, so
   a customer can never see another customer's claim. The cashier, kitchen and
   owner boards therefore sign in through Supabase Auth and hand the resulting
   access token here. The publishable key stays in the apikey slot; only the
   Authorization bearer changes. No session = anon = menu reads only.
   setSessionToken(null) returns to the anonymous (customer) transport.        */
export function setSessionToken(token) {
  SESSION = token || null;
  HEADERS.Authorization = `Bearer ${SESSION || CONFIG.sbKey}`;
}
export function clearSessionToken() { setSessionToken(null); }
/* the current staff bearer or null — realtime.js needs it, because Realtime
   events are RLS-filtered for the subscriber and anon cannot read orders. */
export function getSessionToken() { return SESSION; }

const ok = (data) => ({ success: true, data, error: null });
const err = (code, message) => ({ success: false, data: null, error: { code, message } });

/* --- currency + time formatters (shared by all four pages) ---------------- */

/* 'en-US' gives the thousands separator; the ₱ symbol is prefixed by hand so no
   locale can ever emit a second one. */
const _peso = new Intl.NumberFormat('en-US', { minimumFractionDigits: 2, maximumFractionDigits: 2 });
export const fmtPeso = (v) => '\u20B1' + _peso.format(Number(v) || 0); // ₱1,250.00

export function fmtTime(iso) {
  const d = new Date(iso);
  const p = (n) => String(n).padStart(2, '0');
  return isNaN(d) ? '--:--' : `${p(d.getHours())}:${p(d.getMinutes())}`; // local, 24h
}

export function fmtCountdown(seconds) {
  const s = Math.max(0, Math.floor(Number(seconds) || 0));
  const p = (n) => String(n).padStart(2, '0');
  const h = Math.floor(s / 3600);
  return h > 0
    ? `${h}:${p(Math.floor((s % 3600) / 60))}:${p(s % 60)}` // h:mm:ss past an hour
    : `${p(Math.floor(s / 60))}:${p(s % 60)}`;             // mm:ss
}

/* --- core RPC: POST /rest/v1/rpc/<fn>, body = named args ----------------- */
/* FIX: this project's API gateway exposes SQL functions ONLY under the /rpc/
   prefix. Bare /rest/v1/<name> is resolved against tables/views and answers
   PGRST205 "Could not find the table 'public.<fn>'" even though PostgREST's
   schema cache reports the RPCs as loaded. Tables (getRows, below) keep the
   bare form - those DO resolve.                                           */
/* Named-arg keys match the SQL parameter names exactly:
   customer_name, items, claim_code, order_id.                        */

async function callSql(fn, args) {
  let res;
  try {
    res = await fetch(`${CONFIG.sbUrl}/rest/v1/rpc/${fn}`, {
      method: 'POST',
      headers: HEADERS,
      body: JSON.stringify(args || {}),
    });
  } catch {
    return err('NETWORK', NET_MSG);
  }
  if (!res.ok) {
    let msg = null;
    try {
      const b = await res.json();
      if (typeof b?.message === 'string') msg = b.message;
      else if (typeof b?.error === 'string') msg = b.error;
      else if (b?.error && typeof b.error.message === 'string') msg = b.error.message;
    } catch { /* body unreadable, fall through to the generic copy */ }
    return err('HTTP', msg || `the cafe server replied ${res.status}`);
  }
  try {
    const body = await res.json(); // the jsonb envelope IS the body
    return { success: !!body.success, data: body.data ?? null, error: body.error ?? null };
  } catch {
    return err('HTTP', 'the cafe server sent something we could not read');
  }
}

/* --- one thin wrapper per SQL function, envelope returned unchanged ------ */

/* Supabase Auth password grant (GoTrue). Returns the envelope with
   data = { access_token, user: { email, user_metadata } } or an error
   envelope. The access_token is what setSessionToken() takes. The
   service-role key is never involved - the publishable key authorizes
   the call, the user's own credentials prove the session. */
export async function signIn(email, password) {
  let res;
  try {
    res = await fetch(`${CONFIG.sbUrl}/auth/v1/token?grant_type=password`, {
      method: 'POST',
      headers: { apikey: CONFIG.sbKey, 'Content-Type': 'application/json' },
      body: JSON.stringify({ email, password }),
    });
  } catch {
    return err('NETWORK', NET_MSG);
  }
  if (!res.ok) {
    let msg = 'Those credentials were not accepted.';
    try { const b = await res.json(); if (b?.msg_desc || b?.error_description) msg = b.msg_desc || b.error_description; } catch {}
    return err('AUTH', msg);
  }
  try { return ok(await res.json()); } catch { return err('AUTH', 'the auth response could not be read'); }
}

export async function createOrder(customerName, items) {
  return await callSql('create_order', { customer_name: customerName, items: items });
}
export async function getOrderByCode(claimCode) {
  return await callSql('get_order_by_code', { claim_code: claimCode });
}
export async function listActivePending() {
  return await callSql('list_active_pending', {});
}
export async function confirmPayment(claimCode) {
  return await callSql('confirm_payment', { claim_code: claimCode });
}
export async function kitchenQueue() {
  return await callSql('kitchen_queue', {});
}
export async function markServed(orderId) {
  return await callSql('mark_served', { order_id: orderId });
}
export async function setPreparing(orderId) {
  return await callSql('set_preparing', { order_id: orderId });
}
export async function voidOrder(orderId) {
  return await callSql('void_order', { order_id: orderId });
}

/* --- catalogue reads: plain GETs, wrapped in the same envelope ----------- */

async function getRows(path) {
  let res;
  try {
    res = await fetch(`${CONFIG.sbUrl}/rest/v1/${path}`, { headers: HEADERS });
  } catch {
    return err('NETWORK', NET_MSG);
  }
  if (!res.ok) return err('HTTP', `the cafe menu could not be loaded (${res.status})`);
  try {
    return ok(await res.json());
  } catch {
    return err('HTTP', 'the cafe menu came back unreadable');
  }
}

export async function getMenu() {
  return await getRows(
    'menu_items?select=id,category_id,name,description,image_url,sizes_and_prices,is_available' +
    '&order=category_id.asc,name.asc'
  );
}

export async function getCategories() {
  return await getRows('categories?select=id,name,display_order&order=display_order.asc');
}

/* --- owner surface (Phase 5): same envelope, session bearer required ------
   The SQL layer (sql/02_functions.sql) gates these on the caller's JWT claims,
   so without signIn()+setSessionToken() first every one of these returns the
   OWNER_SESSION_REQUIRED error envelope. Param names match the SQL exactly. */
export async function salesSummary(from, to, grain) {
  return await callSql('sales_summary', { from_time: from, to_time: to, grain });
}
export async function turnoverStats(from, to) {
  return await callSql('turnover_stats', { from_time: from, to_time: to });
}
export async function createCategory(name, displayOrder) {
  return await callSql('create_category', { name, display_order: displayOrder });
}
export async function reorderCategories(newOrder) {
  return await callSql('reorder_categories', { new_order: newOrder });
}
export async function deleteCategory(categoryId, fallbackCategoryId) {
  // SQL parameters are p_-prefixed (delete_category used to raise 42702 "column reference
  // category_id is ambiguous" - see sql/02_functions.sql). Keys here must match the parameter
  // names exactly, or PostgREST answers PGRST202 "required parameter missing".
  return await callSql('delete_category', { p_category_id: categoryId, p_fallback_category_id: fallbackCategoryId });
}
export async function createMenuItem(categoryId, name, description, imageUrl, sizesAndPrices, isAvailable) {
  return await callSql('create_menu_item', {
    category_id: categoryId, name, description, image_url: imageUrl,
    sizes_and_prices: sizesAndPrices, is_available: isAvailable,
  });
}
export async function updateMenuItem(menuItemId, name, description, imageUrl, sizesAndPrices, isAvailable) {
  // Keys must match the SQL parameter names, which are p_-prefixed (see sql/02_functions.sql
  // - bare `name`/`image_url`/... collide with menu_items columns: 42702 at CALL time).
  return await callSql('update_menu_item', {
    p_menu_item_id: menuItemId, p_name: name, p_description: description,
    p_image_url: imageUrl, p_sizes_and_prices: sizesAndPrices, p_is_available: isAvailable,
  });
}

/* Storage upload: PUT into the public `menu-images` bucket (owner creates that
   bucket once in the Dashboard; RLS lets authenticated users write, anon cannot).
   Returns the public URL for menu_items.image_url. Slug-safe object names only. */
export async function uploadImage(fileName, bytes, contentType) {
  const slug = String(fileName).toLowerCase().replace(/[^a-z0-9._-]+/g, '-').slice(0, 80) || 'photo';
  try {
    const res = await fetch(`${CONFIG.sbUrl}/storage/v1/object/menu-images/${slug}`, {
      method: 'POST',
      headers: { ...HEADERS, 'Content-Type': contentType, 'x-upsert': 'true' },
      body: bytes,
    });
    if (!res.ok) return err('HTTP', 'the photo could not be uploaded.');
    return ok(`${CONFIG.sbUrl}/storage/v1/object/public/menu-images/${slug}`);
  } catch {
    return err('NETWORK', NET_MSG);
  }
}

/* ===========================================================================
   Error codes the SQL layer (sql/02_functions.sql) can emit, plus the two
   transport codes added here. Pages map each code to their own copy string
   and never render a stack trace or the raw code to the customer.

     INVALID_CUSTOMER_NAME  create_order: name blank or over 100 chars
     INVALID_ITEMS          create_order: items not a non-empty array of objects
     MENU_ITEM_UNAVAILABLE  create_order: item not on the menu right now
     INVALID_SIZE           create_order: size not offered for that item
     CODE_EXHAUSTED         create_order: no free 5-digit claim code left, retry
     ORDER_NOT_FOUND        get_order_by_code: wrong code, or claim already gone
     ORDER_EXPIRED          confirm_payment: claim ran out of time
     NOT_SERVABLE           mark_served: order not waiting in the kitchen
     NOT_PREPARABLE         set_preparing: order not waiting to be cooked
     NOT_VOIDABLE           void_order: not an open unpaid claim
     OWNER_SESSION_REQUIRED owner RPCs (Phase 5): no signed-in JWT — every one of
                            sales_summary / turnover_stats / create_category /
                            reorder_categories / delete_category / create_menu_item /
                            update_menu_item returns this when called anon
     INVALID_GRAIN          sales_summary: grain not daily/monthly/yearly
     CATEGORY_NOT_FOUND     create_category target / delete_category: gone already
     INVALID_CATEGORY_NAME  create_category: blank or over 80 chars
     INVALID_ORDER          reorder_categories: not an array of category uuids
     INVALID_FALLBACK       delete_category: fallback missing, or same as the victim
     INVALID_ITEM_NAME      create/update_menu_item: name supplied but blank/over 120
     INVALID_SIZES          create/update_menu_item: sizes_and_prices shape rejected
     MENU_ITEM_NOT_FOUND    update_menu_item: that item is no longer on the menu
     NETWORK                fetch failed (dns / offline / CORS) — added here
     HTTP                   non-2xx from the REST surface — added here
   =========================================================================== */
