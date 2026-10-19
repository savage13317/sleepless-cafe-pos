/* ===========================================================================
   assets/config.js — COMMITTED to the repo and served publicly on GitHub Pages.
   Contains NO secret. `sbKey` is the PUBLISHABLE (client) key only.
   The service-role key never appears here, and never appears in the browser at
   all — it lives only in server-side tooling (tools/inject-config.mjs, Vercel
   env) and in the Supabase dashboard.

   Resolution priority, first non-empty value wins:
     1. window.SL_CONFIG   — Phase B: tools/inject-config.mjs sets it from Vercel
                             env before the page's module graph runs.
     2. localStorage       — Phase A: a page reads ?sburl= / ?sbkey= query params
                             exactly once, writes {sbUrl,sbKey} to the 'sl_config'
                             key, so later visits need no query string.
     3. committed default  — this file (placeholder only, never a real URL/key).
   =========================================================================== */

const _LS = (() => {
  try { return JSON.parse(localStorage.getItem('sl_config') || '{}'); } catch { return {}; }
})();

export const CONFIG = {
  sbUrl: (window.SL_CONFIG?.sbUrl) || _LS?.sbUrl || 'https://REPLACE_ME.supabase.co',
  sbKey: (window.SL_CONFIG?.sbKey) || _LS?.sbKey || '',
  ownerEmails: ((window.SL_CONFIG?.ownerEmails || _LS?.ownerEmails || '').split(',')).filter(Boolean),
  ttlMinutes: 60,
};
