# SaaS operations

## Apply the schema

Apply `drizzle/migrations` in journal order. The important repair sequence for an existing database is:

1. Apply `0003_saas_security_inventory.sql` (the admin list RPC now has explicit return-type casts).
2. Apply `0004_access_passes.sql`.
3. Apply `0005_fix_admin_list_businesses.sql` if `0003` was already applied before the cast fix.

The role enum values are deliberately defined before the security functions. The migrations use one shared PostgreSQL schema: `shop_id` is the tenant boundary; RLS and security-definer RPCs check active membership and role on the server. The Android Room database is only a cache.

## Deploy the access-pass functions

From the `pos-backbone` repository, link the Supabase project and deploy the two functions:

```bash
supabase login
supabase link --project-ref YOUR_PROJECT_REF
supabase functions deploy create-access-pass
supabase functions deploy redeem-access-pass --no-verify-jwt
```

`create-access-pass` requires the caller's Supabase access token. `redeem-access-pass` intentionally accepts an anonymous request, but it accepts only a random, one-time passkey and immediately consumes it. The service-role key is used only inside Edge Functions and must never be placed in either APK.

The recipient flow is now:

1. Superadmin opens an active business and selects **Owner pass**.
2. The backend creates a random passkey, stores only its SHA-256 hash, and returns the plaintext once for copying.
3. The owner/staff APK pastes it and taps **Sign in with passkey**.
4. The redemption function validates expiry and one-time use, creates a synthetic Auth identity, attaches it to the business with the requested role, and returns short-lived sign-in credentials to the APK.
5. Supabase Auth creates the normal access/refresh session; all later access is still controlled by business status and RLS.

Passes expire after 24 hours and cannot be reused. A suspended or closed business cannot issue or redeem passes.

## Seed the first platform administrator

Create the administrator's Supabase Auth account through the normal Supabase Auth flow. After the user is confirmed, run this once from a trusted SQL/admin channel, replacing the UUID with that Auth user's ID:

```sql
insert into public.platform_admins (user_id)
values ('00000000-0000-0000-0000-000000000000')
on conflict (user_id) do nothing;
```

There is intentionally no client-callable bootstrap RPC. `platform_admins` has RLS and no client insert/update/delete grant. The separate Admin APK is the only UI that exposes the platform email/password login.

## Business lifecycle

`active` businesses are usable. `suspended` and `closed` businesses retain products, stock batches, sales, receipts, and audit events, but `is_shop_member` returns false for every owner and staff membership. The owner cannot reopen the business; a platform admin must call:

```sql
select public.admin_set_business_status(
  'business-uuid', 'active', 'Reopened after review'
);
```

## Role policy

The supported workspace roles are `owner`, `manager`, `inventory_clerk`, and `cashier`. Owners and managers can manage products, staff, stock adjustments, and sale undo. Inventory clerks can receive stock and add catalog products. Cashiers can sell and view active business data. UI restrictions are repeated inside database RPCs.

## Different purchase prices

`stock_batches` stores one cost layer per receipt. `receive_stock_with_cost` creates a batch with `unit_cost`; `record_sale_unit` consumes remaining batches in `received_at, id` order and writes the exact allocation to `sale_batch_allocations`. `sales.unit_cost_total` and `sales.profit_total` are historical snapshots. `undo_sale` restores exact allocations. `products.average_cost` is a weighted-average display value only.

## Release APK

The Android release build enables R8 shrinking/obfuscation and excludes the publishable session/cache from backup. Build with a protected production keystore and CI secrets:

```bash
STORE_PASSWORD="$STORE_PASSWORD" KEY_PASSWORD="$KEY_PASSWORD" \
KEYSTORE_PATH="/secure/keystores/counterpos-upload.jks" \
./gradlew :app:assembleRelease :admin:assembleRelease
```

The publishable Supabase key may be in the client. A service-role key, database password, or admin credential must never be placed in `BuildConfig`, resources, assets, logs, or an APK.
