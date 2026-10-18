# SYSTEM ARCHITECTURE & DEVELOPMENT SPECIFICATION: Café 4-Role POS & Ordering System

## 1. Project Overview & Objective
Build a lightweight, mobile-first, web-based café ordering, payment, and management system using **Supabase** (PostgreSQL, Realtime, Storage, Auth/RLS) for the backend and static/dynamic web pages (deployable on GitHub Pages for development and Vercel for production). 

The system operates across **four distinct interfaces (roles)** with strict workflow separation:
1. **Customer Webpage:** Interactive picture-card menu, cart, checkout with name capture, and automatic generation of a unique 5-digit claim code (60-minute TTL / auto-expiration).
2. **Cashier Webpage:** 5-digit code entry terminal + fallback management table of all unpaid, active orders to process payments and trigger kitchen queue.
3. **Kitchen Webpage:** Live real-time dashboard of paid orders showing customer name, payment time, item breakdown, and a "Mark as Served" action button that tracks total elapsed fulfillment time.
4. **Owner Webpage:** Administrative control center with Sales Analytics (Daily/Monthly/Yearly tabs), Order Turnover/Performance metrics, and a dynamic Menu & Category Builder with image upload.

---

## 2. Database Schema & Architecture (Supabase / PostgreSQL)

Design and execute the following relational database schema in Supabase:

### A. Tables
1. **`categories`**
   - `id` (UUID or SERIAL, Primary Key)
   - `name` (TEXT, e.g., "Coffee", "Pastries", "Main Course")
   - `display_order` (INTEGER, for sorting)
   - `created_at` (TIMESTAMPTZ)

2. **`menu_items`**
   - `id` (UUID or SERIAL, Primary Key)
   - `category_id` (FOREIGN KEY references `categories(id)`)
   - `name` (TEXT)
   - `description` (TEXT)
   - `image_url` (TEXT - Supabase Storage public URL)
   - `sizes_and_prices` (JSONB, e.g., `[{"size": "Regular", "price": 120}, {"size": "Large", "price": 150}]`)
   - `is_available` (BOOLEAN, default TRUE)
   - `created_at` (TIMESTAMPTZ)

3. **`orders`**
   - `id` (UUID or SERIAL, Primary Key)
   - `code` (VARCHAR(5), UNIQUE, 5-digit alphanumeric code generated on checkout)
   - `customer_name` (TEXT)
   - `status` (VARCHAR(30), ENUM: `pending_payment`, `paid`, `preparing`, `served`, `cancelled`, `expired`)
   - `total_amount` (DECIMAL(10,2))
   - `created_at` (TIMESTAMPTZ, default NOW())
   - `expires_at` (TIMESTAMPTZ, default `NOW() + INTERVAL '60 minutes'`)
   - `paid_at` (TIMESTAMPTZ, NULLable)
   - `served_at` (TIMESTAMPTZ, NULLable)
   - `fulfillment_time_seconds` (INTEGER, calculated upon serving)

4. **`order_items`**
   - `id` (UUID or SERIAL, Primary Key)
   - `order_id` (FOREIGN KEY references `orders(id)` ON DELETE CASCADE)
   - `menu_item_id` (FOREIGN KEY references `menu_items(id)`)
   - `item_name` (TEXT snapshot)
   - `size` (TEXT snapshot)
   - `unit_price` (DECIMAL(10,2))
   - `quantity` (INTEGER)
   - `subtotal` (DECIMAL(10,2))

### B. Database Triggers & Functions
- **Auto-Expiration Logic:** Implement a PostgreSQL function or Supabase Cron job that periodically updates orders where `status = 'pending_payment'` and `expires_at < NOW()` to `status = 'expired'`, releasing them from active cashier tables.
- **Realtime Publication:** Enable Supabase Realtime on the `orders` table so the Cashier and Kitchen screens update instantly without manual page refreshes.

---

## 3. Detailed Interface & Workflow Specifications

### Role 1: Customer Interface (`/menu.html`)
- **UI Structure:** Mobile-optimized layout with category navigation tabs at the top.
- **Menu Display:** Picture cards featuring item image, name, description, size selector options, price, and an interactive quantity stepper (`+` / `-`) with an **"Add to Cart"** button.
- **Cart Drawer / Modal:** Shows selected items, chosen sizes, itemized prices, total count, and a **"Proceed to Checkout"** button.
- **Checkout Flow:**
  1. Prompts the customer for their **Full Name**.
  2. Inserts an order into the Supabase database with status `pending_payment` and calculates `expires_at` (`NOW() + 60 minutes`).
  3. Generates a cryptographically secure random **5-digit code** (e.g., `48291`).
  4. Displays a success confirmation screen: *"Order Placed! Please present your code **48291** and your name (**[Customer Name]**) to the cashier within 60 minutes to process payment."*

### Role 2: Cashier Interface (`/cashier.html`)
- **UI Structure:** Dedicated desktop/tablet terminal view.
- **Code Entry Search:** A prominent search input where the cashier can quickly type or scan the 5-digit code. Submitting pulls up the order details instantly.
- **Active Unpaid Orders Table:** For cases where a customer forgets their code, display a live-updating table of all orders where `status = 'pending_payment'` and `expires_at > NOW()`.
  - *Table Columns:* Code, Customer Name, Time Created, Time Remaining (countdown), No. of Items/Drinks, Total Amount.
- **Action Workflow:** Cashier verifies payment (cash/e-wallet), clicks **"Confirm Payment"**, which updates the order `status` to `paid` and sets `paid_at = NOW()`. This instantly broadcasts the order to the Kitchen queue.

### Role 3: Kitchen Display System - KDS (`/kitchen.html`)
- **UI Structure:** High-contrast, large-text dashboard optimized for kitchen monitors or tablets.
- **Live Feed:** Subscribes to Supabase Realtime for orders where `status = 'paid'`. Orders appear as visual cards sorted chronologically.
- **Card Information:**
  - Customer Name & 5-Digit Code
  - Payment Time (`paid_at`)
  - Live Elapsed Time Counter (showing how many minutes/seconds have passed since payment was received)
  - Itemized list with quantities and custom size choices.
- **Action Workflow:** Kitchen staff taps **"Mark as Served"** when the order is ready. This updates `status` to `served`, records `served_at = NOW()`, computes `fulfillment_time_seconds` (`served_at - paid_at`), and archives the card from the active kitchen view.

### Role 4: Owner Dashboard (`/owner.html`)
- **UI Structure:** Secure tabbed administrative control center.
- **Tab 1: Sales Records**
  - Interactive date-range filters (Daily, Monthly, Yearly summaries).
  - Metrics cards: Total Revenue, Total Orders Completed, Average Order Value.
  - Exportable data logs of completed sales.
- **Tab 2: Order Turnover & Performance**
  - Metrics tracking average kitchen fulfillment time (speed of service from payment to serving).
  - Peak ordering hour heatmaps based on `created_at` timestamps.
- **Tab 3: Menu Creation**
  - Form to upload menu item pictures (connected to Supabase Storage bucket).
  - Inputs for Item Name, Description, Size variants (dynamic key-value pair builder for Size + Price), and Category assignment.
- **Tab 4: Menu Grouping & Tab Management**
  - Interface to create, reorder, and delete category tabs (e.g., Coffee, Non-Coffee, Pastries, Desserts).

---

## 4. Technical Guardrails & Best Practices
- **Client-Side Routing Workaround:** Since initial development will run on static hosting (GitHub Pages), use separate HTML entry points (`index.html` or `menu.html`, `cashier.html`, `kitchen.html`, `owner.html`) or query parameter routers to prevent `404 Not Found` routing errors.
- **Error Handling:** Graceful fallbacks for network disconnects, database timeouts, and invalid 5-digit code lookups at the cashier terminal.
- **Security:** Use Supabase Row Level Security (RLS) policies where appropriate, ensuring public access for menu reads and order inserts, while locking down owner modifications.