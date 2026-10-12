-- Server-backed one-time access passes.
-- Plaintext passkeys are never stored in Postgres; Edge Functions store SHA-256 hashes.

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

CREATE INDEX IF NOT EXISTS access_passes_active_idx
  ON public.access_passes(pass_hash)
  WHERE redeemed_at IS NULL AND revoked_at IS NULL;
CREATE INDEX IF NOT EXISTS access_passes_shop_idx
  ON public.access_passes(shop_id, created_at DESC);

ALTER TABLE public.access_passes ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON public.access_passes FROM anon, authenticated;
GRANT ALL ON public.access_passes TO service_role;

DROP POLICY IF EXISTS "owners read own access passes" ON public.access_passes;
CREATE POLICY "owners read own access passes" ON public.access_passes
  FOR SELECT TO authenticated
  USING (public.is_shop_manager(shop_id));

COMMENT ON TABLE public.access_passes IS
  'One-time access credentials. Only SHA-256 hashes are stored; creation and redemption happen in Supabase Edge Functions.';
