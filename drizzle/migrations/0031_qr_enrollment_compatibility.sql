-- The atomic QR poller uses a short processing lease. Keep this migration
-- idempotent so older live databases can be upgraded safely.
ALTER TABLE public.access_challenges
  ADD COLUMN IF NOT EXISTS processing_at timestamptz;

CREATE INDEX IF NOT EXISTS access_challenges_processing_idx
  ON public.access_challenges(status, processing_at);
