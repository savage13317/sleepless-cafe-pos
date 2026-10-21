/* ===========================================================================
   assets/realtime.js — Phase 4 realtime transport for the KDS board.

   EXACT WIRE (matches sql/04_realtime.sql, copy verbatim):
     wss://<sbUrl>/websocket?apikey=<publishable>
   Authorize with the same PUBLISHABLE key api.js already uses; the service-role
   key is never involved.

   FILTER STRINGS (the `ph` param the wire encodes):
     eq:orders.INSERT      a new paid order lands on the board
     eq:orders.UPDATE      paid -> preparing -> served status moves
   supabase-js 2.118.0 equivalent of those filters:
     .on('postgres_changes', { event:'INSERT', schema:'public', table:'orders' }, cb)
     .on('postgres_changes', { event:'UPDATE', schema:'public', table:'orders' }, cb)
   on the 'orders' table. The dynamic import below is therefore pinned to
   @supabase/supabase-js@2.118.0 — the only version proven to resolve on the CDN.

   FIX: the import moved from @supabase/supabase-js@4 to @2.118.0.
     Verified against the npm registry + jsDelivr: NO 4.x exists. dist-tags for
     both @supabase/supabase-js and @supabase/realtime-js are latest 2.118.0,
     3.0.0-next.29 (prerelease), rc 2.100.0-rc.0, beta 2.112.0-beta.0, canary
     2.118.0-canary.2. `cdn.jsdelivr.net/npm/@supabase/supabase-js@4/+esm` returns
     the 48-char body "Couldn't find the requested release version 4." so the old
     dynamic import THREW, the catch fired, mode stayed 'poll', and the board ran
     silently on the 3 s polling fallback — Phase 4's gate was never met.
     Worse, the published 2.118.0 API is Phoenix-channel based and has NO
     client.socket, NO ensureStarted, and NO client.close — the three members the
     old code called — so even a successful @4 import could not have connected.
     Rewritten here to the verified 2.x surface: createClient -> client.channel
     -> .on('postgres_changes', ...) -> .subscribe(cb, timeout) with
     postgres_changes_options.wait:true, teardown via removeChannel + async
     disconnect. Never pin a major version that has not been proven to resolve.

   Delivery is RLS-gated ("records are sent only to clients allowed to read them"):
   anon has no SELECT policy on orders (sql/03_rls.sql), so the socket MUST carry
   the staff bearer or it delivers nothing — see accessToken below.

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

   • The poll now runs ALONGSIDE a live socket, not only behind a dead one: a
     WebSocket can die silently (a throttled/backgrounded tab kills the
     connection without ever firing a 'close' event, and a long idle gap can
     drop it the same way), so with nothing but the socket the board freezes
     and the cook has to refresh. A backstop poll timer always runs while the
     socket lives, so a silently-dead socket can never leave the board frozen.
     The socket still repaints instantly when it works; same callback, same
     payload, so both paths look identical.
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

  /* BACKSTOP (item: paid orders appeared late on the KDS): a WebSocket can die
     silently - a throttled/backgrounded tab kills the connection without ever
     firing a 'close' event, and a long idle gap can drop it the same way. With
     nothing but the socket, the board then freezes and the cook has to refresh
     the page. So the poll timer runs ALONGSIDE a live socket instead of only
     behind a dead one: the socket still repaints instantly when it works, and
     a silently-dead socket can never leave the board frozen. Same callback,
     same payload, so both paths look identical. */
  startPolling(poll);

  let client = null;
  try {
    /* dynamic import so a failed CDN load falls back to polling instead of
       breaking the page — a static import would make the whole module fail. */
    const sb = await import('https://cdn.jsdelivr.net/npm/@supabase/supabase-js@2.118.0/+esm');
    const { createClient } = sb;
    client = createClient(CONFIG.sbUrl, CONFIG.sbKey, {
      /* accessToken is a CALLBACK (() => Promise<string|null>), called on connect
         AND on every heartbeat — so it re-reads the session token each time. The
         staff bearer is required: anon cannot SELECT orders, so RLS would deliver
         nothing over the socket. Do NOT pass global:{headers:...} — websocket
         connections cannot carry headers in 2.118.0 (apikey rides in params). */
      accessToken: () => {
        const t = getSessionToken();
        return t || null;
      },
    });
  } catch {
    /* no supabase-js: stay on polling, silently */
  }

  if (!client) { startPolling(poll); return; }

  /* one handle so a subscribe error, a socket close, and stopWatching() all land
     in the same place exactly once. `dead` is per-socket, so a CLOSED event that
     fires AFTER stopWatching() already tore down cannot resurrect the socket and
     cannot start a second polling timer. Teardown in 2.118.0 = removeChannel(ch)
     (or ch.unsubscribe()) then await client.disconnect(); disconnect is async
     (returns "ok"|"timeout"), and stopWatching() must stay synchronous, so the
     disconnect is fire-and-forget with a catch guard. */
  let ch = null;
  let dead = false;

  const teardown = () => {
    if (ch) { try { ch.unsubscribe(); } catch { /* already gone */ } }
    if (client) {
      try { client.removeChannel(ch); } catch { /* already gone */ }
      /* disconnect is async ("ok"|"timeout"); fire-and-forget so stopWatching()
         stays synchronous. */
      try { void client.disconnect(1000, 'stop').catch(() => {}); } catch { /* already gone */ }
    }
  };

  const handle = { close: null, drop: null };
  const drop = () => {
    if (dead) return;
    dead = true;
    if (_live === handle) _live = null;
    teardown();
    startPolling(poll);              // the board keeps moving on the 3 s timer
  };
  const close = () => {
    if (dead) return;
    dead = true;
    if (_live === handle) _live = null;
    teardown();
  };
  handle.close = close;
  handle.drop = drop;

  try {
    /* the page's callback is sync-safe and payload-agnostic (it re-reads
       kitchen_queue()), but a throw inside it must never kill the socket. */
    const deliver = (payload) => { try { onEvent(payload); } catch { /* page owns copy */ } };

    /* wait:true holds the SUBSCRIBED callback until the SERVER confirms the
       subscription, and reports CHANNEL_ERROR on failure — so the ws/poll
       decision is honest, never optimistic. */
    ch = client.channel('orders-watch', {
      config: { postgres_changes_options: { wait: true } },
    });
    ch.on('postgres_changes', { event: 'INSERT', schema: 'public', table: 'orders' }, deliver);
    ch.on('postgres_changes', { event: 'UPDATE', schema: 'public', table: 'orders' }, deliver);
    _live = handle;                  // stopWatching() can tear this down now

    /* subscribe() is not itself awaitable for the join result, so wrap it: resolve
       only when the callback reports SUBSCRIBED (server-confirmed). Any other
       status (CLOSED / CHANNEL_ERROR / ERR) tears down to polling. A belt-and-
       braces timeout below guarantees startWatching() never hangs the page boot
       if the callback is never invoked at all — the board then runs on polling
       and `mode` never lies about a socket that was never confirmed. */
    await new Promise((resolve, reject) => {
      const guard = setTimeout(() => { drop(); reject(new Error('subscribe unconfirmed')); }, 12000);
      const clear = () => clearTimeout(guard);   // called on every exit path below
      try {
        ch.subscribe((status, err) => {
          if (status === 'SUBSCRIBED' || status === 'ok') {
            clear();
            resolve();
          } else {
            clear();
            drop();                  // CLOSED / CHANNEL_ERROR: polling takes over
            reject(new Error('subscribe not confirmed'));
          }
        }, 10000);
      } catch {
        clear();
        reject(new Error('subscribe threw'));
      }
    });
    mode = 'ws';                     // the dot: live channel, not the 3 s timer
  } catch {
    drop();                          // socket refused / not confirmed: polling takes over
  }
}
