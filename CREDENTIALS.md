# Test Credentials — POS Multi-Tenant System

> **Last updated:** 2026-10-24
> **Supabase Project:** `epldhypmhpxkebtiidsc` (sleepless-cafe)
> **Region:** ap-southeast-2
> **Auth Users:** 5 | **Staff Roster:** 5

---

## Store: Sleepless Café (flagship)
**Tier:** pro | **Store UUID:** `00000000-0000-0000-8333-000000000001`

| Role | Email | Password | Notes |
|------|-------|----------|-------|
| Owner | `dev@sleepless-cafe.test` | `DevStaff2026!` | Bootstrap owner, full access |
| Owner | `flagship-owner@sleepless-cafe.test` | `OwnerFlagship2026!` | Dedicated flagship owner account |

**Login URL:** `http://localhost:8731/login.html`
**Cashier URL:** `http://localhost:8731/cashier.html`
**Kitchen URL:** `http://localhost:8731/kitchen.html`
**Owner URL:** `http://localhost:8731/owner.html`
**Menu URL:** `http://localhost:8731/menu.html`

---

## Store: Marcelas B&B Restaurant (marcelas)
**Tier:** starter | **Store UUID:** `00000000-0000-0000-8333-000000000002`

| Role | Email | Password | Notes |
|------|-------|----------|-------|
| Owner | `marcelas-owner@sleepless-cafe.test` | `OwnerMarcelas2026!` | Dedicated Marcelas owner account |
| Cashier | `marcelas-cashier@sleepless-cafe.test` | `CashierMarcelas2026!` | Marcelas cashier station |
| Kitchen | `marcelas-kitchen@sleepless-cafe.test` | `MarcelasStaff2026!` | Marcelas kitchen board |

**Login URL:** `http://localhost:8731/marcelas-login.html`
**Kitchen URL:** `http://localhost:8731/marcelas-kitchen.html`
**Menu URL:** `http://localhost:8731/menu.html?store=marcelas`
**Owner URL:** `http://localhost:8731/marcelas-owner.html`

---

## Store Selector
**URL:** `http://localhost:8731/` (root index.html)
Redirects to the appropriate login page based on store selection.

---

## Edge Function (Store Token)
**Endpoint:** `https://epldhypmhpxkebtiidsc.supabase.co/functions/v1/store-token`
**Status:** DEPLOYED
**Purpose:** Mints store-bearing anon JWTs for multi-tenant realtime filtering

---

## Store Isolation

### How It Works
- Each user has a `store_id` in `staff_roster` table
- JWT tokens (from Edge Function) contain `sid` claim = store UUID
- RLS policies check: `jwt_store_id() IS NOT NULL AND store_id = jwt_store_id()`
- Login pages enforce store routing (flagship vs marcelas)
- Kitchen/Cashier/Owner boards pass `storeId` to `startWatching()` for realtime filtering

### Testing Isolation
1. **Cross-store order isolation:** Flagship order NOT visible on Marcelas kitchen board
2. **Login page isolation:** Marcelas login rejects flagship accounts and vice versa
3. **Realtime filtering:** WebSocket subscriptions scoped to store via `filter: 'store_id=eq.<storeId>'`

---

## Order Status Flow

```
Order Placed → pending_payment → paid → preparing → served
     │              │               │          │           │
     │              │               │          │           └─ Kitchen board hides
     │              │               │          └─ Kitchen board shows (Mark as Served)
     │              │               └─ Cashier confirms → kitchen sees it
     │              └─ Cashier board shows (Confirm Payment)
     └─ Customer cart → order created
```

**Key points:**
- Kitchen board (`kitchen_queue()`) only shows orders with status `paid` or `preparing`
- Cashier board (`list_active_pending()`) shows orders with status `pending_payment`
- Payment confirmation (`confirm_payment()`) transitions `pending_payment` → `paid`
- Kitchen "Mark as Served" (`mark_served()`) transitions `paid`/`preparing` → `served`

---

## Full Test Flow — Marcelas Store

### Step 1: Place Order
1. Open `menu.html?store=marcelas`
2. Add items to cart
3. Submit order → order code generated (e.g., 18551)

### Step 2: Confirm Payment (Cashier)
1. Open `login.html` → sign in as `dev@sleepless-cafe.test` (flagship owner, can access cashier)
   OR create a test flagship cashier order
2. Navigate to `cashier.html`
3. Look up order code from Step 1... **WAIT** — flagship cashier cannot see Marcelas orders!

**Correct approach for Marcelas cashier test:**
1. Sign in as `marcelas-cashier@sleepless-cafe.test` via `marcelas-login.html`
2. Navigate to `cashier.html?store=marcelas` or use the Marcelas cashier page
3. Look up order code → click "Confirm Payment"

### Step 3: Kitchen Board
1. Open `marcelas-login.html`
2. Sign in as `marcelas-kitchen@sleepless-cafe.test`
3. Navigate to `marcelas-kitchen.html`
4. Order should appear with status `paid` and timer counting up

### Step 4: Mark as Served
1. On kitchen board, click "Mark as Served" for the order
2. Order status changes to `served` → hidden from kitchen board

### Step 5: Owner Dashboard
1. Open `marcelas-login.html`
2. Sign in as `marcelas-owner@sleepless-cafe.test`
3. Navigate to `marcelas-owner.html`
4. View order history, sales reports, etc.

---

## Notes
- All users share the same Supabase project (multi-tenant architecture)
- RLS policies enforce store isolation via `store_id` column
- JWT claims contain `sid` (store UUID) for store-bearing anon tokens
- Staff users authenticate via Supabase Auth (email/password)
- `staff_session()` function is SECURITY DEFINER to bypass RLS on staff_roster
- **Deleted test users:** cashier-probe, kitchen-probe, kitchen-test, staff-probe, staff-probe2, staff-gate, owner (orphaned)
