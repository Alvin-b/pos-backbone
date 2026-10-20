-- Business-wide opening hours are distinct from each employee's personal duty schedule.
-- The explicit enforcement flag distinguishes unrestricted access from an enabled all-closed schedule.
ALTER TABLE public.shops
  ADD COLUMN IF NOT EXISTS business_hours_enabled boolean NOT NULL DEFAULT false;

CREATE TABLE IF NOT EXISTS public.shop_business_hours (
  shop_id uuid NOT NULL REFERENCES public.shops(id) ON DELETE CASCADE,
  weekday smallint NOT NULL CHECK (weekday BETWEEN 0 AND 6),
  open_time time NOT NULL,
  close_time time NOT NULL,
  enabled boolean NOT NULL DEFAULT false,
  updated_at timestamptz NOT NULL DEFAULT now(),
  updated_by uuid,
  PRIMARY KEY (shop_id, weekday)
);

CREATE INDEX IF NOT EXISTS shop_business_hours_enabled_idx
  ON public.shop_business_hours(shop_id, weekday) WHERE enabled;

ALTER TABLE public.shop_business_hours ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON public.shop_business_hours FROM PUBLIC, anon, authenticated;
GRANT ALL ON public.shop_business_hours TO service_role;

CREATE OR REPLACE FUNCTION public.get_business_hours(_shop uuid)
RETURNS jsonb
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = public AS $$
DECLARE
  business_timezone text;
  hours_enforced boolean;
  days_json jsonb;
BEGIN
  IF NOT public.is_shop_member(_shop) THEN RAISE EXCEPTION 'forbidden'; END IF;

  SELECT coalesce(nullif(timezone, ''), 'Africa/Nairobi'), business_hours_enabled
    INTO business_timezone, hours_enforced
  FROM public.shops WHERE id = _shop;

  SELECT coalesce(jsonb_agg(
    jsonb_build_object(
      'weekday', weekday,
      'open_time', to_char(open_time, 'HH24:MI'),
      'close_time', to_char(close_time, 'HH24:MI'),
      'enabled', enabled
    ) ORDER BY weekday
  ), '[]'::jsonb) INTO days_json
  FROM public.shop_business_hours WHERE shop_id = _shop;

  RETURN jsonb_build_object(
    'is_enabled', coalesce(hours_enforced, false),
    'timezone', coalesce(business_timezone, 'Africa/Nairobi'),
    'days', coalesce(days_json, '[]'::jsonb)
  );
END $$;

CREATE OR REPLACE FUNCTION public.set_business_hours(_shop uuid, _enabled boolean, _days jsonb)
RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE
  row_count int;
BEGIN
  IF NOT public.is_shop_member(_shop) OR NOT EXISTS (
    SELECT 1 FROM public.shop_members
    WHERE shop_id = _shop AND user_id = auth.uid() AND role = 'owner'
  ) THEN RAISE EXCEPTION 'forbidden'; END IF;

  IF _enabled IS NULL OR _days IS NULL OR jsonb_typeof(_days) <> 'array' THEN RAISE EXCEPTION 'invalid_business_hours'; END IF;
  row_count := jsonb_array_length(_days);
  IF row_count NOT IN (0, 7) THEN RAISE EXCEPTION 'business_hours_requires_seven_days'; END IF;

  IF EXISTS (
    SELECT 1
    FROM jsonb_array_elements(_days) AS item(value)
    WHERE jsonb_typeof(item.value) <> 'object'
      OR coalesce(item.value->>'weekday', '') !~ '^[0-6]$'
      OR coalesce(jsonb_typeof(item.value->'enabled'), '') <> 'boolean'
      OR coalesce(item.value->>'open_time', '') !~ '^(?:[01][0-9]|2[0-3]):[0-5][0-9]$'
      OR coalesce(item.value->>'close_time', '') !~ '^(?:[01][0-9]|2[0-3]):[0-5][0-9]$'
      OR (item.value->>'enabled') = 'true'
        AND item.value->>'open_time' = item.value->>'close_time'
  ) THEN RAISE EXCEPTION 'invalid_business_hours'; END IF;

  IF EXISTS (
    SELECT 1 FROM jsonb_array_elements(_days) AS item(value)
    GROUP BY item.value->>'weekday' HAVING count(*) > 1
  ) THEN RAISE EXCEPTION 'duplicate_business_hours_weekday'; END IF;

  DELETE FROM public.shop_business_hours WHERE shop_id = _shop;
  INSERT INTO public.shop_business_hours(shop_id, weekday, open_time, close_time, enabled, updated_by)
  SELECT _shop,
         (item.value->>'weekday')::smallint,
         (item.value->>'open_time')::time,
         (item.value->>'close_time')::time,
         (item.value->>'enabled')::boolean,
         auth.uid()
  FROM jsonb_array_elements(_days) AS item(value);

  UPDATE public.shops SET business_hours_enabled = _enabled WHERE id = _shop;
  RETURN public.get_business_hours(_shop);
END $$;

-- Apply both the business-wide opening window and the authenticated employee's individual shift.
-- Time boundaries are [open, close); overnight windows continue into the following weekday.
CREATE OR REPLACE FUNCTION public.can_sell_for_shop(_shop uuid)
RETURNS boolean
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = public AS $$
DECLARE
  business_timezone text;
  hours_enforced boolean;
  local_now timestamp;
  dow int;
  current_time_value time;
  employee_schedule_count int;
BEGIN
  IF NOT public.is_shop_member(_shop) THEN RETURN false; END IF;

  SELECT coalesce(nullif(timezone, ''), 'Africa/Nairobi'), business_hours_enabled
    INTO business_timezone, hours_enforced
  FROM public.shops WHERE id = _shop;
  local_now := now() AT TIME ZONE coalesce(business_timezone, 'Africa/Nairobi');
  dow := extract(dow FROM local_now)::int;
  current_time_value := local_now::time;

  IF coalesce(hours_enforced, false) AND NOT EXISTS (
    SELECT 1 FROM public.shop_business_hours h
    WHERE h.shop_id = _shop AND h.enabled AND (
      (h.weekday = dow AND (
        (h.open_time < h.close_time AND current_time_value >= h.open_time AND current_time_value < h.close_time)
        OR (h.open_time > h.close_time AND current_time_value >= h.open_time)
      ))
      OR (h.weekday = ((dow + 6) % 7) AND h.open_time > h.close_time AND current_time_value < h.close_time)
    )
  ) THEN RETURN false; END IF;

  SELECT count(*) INTO employee_schedule_count
  FROM public.employee_working_hours
  WHERE shop_id = _shop AND user_id = auth.uid() AND enabled;
  IF employee_schedule_count = 0 THEN RETURN true; END IF;

  RETURN EXISTS (
    SELECT 1 FROM public.employee_working_hours h
    WHERE h.shop_id = _shop AND h.user_id = auth.uid() AND h.enabled AND (
      (h.weekday = dow AND (
        (h.start_time < h.end_time AND current_time_value >= h.start_time AND current_time_value < h.end_time)
        OR (h.start_time > h.end_time AND current_time_value >= h.start_time)
      ))
      OR (h.weekday = ((dow + 6) % 7) AND h.start_time > h.end_time AND current_time_value < h.end_time)
    )
  );
END $$;

REVOKE EXECUTE ON FUNCTION public.get_business_hours(uuid), public.set_business_hours(uuid, boolean, jsonb), public.can_sell_for_shop(uuid) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.get_business_hours(uuid), public.set_business_hours(uuid, boolean, jsonb), public.can_sell_for_shop(uuid) TO authenticated;
