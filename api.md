# Counter POS – SaaS Mobile API Guide

This backend powers the Counter POS mobile app: business accounts, staff
memberships, a shared beverage catalog, shop inventory, selling, stock
receiving, FIFO cost layers, daily totals, and platform administration. There
is no public backend UI; clients use Supabase Auth, PostgREST, RPCs, Storage,
and RLS.

> [!CAUTION]
> **Previously deployed databases:** audit the deployed schema and migration ledger
> against `drizzle/migrations/meta/_journal.json` before applying any
> SQL. Do **not** blindly replay historical migrations; apply only an approved
> forward migration after confirming which objects already exist.

## 1. Connection settings

| Setting | Value |
|---|---|
| Project URL | `https://pvcqfoycrqtnirbwtccm.supabase.co` |
| Publishable key | See the project environment/configuration; it is safe to ship in a client |
| Currency | KES, whole shillings (integers) |
| Business day timezone | Africa/Nairobi |

The publishable key is not a secret. Never ship a service-role key in an APK.
Every business row is scoped by `shop_id`; RLS and security-definer RPCs enforce
that scope server-side.

## 2. Authentication and account lifecycle

```ts
await supabase.auth.signUp({ email, password });
await supabase.auth.signInWithPassword({ email, password });
await supabase.auth.signOut();
```

Email confirmation follows the Supabase project setting. After signing in,
call `my_account` to load memberships and platform-admin status:

```ts
const { data: account } = await supabase.rpc('my_account');
// account.user_id
// account.email
// account.is_platform_admin
// account.memberships: [{ shop_id, shop_name, role, status, currency, low_stock_threshold }]
```

A business is the tenant/account boundary. All staff are memberships in that
business. A suspended or closed business retains its inventory and sales, but
`is_shop_member` returns false, so reads and mutations stop immediately for the
owner and every staff member. The owner cannot reopen it; only a platform admin
can set the status back to `active`.

Create a business after a normal user signs up:

```ts
await supabase.rpc('create_shop', { _name: 'My Counter' });
```

## 3. Data model

| Table | Purpose | Important fields |
|---|---|---|
| `shops` | Business/tenant account | `id, name, status, currency, low_stock_threshold` |
| `shop_members` | Staff memberships | `shop_id, user_id, role` |
| `catalog_items` | Shared master beverage library | `code, barcode, name, category, suggested_price, image_url` |
| `products` | Business-owned inventory | `shop_id, code, price, stock, average_cost, archived` |
| `stock_receipts` | Immutable stock-in/adjustment ledger | `qty, unit_cost, supplier, reference, notes, received_by` |
| `stock_batches` | Remaining FIFO cost layers | `received_qty, remaining_qty, unit_cost, received_at` |
| `sales` | Sales ledger | `qty, stock_qty, unit_price, unit_cost_total, profit_total, undone_at` |
| `sale_batch_allocations` | Exact cost layers consumed by each sale | `sale_id, batch_id, qty, unit_cost` |
| `audit_events` | Administrative and stock/sales audit trail | `shop_id, actor_user_id, action, metadata` |

`products.average_cost` is a weighted-average display value. The accounting
source of truth is `stock_batches` plus `sale_batch_allocations`.

## 4. Roles

| Action | Owner | Manager | Inventory clerk | Cashier |
|---|---:|---:|---:|---:|
| View active business data | yes | yes | yes | yes |
| Sell products | yes | yes | no | yes |
| Receive stock / add catalog products | yes | yes | yes | no |
| Adjust stock count | yes | yes | no | no |
| Edit product price/name/photo | yes | yes | no | no |
| Undo a sale | yes | yes | no | no |
| Add/remove staff | yes | yes | no | no |
| Suspend/close/reopen business | platform admin only | platform admin only | platform admin only | platform admin only |

`owner` is reserved for the platform-admin-enrolled business owner. Current
onboarding supports only Owner and Waiter; Waiter is stored as `cashier` for
compatibility. Historical `manager` and `inventory_clerk` roles remain in the
database but are not offered by the current app.

```ts
await supabase.rpc('add_member_by_email', {
  _shop: shopId,
  _email: 'cashier@shop.ke',
  _role: 'cashier', // Waiter; the only staff role currently offered
});
```

## 5. Business administration RPCs

Platform admins are seeded by an operator inserting the trusted user UUID into
`public.platform_admins`; this table is never writable by client users.

```ts
const businesses = await supabase.rpc('admin_list_businesses');
await supabase.rpc('admin_create_business', {
  _name: 'New Client Business',
  _owner_email: 'owner@client.ke',
});
await supabase.rpc('admin_set_business_status', {
  _shop: shopId,
  _status: 'suspended', // active | suspended | closed
  _reason: 'Billing review',
});
```

### Complete business profile and counter setup

Use the forward onboarding RPC when a platform administrator is creating a
tenant. It is `SECURITY DEFINER`, but it still requires
`public.is_platform_admin()`; ordinary authenticated users and anonymous users
must not call it. The RPC delegates profile creation to
`admin_create_business`, then sets the counter inventory mode and adds counters
to the existing seeded **Counter 1**.

```ts
const { data: shop } = await supabase.rpc('admin_create_business_profile', {
  _name: 'Westlands Club',                 // text, required, 1..120 characters
  _owner_email: 'owner@client.ke',         // text, default null
  _business_type: 'big_club',              // text, default big_club
  _business_size: 'large',                 // text, default medium
  _counter_inventory_mode: 'per_counter',  // text, default shared
  _counter_count: 4,                       // int, default 1, range 1..50
});
```

The exact accepted values are:

| SQL value | Product/profile label | Profile behavior |
|---|---|---|
| `big_club` | Bar/Club | Tables, employee management, working hours, FIFO inventory, and sales analytics enabled |
| `counter_seller` | Liquor Store | Counter workflow, employee management, and FIFO inventory enabled; tables, working hours, and sales analytics disabled |

`_business_size` accepts `small`, `medium`, or `large`. The
`_counter_inventory_mode` accepts `shared` or `per_counter`. `_counter_count`
is the total number of active counters and must be an integer from 1 through
50; `1` keeps only the trigger-seeded `Counter 1`, while `4` creates
`Counter 1` through `Counter 4`. The RPC returns the created `public.shops` row,
including `business_type`, `business_size`, `feature_flags`, and
`counter_inventory_mode`. Invalid values raise `invalid_business_name`,
`invalid_business_type`, `invalid_business_size`,
`invalid_counter_inventory_mode`, or `invalid_counter_count`.

"Remove" is implemented as `closed`, not a destructive delete. This preserves
sales, inventory, batches, and audit history for later reopening.

## 6. Sales and stock RPCs

Stock and sales are never written directly from the client.

| Function | Args | Meaning |
|---|---|---|
| `record_sale` | `_product, _qty` | Bottle sale using configured product price |
| `record_sale_unit` | `_product, _qty, _unit_name, _unit_price` | Sale unit such as Bottle, Glass, or Cup; allocates FIFO stock |
| `undo_sale` | `_shop, _sale?` | Manager/owner-only undo; restores exact consumed batches |
| `receive_stock_with_cost` | `_product, _qty, _unit_cost?, _supplier?, _reference?, _notes?` | Adds a new independently priced batch |
| `add_from_catalog_with_cost` | `_shop, _catalog, _qty?, _price?, _unit_cost?` | Adds/receives catalog product and cost batch |
| `adjust_stock` | `_product, _new_stock, _reason?` | Audited positive/negative count adjustment |
| `register_product_with_cost` | product fields plus `_unit_cost` | Creates a custom product and opening cost batch |
| `find_product` | `_shop, _query` | Active shop-scoped barcode/code/name search |
| `daily_summary` | `_shop, _day?` | Daily revenue and quantity summary |

Legacy functions (`receive_stock`, `add_from_catalog`, `register_product`) stay
available and create a zero-cost batch for backward compatibility. New clients
should send unit cost whenever it is known.

### Different purchase price example

If the shop has 10 bottles at KSh 100 and receives 6 more at KSh 120:

```ts
await supabase.rpc('receive_stock_with_cost', {
  _product: productId,
  _qty: 6,
  _unit_cost: 120,
  _supplier: 'Supplier B',
  _reference: 'INV-1042',
});
```

The system keeps two layers: `10 × 100` and `6 × 120`. The next 10 bottle sales
consume the KSh 100 layer first (FIFO); later sales consume the KSh 120 layer.
Each sale stores its cost and gross profit. Undo restores the exact batch
allocations, so changing the selling price never rewrites historical costs.

`average_cost` is recalculated for quick display; it does not merge or delete
batches. If physical stock is counted at 13 instead of 16, use:

```ts
await supabase.rpc('adjust_stock', {
  _product: productId,
  _new_stock: 13,
  _reason: 'Weekly stock count – three damaged bottles',
});
```

## QR and passkey sign-in endpoints

Call the existing functions with `supabase.functions.invoke(name, { body })`.
Public endpoints require the client publishable key, not an administrator secret.

| Function | Body | Authentication |
|---|---|---|
| `create-access-challenge` | `{}` | Public |
| `poll-access-challenge` | `{ token }` | Public; possession of the QR token |
| `approve-access-challenge` | `{ token, shop_id, role }` | Platform admin for Owner; active business owner for Waiter (`cashier`) |
| `create-access-pass` | `{ shop_id, role }` | Platform admin for Owner; active business owner for Waiter (`cashier`) |
| `redeem-access-pass` | `{ passkey }` | Public; possession of the one-time passkey |
| `issue-superadmin-token` | `{}` | Signed-in platform admin |
| `redeem-superadmin-token` | `{ token }` | Public; possession of the valid superadmin token |

Create a QR challenge, display its returned `token`, then poll using that exact
token. Pending challenges have no shop until approval and return
`{ status: 'pending' }`, not `qr_not_found`. An approved challenge is claimed
with a conditional `approved → processing` update before identity creation;
concurrent polls cannot both return credentials. During processing, continue
polling. After consumption, credentials are not returned again. Challenges
expire after 10 minutes. A failed processor releases its claim for retry; a
claim left in `processing` is conditionally recoverable after four minutes if
the challenge is still valid. After expiry, create and approve a fresh QR.

QR/passkey redemption returns `email` and `password` for
`supabase.auth.signInWithPassword`; never log or persist these enrollment
credentials. Superadmin redemption returns the normal session tokens instead.
After signing in, call `my_account` and select the approved business.

Forward migration files `0021_admin_create_business_profile.sql`,
`0022_atomic_qr_claim.sql`, and `0023_owner_waiter_roles.sql` are present in this
checkout. Their presence in Git does not prove they reached the live database.
Before enabling business creation, audit the live ledger/schema for `0016` and
`0021`; before deploying the current poll function, confirm `0022`; before
relying on the role restrictions, confirm `0023`. Do not blindly replay
historical migrations to resolve drift.

## 7. Typical mobile flows

### First launch

```ts
const { data: account } = await supabase.rpc('my_account');
if (!account.memberships.length && !account.is_platform_admin) {
  await supabase.rpc('create_shop', { _name: 'My Counter' });
}
```

The app must select one active membership before loading business data. It must
clear its local cache when signing out or switching businesses.

### Load active business data

```ts
const { data: products } = await supabase
  .from('products')
  .select('*')
  .eq('shop_id', shopId)
  .eq('archived', false)
  .order('name');

const { data: sales } = await supabase
  .from('sales')
  .select('*')
  .eq('shop_id', shopId)
  .order('created_at', { ascending: false })
  .limit(200);
```

The backend still filters these rows with RLS; client-side `shop_id` filters are
for query efficiency, not a security boundary.

### Private product photos

Use a path beginning with the business UUID:

```ts
const path = `${shopId}/${crypto.randomUUID()}.jpg`;
await supabase.storage.from('product-photos').upload(path, file, {
  contentType: 'image/jpeg',
});
const { data } = await supabase.storage.from('product-photos').createSignedUrl(path, 3600);
```

Never use a service-role key in the mobile app. Storage policies enforce the
same active-business membership check.

## 8. Live updates

```ts
const channel = supabase.channel(`shop-${shopId}`)
  .on('postgres_changes', { event: '*', schema: 'public', table: 'products', filter: `shop_id=eq.${shopId}` }, refreshShelf)
  .on('postgres_changes', { event: '*', schema: 'public', table: 'stock_batches', filter: `shop_id=eq.${shopId}` }, refreshCosts)
  .on('postgres_changes', { event: 'INSERT', schema: 'public', table: 'sales', filter: `shop_id=eq.${shopId}` }, refreshToday)
  .subscribe();
```

## 9. Client security requirements

- Ship only the publishable key; never ship a service-role key.
- Store sessions in encrypted Android storage and clear them on explicit sign-out.
- Treat `status` and membership role returned by `my_account` as UX state only;
  the database remains the authorization boundary.
- Do not trust local Room/cache values for stock, price, role, or suspension.
- Use a release APK with R8 shrinking/obfuscation and a protected release
  keystore. APK code cannot be made impossible to reverse engineer; secrets and
  authorization must therefore live on the backend.

## 10. Edge Functions

The repository contains seven Supabase Edge Functions. Deploy every route to
the linked project with the JWT setting shown below; the service-role secret is
server-side only and must never be shipped in the APK.

| Function | `verify_jwt` | Client purpose |
|---|---:|---|
| `create-access-challenge` | `false` | Create a staff QR enrollment challenge |
| `poll-access-challenge` | `false` | Poll a challenge result |
| `redeem-access-pass` | `false` | Redeem a one-time business/employee passkey |
| `redeem-superadmin-token` | `false` | Redeem a rotating platform-admin token |
| `approve-access-challenge` | `true` | Platform admin enrolls an Owner; active owner enrolls a Waiter |
| `create-access-pass` | `true` | Platform admin issues an Owner pass; active owner issues a Waiter pass |
| `issue-superadmin-token` | `true` | Authenticated platform admin issues a 10-minute token |

QR sign-in is a phone-pairing flow: the requesting phone creates its challenge
and polls automatically; the Superadmin app approves the selected business and
role; the requesting phone then exchanges the one-time challenge for its
session. Polling atomically claims an approved challenge in a short-lived
`processing` state before identity and membership provisioning, so concurrent
pollers cannot both receive credentials. Stale claims are recoverable after
four minutes, while inactive memberships are never reactivated by retrying QR
provisioning. If approval returns HTTP 400, its
human-readable `message` names the invalid `token`, `shop_id`, or `role`; the
same response also includes those fields in the structured `invalid_fields`
array.

## 11. Type generation

`src/integrations/supabase/types.ts` is the generated TypeScript surface for the
original project. Regenerate it from the deployed Supabase schema after applying
these migrations so RPC and new-column types stay current.

## Business counters and lock state (added)
- `shops.counter_inventory_mode`: `shared` | `per_counter`. Table `service_counters` (id, shop_id, name, active) — every business gets "Counter 1" automatically; members can read.
- `my_account()` memberships now include `counter_inventory_mode`, `timezone`, `is_locked` and `can_sell_now`, plus top-level `server_time`.
- The app must lock a staff screen ONLY when `is_locked` is true (business not active, employee suspended/terminated, or outside working hours). Employees with no working hours set are never locked. Do not lock by default after QR enrollment — call `my_account()` after signing in and use `is_locked`.

### Calling signed-in sign-in endpoints (issue-superadmin-token, create-access-pass, approve-access-challenge)
Always send a *fresh* user access token. Access tokens expire after 1 hour; a stored token that was never refreshed returns
`401 {"error":"session_expired","reason":"token_expired"}`. Before calling, use `supabase.auth.getSession()` (auto-refreshes)
or `supabase.functions.invoke(...)`, which attaches the current session. On a 401, call `supabase.auth.refreshSession()` once and retry;
if that fails, send the user back to the sign-in screen. Never send the publishable key as the bearer token.
