-- Counter POS / Lovable Supabase setup
-- Run this in the Lovable project's Supabase SQL Editor.
-- This script is safe to run repeatedly.
-- IMPORTANT: create and confirm the administrator in Supabase Auth first,
-- then replace the email below with that exact address.

BEGIN;

-- Repair employee/business-profile columns and the server-side access controls.
-- This is the idempotent repair migration shipped with the backend.
ALTER TABLE public.shops
  ADD COLUMN IF NOT EXISTS timezone text NOT NULL DEFAULT 'Africa/Nairobi',
  ADD COLUMN IF NOT EXISTS business_type text NOT NULL DEFAULT 'big_club',
  ADD COLUMN IF NOT EXISTS business_size text NOT NULL DEFAULT 'medium',
  ADD COLUMN IF NOT EXISTS feature_flags jsonb NOT NULL DEFAULT '{"tables":true,"employee_management":true,"working_hours":true,"fifo_inventory":true,"sales_analytics":true}'::jsonb;

ALTER TABLE public.shop_members
  ADD COLUMN IF NOT EXISTS employment_status text NOT NULL DEFAULT 'active',
  ADD COLUMN IF NOT EXISTS status_reason text,
  ADD COLUMN IF NOT EXISTS status_changed_at timestamptz,
  ADD COLUMN IF NOT EXISTS status_changed_by uuid;

UPDATE public.shop_members SET employment_status = 'active' WHERE employment_status IS NULL;

DO $$
BEGIN
  IF NOT EXISTS (
    SELECT 1 FROM pg_constraint WHERE conname = 'shop_members_employment_status_check'
  ) THEN
    ALTER TABLE public.shop_members ADD CONSTRAINT shop_members_employment_status_check
      CHECK (employment_status IN ('active', 'suspended', 'terminated'));
  END IF;
END $$;

CREATE TABLE IF NOT EXISTS public.employee_working_hours (
  shop_id uuid NOT NULL REFERENCES public.shops(id) ON DELETE CASCADE,
  user_id uuid NOT NULL,
  weekday smallint NOT NULL CHECK (weekday BETWEEN 0 AND 6),
  start_time time NOT NULL,
  end_time time NOT NULL,
  enabled boolean NOT NULL DEFAULT true,
  updated_at timestamptz NOT NULL DEFAULT now(),
  updated_by uuid,
  PRIMARY KEY (shop_id, user_id, weekday)
);

ALTER TABLE public.employee_working_hours ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON public.employee_working_hours FROM anon, authenticated;
GRANT ALL ON public.employee_working_hours TO service_role;

-- Ensure the platform-admin table exists before assigning the first admin.
CREATE TABLE IF NOT EXISTS public.platform_admins (
  user_id uuid PRIMARY KEY,
  created_at timestamptz NOT NULL DEFAULT now(),
  created_by uuid
);
ALTER TABLE public.platform_admins ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON public.platform_admins FROM anon, authenticated;
GRANT ALL ON public.platform_admins TO service_role;

CREATE TABLE IF NOT EXISTS public.platform_admin_tokens (
  singleton boolean PRIMARY KEY DEFAULT true CHECK (singleton),
  token_hash text NOT NULL,
  auth_user_id uuid NOT NULL REFERENCES auth.users(id) ON DELETE CASCADE,
  issued_at timestamptz NOT NULL DEFAULT now(),
  expires_at timestamptz NOT NULL,
  issued_by uuid REFERENCES auth.users(id),
  last_redeemed_at timestamptz
);
ALTER TABLE public.platform_admin_tokens ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON public.platform_admin_tokens FROM anon, authenticated;
GRANT ALL ON public.platform_admin_tokens TO service_role;

CREATE TABLE IF NOT EXISTS public.access_passes (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  shop_id uuid NOT NULL REFERENCES public.shops(id) ON DELETE CASCADE,
  role public.shop_role NOT NULL CHECK (role IN ('owner', 'manager', 'inventory_clerk', 'cashier')),
  pass_hash text NOT NULL UNIQUE,
  created_by uuid NOT NULL,
  created_at timestamptz NOT NULL DEFAULT now(),
  expires_at timestamptz NOT NULL DEFAULT (now() + interval '24 hours'),
  redeemed_at timestamptz,
  redeemed_by uuid,
  revoked_at timestamptz
);
CREATE INDEX IF NOT EXISTS access_passes_active_idx ON public.access_passes(pass_hash) WHERE redeemed_at IS NULL AND revoked_at IS NULL;
ALTER TABLE public.access_passes ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON public.access_passes FROM anon, authenticated;
GRANT ALL ON public.access_passes TO service_role;

CREATE TABLE IF NOT EXISTS public.access_challenges (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  token_hash text NOT NULL UNIQUE,
  status text NOT NULL DEFAULT 'pending' CHECK (status IN ('pending', 'approved', 'consumed', 'expired', 'revoked')),
  shop_id uuid REFERENCES public.shops(id) ON DELETE CASCADE,
  role public.shop_role,
  created_at timestamptz NOT NULL DEFAULT now(),
  expires_at timestamptz NOT NULL DEFAULT (now() + interval '10 minutes'),
  approved_at timestamptz,
  approved_by uuid,
  consumed_at timestamptz,
  consumed_by uuid
);
CREATE INDEX IF NOT EXISTS access_challenges_pending_idx ON public.access_challenges(token_hash, status, expires_at);
ALTER TABLE public.access_challenges ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON public.access_challenges FROM anon, authenticated;
GRANT ALL ON public.access_challenges TO service_role;

-- Register the first platform administrator.
-- Replace the email value before running this block.
DO $$
DECLARE
  v_admin_email text := lower(trim('REPLACE_WITH_ADMIN_EMAIL'));
  v_admin_id uuid;
BEGIN
  IF v_admin_email = 'replace_with_admin_email' THEN
    RAISE EXCEPTION 'Replace REPLACE_WITH_ADMIN_EMAIL with the confirmed Supabase Auth email before running this script';
  END IF;

  SELECT id INTO v_admin_id
  FROM auth.users
  WHERE lower(email) = v_admin_email
  LIMIT 1;

  IF v_admin_id IS NULL THEN
    RAISE EXCEPTION 'No confirmed Auth user found for %', v_admin_email;
  END IF;

  INSERT INTO public.platform_admins(user_id)
  VALUES (v_admin_id)
  ON CONFLICT (user_id) DO NOTHING;
END $$;

COMMIT;

-- Verification: this should return the administrator email and true.
SELECT
  u.id AS user_id,
  u.email,
  EXISTS (
    SELECT 1 FROM public.platform_admins pa WHERE pa.user_id = u.id
  ) AS is_platform_admin
FROM auth.users u
WHERE lower(u.email) = lower('REPLACE_WITH_ADMIN_EMAIL');
