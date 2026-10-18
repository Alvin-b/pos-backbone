# SaaS operations

## Apply the schema

> [!CAUTION]
> **Previously deployed databases:** first audit the deployed schema and its
> migration ledger against `drizzle/migrations/meta/_journal.json`. Do **not**
> blindly replay historical migrations on an existing database. Confirm which
> migrations and objects are already present, then apply only an approved
> forward repair (such as `0021_admin_create_business_profile.sql`,
> `0022_atomic_qr_claim.sql`, or `0023_owner_waiter_roles.sql`).

For a clean database, use the journal-driven migration command/process and run
the entries in `drizzle/migrations/meta/_journal.json` order. The repaired
journal includes every SQL file exactly once, including the previously omitted
employee/profile/access-control migrations and the new `0021`–`0023` migrations.
Its tags are the migration filename stems and its `when` values are strictly
increasing. Do not substitute a numeric filename sort for the journal when
there are duplicate historical prefixes such as `0004_*` and `0005_*`.

For an existing database, inventory the deployed migration ledger, tables,
columns, functions, triggers, policies, and grants first. Compare that
inventory with the journal and SQL, resolve any drift, and record the repair
plan before running SQL. The old repair sequence in prior versions of this
document is not a license to rerun `0003`–`0016`; those historical files may
already be partially or fully applied.

The role enum values are deliberately defined before the security functions.
The migrations use one shared PostgreSQL schema: `shop_id` is the tenant
boundary; RLS and security-definer RPCs check active membership and role on the
server. The Android Room database is only a cache.

Migration `0016_counter_inventory_modes.sql` now also creates the unique
`(shop_id, name)` index required by its counter-seeding `ON CONFLICT` clauses.
If index creation reports duplicate rows, inspect and resolve duplicate counter
names before retrying; do not remove the conflict clauses.

## Deploy the Edge Functions

From the `pos-backbone` repository, link the Supabase project and deploy all
seven functions. The commands without `--no-verify-jwt` retain the configured
JWT verification default (`verify_jwt = true`):

```bash
supabase login
supabase link --project-ref YOUR_PROJECT_REF
supabase functions deploy create-access-challenge --no-verify-jwt
supabase functions deploy poll-access-challenge --no-verify-jwt
supabase functions deploy redeem-access-pass --no-verify-jwt
supabase functions deploy approve-access-challenge
supabase functions deploy create-access-pass
supabase functions deploy issue-superadmin-token
supabase functions deploy redeem-superadmin-token --no-verify-jwt
```

| Function | `verify_jwt` | Deployment/authentication purpose |
|---|---:|---|
| `create-access-challenge` | `false` | Unauthenticated challenge creation; the function validates the request payload |
| `poll-access-challenge` | `false` | Unauthenticated polling of a challenge result |
| `redeem-access-pass` | `false` | Unauthenticated one-time passkey redemption |
| `redeem-superadmin-token` | `false` | Unauthenticated rotating-token redemption |
| `approve-access-challenge` | `true` | Platform admin enrolls an Owner; active owner enrolls a Waiter |
| `create-access-pass` | `true` | Platform admin issues an Owner pass; active owner issues a Waiter pass |
| `issue-superadmin-token` | `true` | Authenticated platform-admin token issuance |

All seven source folders live under `supabase/functions/`. Keep the
service-role secret available only to the Edge Functions; never put it in
client code, logs, or an APK.

The mobile app calls `POST https://YOUR_PROJECT_REF.supabase.co/functions/v1/create-access-challenge`. If the app reports **requested function was not found**, the function has not been deployed to the linked Supabase project (or the APK is using a different project URL). Verify it with:

```bash
supabase functions list
curl -i -X POST "https://YOUR_PROJECT_REF.supabase.co/functions/v1/create-access-challenge" \
  -H "apikey: YOUR_PUBLISHABLE_KEY" -H "Content-Type: application/json" -d '{}'
```

A successful response is JSON containing `token` beginning with `CPR1|` and `expires_in_seconds`.

Do not use the old blanket repair sequence for an existing database. For the
reported business-creation mismatch, verify `0015` prerequisites and complete
`0016_counter_inventory_modes.sql` before applying
`0021_admin_create_business_profile.sql`. For QR polling claims, apply
`0022_atomic_qr_claim.sql` before deploying the current poll function. Apply
`0023_owner_waiter_roles.sql` after the existing employee/profile functions are
present. Always inspect the remote migration ledger and catalog first; the
repository journal does not prove what reached Supabase.

`create-access-pass` requires the caller's Supabase access token. `redeem-access-pass` intentionally accepts an anonymous request, but it accepts only a random, one-time passkey and immediately consumes it. The service-role key is used only inside Edge Functions and must never be placed in either APK.

The recipient flow is now:

1. Superadmin opens an active business and creates an **Owner pass** (or scans the owner's live QR).
2. The backend creates a random passkey, stores only its SHA-256 hash, and returns the plaintext once for copying.
3. The owner opens the same app, pastes it, and taps **Sign in with passkey**.
4. The redemption function validates expiry and one-time use, creates a synthetic Auth identity, attaches it to the business with the requested role, and returns short-lived sign-in credentials to the APK.
5. Supabase Auth creates the normal access/refresh session; all later access is still controlled by business status and RLS. The owner then manages Waiter enrollment from that business workspace.

Passes expire after 24 hours and cannot be reused. A suspended or closed business cannot issue or redeem passes.

## Employee controls and working hours

Business owners can list tenant employees, suspend or terminate an employee, reactivate an employee, and set weekday working hours. Employee status is stored on `shop_members`; it is not implemented as a client-only flag. Suspended and terminated employees immediately lose tenant RLS access.

Working hours are stored in `employee_working_hours` using the business timezone (`shops.timezone`, default `Africa/Nairobi`). If an employee has no enabled schedule rows, the tenant keeps the legacy always-available behavior. Once any schedule is configured, the server checks the current local weekday/time before every sale. A database trigger rejects sales outside the configured window, so changing or modifying the APK cannot bypass the lock.

The business app's **Manage team** panel can scan a Waiter's live QR challenge, lock/reactivate the account, and save weekday hours. The platform Superadmin scanner enrolls only the selected business owner; the owner then manages Waiter enrollment.

## Application boundaries
CounterPOS currently uses one client APK with server-selected roles rather than requiring a separate superadmin APK:
- **Platform administrator**: signs in through the same client app and is routed to the Superadmin dashboard when the Auth user exists in `public.platform_admins`. This screen registers businesses and enrolls each business owner.
- **Business owner**: uses the same client app for inventory, sales, tables, Waiter enrollment, employee status, and active-hours policies.
- **Waiter**: is stored as the existing `cashier` database role so current sale permissions continue to work; the UI labels it **Waiter**. The database retains older role values for compatibility, but the current onboarding path does not offer them.

Business profiles still control feature flags. A future separate admin APK can be added without changing the backend contract, but it is not required for the current SaaS deployment.

## Tenant profiles

When registering a business, the platform administrator must choose the
canonical values below. These values are stored on `shops.business_type`,
`shops.business_size`, `shops.feature_flags`, and
`shops.counter_inventory_mode`:

| SQL value | Business label | Enabled profile behavior |
|---|---|---|
| `big_club` | Bar/Club | Tables, FIFO inventory, sales analytics, employee management, and working-hours controls |
| `counter_seller` | Liquor Store | Counter workflow, FIFO inventory, and employee management; no tables, working-hours, or sales-analytics screens |

`business_size` is exactly one of `small`, `medium`, or `large`.

### Platform-admin profile creation RPC

Use `admin_create_business_profile` for complete onboarding. It is callable by
authenticated users only and performs a server-side
`public.is_platform_admin()` check. Its exact SQL signature is:

```sql
public.admin_create_business_profile(
  _name text,
  _owner_email text DEFAULT NULL,
  _business_type text DEFAULT 'big_club',
  _business_size text DEFAULT 'medium',
  _counter_inventory_mode text DEFAULT 'shared',
  _counter_count int DEFAULT 1
) RETURNS public.shops
```

Example:

```ts
await supabase.rpc('admin_create_business_profile', {
  _name: 'Westlands Club',
  _owner_email: 'owner@client.ke',
  _business_type: 'big_club',
  _business_size: 'large',
  _counter_inventory_mode: 'per_counter',
  _counter_count: 4,
});
```

`_counter_inventory_mode` is exactly `shared` or `per_counter`.
`_counter_count` is an integer from 1 through 50 and means the total active
counter count. The RPC delegates business/profile creation to
`admin_create_business`, whose existing trigger seeds **Counter 1**; it then
updates the mode and inserts only `Counter 2` through `Counter N`. Therefore a
count of `1` preserves the default seeded Counter 1, while a count of `4`
produces Counter 1–4. The returned `public.shops` row includes the selected
profile and mode. Invalid values fail with the named `invalid_*` SQL errors;
previously deployed databases must audit schema/ledger state before applying
the forward-only `0021_admin_create_business_profile.sql` migration.

## Rotating Superadmin token

The protected Lovable web page authenticates the platform administrator normally, then calls `issue-superadmin-token` and displays a `CPSA1|...` bearer token valid for 10 minutes. Only the SHA-256 hash is stored. The Android login screen sends the token to `redeem-superadmin-token`; the server validates expiry and platform-admin membership, then returns a normal Supabase session for the platform-admin console. Business passkeys and employee QR challenges cannot redeem this token.

## Seed the first platform administrator

Create the administrator's Supabase Auth account through the normal Supabase Auth flow. After the user is confirmed, run this once from a trusted SQL/admin channel, replacing the UUID with that Auth user's ID:

```sql
insert into public.platform_admins (user_id)
values ('00000000-0000-0000-0000-000000000000')
on conflict (user_id) do nothing;
```

There is intentionally no client-callable bootstrap RPC. `platform_admins` has RLS and no client insert/update/delete grant. The unified Android app recognizes the system-issued Superadmin token and routes that account to the Superadmin dashboard; a separate admin APK is not required.

## Business lifecycle

`active` businesses are usable. `suspended` and `closed` businesses retain products, stock batches, sales, receipts, and audit events, but `is_shop_member` returns false for every owner and staff membership. The owner cannot reopen the business; a platform admin must call:

```sql
select public.admin_set_business_status(
  'business-uuid', 'active', 'Reopened after review'
);
```

## Role policy

The database retains the historical roles `owner`, `manager`, `inventory_clerk`, and `cashier`. Current onboarding is narrower: Superadmin can enroll only an `owner`, and an owner can enroll or assign only `cashier` (displayed as **Waiter**). Migration `0023_owner_waiter_roles.sql` enforces this restriction in employee RPCs; the Edge Functions enforce the same rule for QR approvals and passkeys.

## Different purchase prices

`stock_batches` stores one cost layer per receipt. `receive_stock_with_cost` creates a batch with `unit_cost`; `record_sale_unit` consumes remaining batches in `received_at, id` order and writes the exact allocation to `sale_batch_allocations`. `sales.unit_cost_total` and `sales.profit_total` are historical snapshots. `undo_sale` restores exact allocations. `products.average_cost` is a weighted-average display value only.

## Release APK

The Android release build enables R8 shrinking/obfuscation and excludes the publishable session/cache from backup. Build with a protected production keystore and CI secrets:

```bash
STORE_PASSWORD="$STORE_PASSWORD" KEY_PASSWORD="$KEY_PASSWORD" \
KEYSTORE_PATH="/secure/keystores/counterpos-upload.jks" \
./gradlew :app:assembleRelease
```

The publishable Supabase key may be in the client. A service-role key, database password, or admin credential must never be placed in `BuildConfig`, resources, assets, logs, or an APK.
