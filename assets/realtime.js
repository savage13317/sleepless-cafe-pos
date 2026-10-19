/* ===========================================================================
   assets/realtime.js — Phase 4 realtime transport for the KDS board.

   EXACT WIRE (matches sql/04_realtime.sql, copy verbatim):
     wss://<sbUrl>/websocket?apikey=<publishable>
   Authorize with the same PUBLISHABLE key api.js already uses; the service-role
   key is never involved.

   FILTER STRINGS (the `ph` param the wire encodes):
     eq:orders.INSERT      a new paid order lands on the board
     eq:orders.UPDATE      paid -> preparing -> served status moves
   supabase-js v4 equivalent of those filters:
     .on('insert', cb)  .on('update', cb)   on table 'orders'
   The dynamic import below is therefore pinned to @supabase/supabase-js@4:
   client.socket([...]) / socket.on / ensureStarted / client.close are the v4
   surface, and v2 has no client.socket at all (it routed realtime through the
   separate @supabase/socket.io package), so importing @2 could never connect.

   DELETE IS NOT SUBSCRIBED HERE. A paid order is never deleted — it is UPDATEd
   to 'served' and simply stops being returned by kitchen_queue(), so the card
   leaving the view is a repaint, not a delete event. (The cashier socket is the
   one that needs eq:orders.DELETE, because expiry and void are physical
   DELETEs.) 'order_items' is NEVER subscribed either: sql/01 declares
   order_id REFERENCES orders ON DELETE CASCADE, so one orders DELETE cascades
   into N order_items events — a flood the board never asked for. Line items
   arrive inside the payload of the orders event instead.

   FALLBACK: if the socket errors, closes, or the supabase-js ESM never loads
   from the CDN, this module drops to 3s polling on the page-supplied poll
   callback (kitchen_queue()). Both modes deliver the same jsonb, so the UI
   looks identical either way — no banner, no degraded view. `mode` tells the
   page which one it is on, for its status dot.
   =========================================================================== */

import { CONFIG } from './config.js';
import { getSessionToken } from './api.js';

export let mode = 'poll';        // 'ws' | 'poll' — the page shows this in a dot
let _pollTimer = null;           // active polling interval, or null
let _live = null;                // { close, drop } handle for the live socket, or null

/* --- polling fallback: the page's own queue read on a 3 s timer. The page
     passes the SAME function in both slots, so a dropped socket repaints
     exactly like a live one — no banner, no degraded view. */
function startPolling(poll) {
  mode = 'poll';
  if (_pollTimer) { clearInterval(_pollTimer); _pollTimer = null; }
  if (typeof poll !== 'function') return;
  _pollTimer = setInterval(() => { try { poll(); } catch { /* page owns copy */ } }, 3000);
}

/* --- stop: clear the timer, then close the live socket exactly once.
     FIX: the old teardown guarded on `_teardown !== mine`, and stopWatching()
     nulled _teardown BEFORE calling it, so the guard always bailed and the
     socket leaked open. The handle below is idempotent on its own `dead` flag
     instead, so the 'close' event the socket fires in reply to this very
     close() cannot resurrect it and cannot start a second poll timer. ------ */
export function stopWatching() {
  if (_pollTimer) { clearInterval(_pollTimer); _pollTimer = null; }
  const h = _live;
  _live = null;
  if (h) h.close();
}

export async function startWatching(onEvent, poll) {
  stopWatching();
  mode = 'poll';                     // pessimistic until the socket proves itself

  let client = null;
  try {
    /* dynamic import so a failed CDN load falls back to polling instead of
       breaking the page — a static import would make the whole module fail. */
    const sb = await import('https://cdn.jsdelivr.net/npm/@supabase/supabase-js@4/+esm');
    const { createClient } = sb;
    const bearer = getSessionToken() || CONFIG.sbKey;
    client = createClient(CONFIG.sbUrl, CONFIG.sbKey, {
      /* Realtime events are RLS-filtered for the subscriber: anon cannot read
         orders (sql/03_rls.sql), so the socket must carry the staff bearer or
         it would deliver nothing and the board would sit on polling forever. */
      global: { headers: { apikey: CONFIG.sbKey, Authorization: `Bearer ${bearer}` } },
      accessToken: bearer,
    });
  } catch {
    /* no supabase-js: stay on polling, silently */
  }

  if (!client) { startPolling(poll); return; }

  /* one handle so a socket error, a socket close, and stopWatching() all land
     in the same place exactly once. `dead` is per-socket, so a close event that
     fires AFTER stopWatching() already tore down cannot resurrect the socket
     and cannot start a second polling timer. */
  let socket = null;
  let dead = false;

  const closeBoth = () => {
    try { if (socket) socket.close({ code: 1000 }); } catch { /* already gone */ }
    try { client.close(); } catch { /* already gone */ }
  };

  const handle = { close: null, drop: null };
  const drop = () => {
    if (dead) return;
    dead = true;
    if (_live === handle) _live = null;
    closeBoth();
    startPolling(poll);              // the board keeps moving on the 3 s timer
  };
  const close = () => {
    if (dead) return;
    dead = true;
    if (_live === handle) _live = null;
    closeBoth();
  };
  handle.close = close;
  handle.drop = drop;

  try {
    socket = await client.socket([
      { type: 'subscribe', filter: 'eq:orders.INSERT' },
      { type: 'subscribe', filter: 'eq:orders.UPDATE' },
    ]);
    _live = handle;                  // stopWatching() can tear this down now
    /* the page's callback is sync-safe and payload-agnostic (it re-reads
       kitchen_queue()), but a throw inside it must never kill the socket. */
    const deliver = (payload) => { try { onEvent(payload); } catch { /* page owns copy */ } };
    socket.on('insert', deliver);    // a new paid order lands on the board
    socket.on('update', deliver);    // paid -> preparing -> served status moves
    socket.on('error', drop);
    socket.on('close', drop);
    await socket.ensureStarted();
    mode = 'ws';                     // the dot: live channel, not the 3 s timer
  } catch {
    drop();                          // socket refused: polling takes over
  }
}
