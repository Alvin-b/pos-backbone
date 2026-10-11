# SaaS operations

## Apply the schema

Apply the migrations in `drizzle/migrations` in journal order. The role enum
values are deliberately in `0002_shop_roles.sql`, before the security functions
in `0003_saas_security_inventory.sql`. Do not run only the last file against a
fresh database.

The migrations use a shared PostgreSQL schema. `shop_id` is the tenant boundary;
RLS policies and security-definer RPCs check active membership and role on the
server. The Android app's local Room database is only a cache and must never be
treated as the inventory authority.

## Seed the first platform administrator

Create the administrator's Supabase Auth account through the normal sign-up
flow. After the user is confirmed, run this once from a trusted SQL/admin
channel, replacing the UUID with that Auth user's ID:

```sql
insert into public.platform_admins (user_id)
values ('00000000-0000-0000-0000-000000000000')
on conflict (user_id) do nothing;
```

There is intentionally no client-callable bootstrap RPC. `platform_admins` has
RLS and no client insert/update/delete grant. The admin console exposes only the
allowlisted `admin_list_businesses`, `admin_create_business`, and
`admin_set_business_status` RPCs.

## Business lifecycle

`active` businesses are usable. `suspended` and `closed` businesses retain
products, stock batches, sales, receipts, and audit events, but
`is_shop_member` returns false for every owner and staff membership. This means
PostgREST reads, Storage policies, sale/stock RPCs, and product mutations stop
without needing to edit or delete every user's Auth record. The owner cannot
reopen the business; a platform admin must call:

```sql
select public.admin_set_business_status(
  'business-uuid', 'active', 'Reopened after review'
);
```

The app labels “Close” as a retained closed state rather than destructive
business deletion. This preserves the owner's data for a later reopening.

## Role policy

The supported workspace roles are `owner`, `manager`, `inventory_clerk`, and
`cashier`. Owners and managers can manage products, staff, stock adjustments,
and sale undo. Inventory clerks can receive stock and add catalog products.
Cashiers can sell and view active business data. The UI hides unavailable
controls, but all security decisions are repeated inside the database RPCs.

## Different purchase prices

`stock_batches` stores one cost layer per receipt. `receive_stock_with_cost`
creates a batch with `unit_cost`; `record_sale_unit` consumes remaining batches
in `received_at, id` order and writes the exact allocation to
`sale_batch_allocations`. `sales.unit_cost_total` and `sales.profit_total` are
historical snapshots, so later purchases or price edits do not rewrite past
sales. `undo_sale` restores the exact allocations. `products.average_cost` is a
weighted-average display value only.

For an inventory count correction, call `adjust_stock` with a reason. Positive
corrections create an audited batch at the current average cost. Negative
corrections consume FIFO layers and create an audited receipt event. Direct
client writes to stock, cost, sales, or batch tables are not granted.

## Release APK

The Android release build enables R8 shrinking/obfuscation and excludes the
publishable session/cache from backup. Build it with a protected production
keystore and CI secrets, for example:

```bash
STORE_PASSWORD="$STORE_PASSWORD" KEY_PASSWORD="$KEY_PASSWORD" \
KEYSTORE_PATH="/secure/keystores/counterpos-upload.jks" \
./gradlew :app:assembleRelease
```

The publishable Supabase key may be in the client. A service-role key, database
password, or admin credential must never be placed in `BuildConfig`, resources,
assets, logs, or the APK.
