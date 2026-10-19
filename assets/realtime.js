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
let _teardown = null;            // active socket teardown, or null
let _pollTimer = null;           // active polling interval, or null

export function stopWatching() {
  if (_pollTimer) { clearInterval(_pollTimer); _pollTimer = null; }
  const t = _teardown;
  _teardown = null;
  if (t) t();
}

export async function startWatching(onEvent, poll) {
  stopWatching();
  mode = 'poll';                    // pessimistic until the socket proves itself

  let client = null;
  try {
    /* dynamic import so a failed CDN load falls back to polling instead of
       breaking the page — a static import would make the whole module fail. */
    const sb = await import('https://cdn.jsdelivr.net/npm/@supabase/supabase-js@2/+esm');
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

  if (!client) { _startPolling(poll); return; }

  /* one shared teardown so a socket error, a socket close, and stopWatching()
     all land in the same place exactly once. */
  let socket = null;
  let mine = null;

  const giveUp = () => {
    if (_teardown !== mine) return;              // already superseded
    _teardown = null;
    try { if (socket) socket.close({ code: 1000 }); } catch { /* already gone */ }
    _startPolling(poll);
  };

  const teardown = () => {
    if (_teardown !== mine) return;
    _teardown = null;
    try { if (socket) socket.close({ code: 1000 }); } catch { /* already gone */ }
    try { client.close(); } catch { /* already gone */ }
  };

  try {
    socket = await client.socket([
      { type: 'subscribe', filter: 'eq:orders.INSERT' },
      { type: 'subscribe', filter: 'eq:orders.UPDATE' },
    ]);
    socket.on('insert', (payload) => onEvent(payload));
    socket.on('update', (payload) => onEvent(payload));
    socket.on('error', giveUp);
    socket.on('close', giveUp);
    await socket.ensureStarted();
    mine = teardown;
    _teardown = mine;
    mode = 'ws';
  } catch {
    giveUp();
  }
}

function _startPolling(poll) {
  mode = 'poll';
  if (_pollTimer) clearInterval(_pollTimer);
  _pollTimer = setInterval(() => { try { poll(); } catch { /* page owns copy */ } }, 3000);
}
