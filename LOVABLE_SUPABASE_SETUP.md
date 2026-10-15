# Counter POS setup in Lovable Cloud

The project does **not** require a separate superadmin APK. The existing client APK routes a signed-in platform administrator to `AdminConsoleScreen` when that Auth user exists in `public.platform_admins`.

The current QR error means the database may be connected, but the Supabase Edge Function endpoint is not deployed in the Lovable project's Supabase environment.

## 1. Connect the Lovable project to Supabase

In Lovable, open the project’s **Integrations / Cloud / Supabase** settings and make sure the project is connected to the Supabase project whose URL is:

```text
https://pvcqfoycrqtnirbwtccm.supabase.co
```

Do not put a service-role key in the Android app, Lovable frontend, GitHub, or chat.

## 2. Apply the SQL setup

Open the Lovable project’s Supabase **SQL Editor**.

1. Create and confirm the platform administrator in Supabase Auth.
2. Open [`supabase/lovable/setup_admin.sql`](supabase/lovable/setup_admin.sql).
3. Replace `REPLACE_WITH_ADMIN_EMAIL` in both places with the exact confirmed Auth email.
4. Run the complete script.
5. The final query must return the email with `is_platform_admin = true`.

This script repairs the employee/business-profile fields, creates the required working-hours and platform-admin tables if missing, and registers the admin account.

If the project is a completely empty Supabase database rather than the existing Lovable database, apply the base migrations in `drizzle/migrations` first, in dependency order. The SQL script is an idempotent repair/bootstrap script, not a replacement for the base schema.

## 3. Deploy the Edge Functions through Lovable

The source is already in the repository under `supabase/functions/`:

- `create-access-challenge`
- `approve-access-challenge`
- `poll-access-challenge`
- `create-access-pass`
- `redeem-access-pass`

In Lovable, use this prompt in the project editor:

> Deploy the Supabase Edge Functions from `supabase/functions` to the connected Supabase project. Deploy `create-access-challenge` with JWT verification disabled, `poll-access-challenge` with JWT verification disabled, and `redeem-access-pass` with JWT verification disabled. Deploy `approve-access-challenge` and `create-access-pass` with JWT verification enabled. Ensure the functions have the Supabase service-role secret available server-side. Do not expose or copy the service-role key into frontend code, Android code, logs, or client-visible environment variables. Verify all five function routes with a POST smoke test.

If Lovable exposes a function deployment panel, deploy the five folders with the same JWT settings above. The function source must remain server-side and must use the existing `_shared/access.ts` helper.

## 4. Verify the missing function

From any terminal with network access, verify the public endpoint using only the publishable key:

```bash
curl -i -X POST \
  'https://pvcqfoycrqtnirbwtccm.supabase.co/functions/v1/create-access-challenge' \
  -H 'apikey: YOUR_SUPABASE_PUBLISHABLE_KEY' \
  -H 'Content-Type: application/json' \
  --data '{}'
```

A successful response is JSON similar to:

```json
{"token":"CPR1|...","expires_in_seconds":600}
```

A `404` means the function is still not deployed. A `500` mentioning `access_challenges` means the SQL schema has not been applied.

## 5. Sign in as the superadmin

There is no separate superadmin app required:

1. Install/open the current Counter POS client app.
2. Sign in with the confirmed Auth email and password used in step 2.
3. The app reads `my_account()`.
4. Because the account is in `public.platform_admins`, it opens the **Platform Admin** console.
5. From there the administrator can register businesses, issue owner access, open a business profile, approve enrollment QR codes, and suspend/reopen/close businesses.

Business owners and employees use the same client app with their own memberships and passkeys. Their screens are selected from their server-side role and business profile.

## 6. Owner and employee flow

- Platform admin creates a business and issues an owner passkey.
- Owner pastes the one-time passkey into the client app.
- Owner opens **Manage team** and issues a cashier or stock-clerk passkey.
- Employee signs in with the passkey or displays a secure QR challenge.
- Owner scans and approves the employee QR.
- Owner can suspend/reactivate the employee and configure working hours.
- The database blocks sales for suspended employees and outside configured hours.
