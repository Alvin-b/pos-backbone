-- Reenrolling the same phone must reuse its existing Auth identity instead
-- of creating another synthetic cp-* user for every new QR token.
ALTER TABLE public.access_challenges
  ADD COLUMN IF NOT EXISTS device_key_hash text;

CREATE INDEX IF NOT EXISTS access_challenges_device_key_idx
  ON public.access_challenges(device_key_hash, shop_id, role, status);

CREATE TABLE IF NOT EXISTS public.access_device_identities (
  device_key_hash text PRIMARY KEY,
  shop_id uuid NOT NULL REFERENCES public.shops(id) ON DELETE CASCADE,
  user_id uuid NOT NULL REFERENCES auth.users(id) ON DELETE CASCADE,
  role public.shop_role NOT NULL,
  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now(),
  UNIQUE (shop_id, user_id, role)
);

ALTER TABLE public.access_device_identities ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON public.access_device_identities FROM anon, authenticated;
GRANT ALL ON public.access_device_identities TO service_role;

NOTIFY pgrst, 'reload schema';
