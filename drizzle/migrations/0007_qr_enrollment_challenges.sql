-- Opaque QR enrollment challenges. The QR contains only a random secret token.
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
COMMENT ON TABLE public.access_challenges IS 'Short-lived opaque QR enrollment secrets; plaintext token is never stored.';
