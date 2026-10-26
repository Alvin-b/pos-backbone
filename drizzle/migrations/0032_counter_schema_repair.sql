-- Forward repair for databases where counter migrations were applied out of order.
-- This column is required by the counter inventory functions and is nullable so
-- existing sales remain assigned to the Unassigned counter.
CREATE TABLE IF NOT EXISTS public.service_counters (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  shop_id uuid NOT NULL REFERENCES public.shops(id) ON DELETE CASCADE,
  name text NOT NULL CHECK (length(trim(name)) BETWEEN 1 AND 60),
  active boolean NOT NULL DEFAULT true,
  created_by uuid NOT NULL,
  created_at timestamptz NOT NULL DEFAULT now(),
  UNIQUE (shop_id, name)
);

ALTER TABLE public.sales
  ADD COLUMN IF NOT EXISTS source_counter_id uuid
  REFERENCES public.service_counters(id) ON DELETE SET NULL;

CREATE INDEX IF NOT EXISTS sales_source_counter_time_idx
  ON public.sales(source_counter_id, created_at DESC)
  WHERE source_counter_id IS NOT NULL;
