-- Preserve the enrollment station selected by the business owner.
-- Both stations use the cashier shop role, butchery needs a separate marker
-- so the enrolled device can open the correct workspace after QR approval.
ALTER TABLE public.access_challenges
  ADD COLUMN IF NOT EXISTS station text;

UPDATE public.access_challenges
SET station = 'waiter'
WHERE station IS NULL
  AND role = 'cashier';

ALTER TABLE public.access_challenges
  DROP CONSTRAINT IF EXISTS access_challenges_station_check;

ALTER TABLE public.access_challenges
  ADD CONSTRAINT access_challenges_station_check
  CHECK (station IS NULL OR station IN ('waiter', 'butchery'));

CREATE INDEX IF NOT EXISTS access_challenges_station_idx
  ON public.access_challenges(shop_id, station, status);

NOTIFY pgrst, 'reload schema';
