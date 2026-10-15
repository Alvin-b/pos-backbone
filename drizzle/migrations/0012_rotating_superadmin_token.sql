-- Rotating platform-admin bearer token used only for Superadmin entry.
-- The plaintext token is never stored in PostgreSQL.
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

COMMENT ON TABLE public.platform_admin_tokens IS 'Single short-lived Superadmin bearer token; only its SHA-256 hash is stored.';
