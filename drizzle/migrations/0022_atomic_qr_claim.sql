-- A polling device must claim an approved QR challenge before identity/member
-- provisioning so concurrent pollers cannot both receive credentials.
ALTER TABLE public.access_challenges
  ADD COLUMN IF NOT EXISTS processing_at timestamptz;

DO $$
DECLARE c record;
BEGIN
  FOR c IN
    SELECT conname
    FROM pg_constraint
    WHERE conrelid = 'public.access_challenges'::regclass
      AND contype = 'c'
      AND pg_get_constraintdef(oid) ILIKE '%status%'
  LOOP
    EXECUTE format('ALTER TABLE public.access_challenges DROP CONSTRAINT %I', c.conname);
  END LOOP;

  ALTER TABLE public.access_challenges
    ADD CONSTRAINT access_challenges_status_check
    CHECK (status IN ('pending', 'approved', 'processing', 'consumed', 'expired', 'revoked'));
END $$;

CREATE INDEX IF NOT EXISTS access_challenges_processing_idx
  ON public.access_challenges(status, processing_at)
  WHERE status = 'processing';
