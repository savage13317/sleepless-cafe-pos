# Store brief — Marcela's B&B Restaurant (`marcelas`)

Second branch of the Ordering System. Flagship (`Sleepless Cafe`, slug `flagship`)
is untouched by anything in this folder: every rule in `stores/marcelas/tokens.css`
is scoped to `[data-sl-store="marcelas"]`, so it can never repaint flagship.

## Identity

| field | value |
|---|---|
| slug | `marcelas` — what a QR code / URL carries |
| store uuid | `00000000-0000-0000-8333-000000000002` (flagship is `…0001`) |
| name | `Marcela's B&B Restaurant` (SQL literal doubles the apostrophe: `'Marcela''s B&B Restaurant'`) |
| tier | `starter` (flagship is `pro`, so the tier axis stays observable) |
| city | `Gamay, Northern Samar` |
| timezone | `Asia/Manila` |
| is_open | `true` |

Catalogue: **4 categories / 10 items**, its own rows only —
categories `33333333-…-8333-0000000000NN`, menu_items `44444444-…-8333-0000000000NN`.

## Brand palette

Taken from Marcela's own website (its inline Tailwind config: `gold` 400/500/600/700
+ `resort` dark/cream, fonts `Cinzel` serif and `Plus Jakarta Sans` sans), mapped
onto the SAME token names the project already uses, so no new token names exist
anywhere.

| token | hex | rgb triple | where it came from on the website |
|---|---|---|---|
| `--brand-dark` | `#0f172a` | `15 23 42` | `resort.dark` — page background |
| `--brand-card` | `#1e293b` | `30 41 59` | slate-800 — website card surface |
| `--brand-card-hover` | `#334155` | `51 65 85` | slate-700 — card hover surface |
| `--brand-accent` | `#d4af37` | `212 175 55` | `gold.500` — primary accent |
| `--brand-accent-light` | `#e6c65a` | `230 198 90` | `gold.400` — light accent / highlights |
| `--brand-cream` | `#faf9f6` | `250 249 246` | `resort.cream` — body text |
| `--brand-muted` | `#94a3b8` | `148 163 184` | slate-400 — secondary text |
| `--brand-border` | `#8c6a15` | `140 106 21` | `gold.700` — hairline borders |
| `--font-sans` | `'Plus Jakarta Sans', sans-serif` | — | website `sans` family |
| `--font-serif` | `'Cinzel', serif` | — | website `cinzel` family (wordmark / headings) |

Flagship's single source of truth stays `assets/tokens.css`; this file is a
**store theme overlay**, not a replacement for it.

## Seed file

`sql/10_marcelas_store.sql` — writes the store row, the 4 categories and the 10
menu items. Three INSERTs, nothing else; idempotent (`ON CONFLICT (id) DO NOTHING`
on fixed literal UUIDs); no DELETE/TRUNCATE/DROP anywhere. `store_id` is passed
EXPLICITLY on every row — the constant default is the flagship uuid, so omitting it
would plant Marcela's breakfast menu inside Sleepless Cafe.

## Replay order

```
01_schema → 02_functions → 03_rls → 04_realtime → 05_seed
→ 06_storage → 07_staff_roster → 08_multitenant → 09_function_delta → 10_marcelas_store
```

`10_` must come last: its FKs point at rows the earlier files create.

## How to view it

```
menu.html?store=marcelas
```

`menu.html` reads `?store=` and stamps `data-sl-store` on `<html>` before first
paint; `stores/marcelas/tokens.css` is loaded unconditionally right after
`assets/tailwind.compiled.css`, and every rule in it is scoped to that attribute —
so loading it on the flagship page is a strict no-op.

## Honest limitation — orders do not follow the branch yet

Browsing `menu.html?store=marcelas` shows Marcela's own menu, because
`menu_for_store` / `categories_for_store` are called with the resolved
`store_id`. **Placing an order does not land in Marcela's store.**

`create_order` derives its branch from `jwt_store_id()` and COALESCEs a missing
token to the flagship uuid:

```sql
sid := COALESCE(jwt_store_id(), '00000000-0000-0000-8333-000000000001'::uuid);
```

An anon customer browsing the page carries **no store token** — the short-lived
anon `sid` is minted server-side when a QR is scanned, not when a URL is typed.
So a claim code placed from `menu.html?store=marcelas` today is written with
`store_id = flagship` and is visible to flagship's cashier/kitchen surfaces, not
Marcela's. The theme is correct; the routing is not. Closing that gap needs a
store-scoped anon token (a later phase), not a client-side change.

## Theme architecture (why this file has two blocks)

Theming has two layers and a store theme must cover both:

1. `assets/app.css` consumes `var(--brand-*)` **at runtime** → overriding the
   custom properties cascades there. ✓
2. `assets/tailwind.compiled.css` is a **build artifact with literal hex baked in**
   (`tools/tailwind.config.js` reads `assets/tokens.css` and resolves `token()` to
   hex at build time). A custom-property override does **NOT** change those classes. ✗

So block 2 of `tokens.css` re-declares each of the 27 `brand-*` utility rules
actually present in the compiled artifact, each prefixed with the scope
`[data-sl-store="marcelas"] `. That block is a **hand-mirrored copy of the build
artifact** — the durable fix is a second Tailwind build run with these tokens
(Phase-9 follow-up), and any future rebuild of `tailwind.compiled.css` must be
re-mirrored here.
