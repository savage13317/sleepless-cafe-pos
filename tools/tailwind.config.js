/* ===========================================================================
   tools/tailwind.config.js — Phase-B build-time Tailwind v3 config.
   ---------------------------------------------------------------------------
   This is the BUILD-TIME replacement for the inline `tailwind.config` script
   that each POS page runs at runtime (see the <script> block in menu.html,
   lines ~46-70). In Phase A the pages load cdn.tailwindcss.com and read the
   :root custom properties out of the *resolved* stylesheet at runtime. In
   Phase B we ship ONE compiled stylesheet instead of the dev-only CDN, so the
   same palette must be resolved at BUILD time.

   Single source of truth: this config READS assets/tokens.css via
   fs.readFileSync + regex. tokens.css stays the only place brand colors and
   fonts are defined; the compiled artifact (assets/tailwind.compiled.css) is a
   DERIVED file. When a token changes, edit tokens.css and re-run the build —
   never hand-edit the compiled CSS.

   The '#000000' fallback mirrors the pages' inline script exactly: a failed
   stylesheet load can never inject `undefined` into generated CSS.
   =========================================================================== */

const fs = require('fs');
const path = require('path');

/* tokens.css lives one level up from this file (tools/ -> ../assets/).
   Resolve relative to __dirname so the build works from any cwd. */
const tokensCss = fs.readFileSync(path.join(__dirname, '..', 'assets', 'tokens.css'), 'utf8');

/* Parse a custom property value out of tokens.css. The colon pattern tolerates
   the multi-space column alignment used in the file (e.g. --brand-card-hover:
   followed by spaces then the hex). Capture stops at the first semicolon so any
   trailing CSS comment is excluded. Falls back to the neutral '#000000' — never
   a brand hex, never undefined. */
function token(name) {
  const re = new RegExp('--' + name + '\\s*:\\s*([^;]+);');
  const m = re.exec(tokensCss);
  const v = m ? m[1].trim() : '';
  return v || '#000000';
}

/* Font stacks: split the comma-separated list into an array, trimming each
   family. Mirrors the pages' F() helper. */
function fonts(name) {
  return token(name).split(',').map(function (s) { return s.trim(); });
}

module.exports = {
  /* Scan the POS entry points. login.html is the staff door (Gate B, unindexed)
     and now contributes its own utilities. Sleepless.html stays design reference
     only and must not contribute classes to the production stylesheet. */
  content: [
    'index.html',
    'menu.html',
    'login.html',
    'cashier.html',
    'kitchen.html',
    'owner.html',
  ],
  theme: {
    extend: {
      colors: {
        brand: {
          dark:        token('brand-dark'),
          card:        token('brand-card'),
          cardHover:   token('brand-card-hover'),   /* camelCase key  <- kebab token */
          accent:      token('brand-accent'),
          accentLight: token('brand-accent-light'),
          cream:       token('brand-cream'),
          muted:       token('brand-muted'),
          border:      token('brand-border'),
        },
      },
      fontFamily: {
        sans:  fonts('font-sans'),
        serif: fonts('font-serif'),
      },
    },
  },
};
