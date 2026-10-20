/* ===========================================================================
   assets/config.js — COMMITTED to the repo and served publicly on GitHub Pages
   (https://savage13317.github.io/sleepless-cafe-pos/).
   Contains NO secret. `sbKey` is the PUBLISHABLE (client) key only, which is
   browser-safe by design (Supabase publishable keys are meant to be public; the
   repo is public and the key already appears in the live site's localStorage/URL).
   The service-role/secret key never appears here, and never appears in the browser
   at all — it lives only in server-side tooling (tools/inject-config.mjs, Vercel
   env) and in the Supabase dashboard.

   Resolution priority, first non-empty value wins:
     1. window.SL_CONFIG   — Phase B: tools/inject-config.mjs sets it from Vercel
                             env before the page's module graph runs. Wins over both.
     2. localStorage       — dev/override path: a page reads ?sburl= / ?sbkey= query
                             params exactly once, writes {sbUrl,sbKey} to the 'sl_config'
                             key, so later visits need no query string.
     3. committed default  — this file: the REAL project URL + publishable key. This
                             is what makes the GitHub Pages deployment work for a
                             first-time visitor with no query string and empty
                             localStorage. Still no secret committed here.
   =========================================================================== */

const _LS = (() => {
  try { return JSON.parse(localStorage.getItem('sl_config') || '{}'); } catch { return {}; }
})();

export const CONFIG = {
  sbUrl: (window.SL_CONFIG?.sbUrl) || _LS?.sbUrl || 'https://epldhypmhpxkebtiidsc.supabase.co',
  sbKey: (window.SL_CONFIG?.sbKey) || _LS?.sbKey || 'sb_publishable_krQEeT-v7feHLYl01f8zsw_to9JjsAD',
  ownerEmails: ((window.SL_CONFIG?.ownerEmails || _LS?.ownerEmails || '').split(',')).filter(Boolean),
  ttlMinutes: 60,
};
