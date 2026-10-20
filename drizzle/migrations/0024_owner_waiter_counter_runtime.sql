-- Owner/waiter runtime hardening and counter naming.
-- A business with one service counter is not presented as "Counter 1". Numbered
-- labels are reserved for actual multi-counter businesses.

UPDATE public.service_counters c
SET name = 'Main Counter'
WHERE c.active
  AND lower(trim(c.name)) = 'counter 1'
  AND (SELECT count(*) FROM public.service_counters active
       WHERE active.shop_id = c.shop_id AND active.active) = 1
  AND NOT EXISTS (
    SELECT 1 FROM public.service_counters existing
    WHERE existing.shop_id = c.shop_id AND existing.id <> c.id
      AND lower(trim(existing.name)) = 'main counter'
  );

CREATE OR REPLACE FUNCTION public.seed_default_service_counter()
RETURNS trigger
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
BEGIN
  INSERT INTO public.service_counters(shop_id, name, created_by)
  VALUES (NEW.id, 'Main Counter', NEW.created_by)
  ON CONFLICT (shop_id, name) DO NOTHING;
  RETURN NEW;
END $$;

-- If a business adds a second physical counter, rename the existing lone default
-- only then. The newly-created counter keeps the explicit name supplied by its owner.
CREATE OR REPLACE FUNCTION public.create_service_counter(_shop uuid, _name text)
RETURNS public.service_counters
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE
  c public.service_counters;
  active_count int;
  normalized_name text := trim(coalesce(_name, ''));
BEGIN
  PERFORM 1 FROM public.shops WHERE id = _shop FOR UPDATE;
  IF NOT FOUND OR NOT public.is_shop_manager(_shop) THEN RAISE EXCEPTION 'forbidden'; END IF;
  IF length(normalized_name) NOT BETWEEN 1 AND 60 THEN RAISE EXCEPTION 'invalid_counter_name'; END IF;

  SELECT count(*) INTO active_count FROM public.service_counters
  WHERE shop_id = _shop AND active;

  IF active_count = 0 AND lower(normalized_name) = 'counter 1' THEN
    normalized_name := 'Main Counter';
  ELSIF active_count = 1 THEN
    UPDATE public.service_counters AS existing_default
    SET name = 'Counter 1'
    WHERE existing_default.shop_id = _shop AND existing_default.active
      AND lower(trim(existing_default.name)) = 'main counter'
      AND NOT EXISTS (
        SELECT 1 FROM public.service_counters used_name
        WHERE used_name.shop_id = _shop AND used_name.id <> existing_default.id
          AND lower(trim(used_name.name)) = 'counter 1'
      );
    IF lower(normalized_name) = 'counter 1' THEN
      normalized_name := 'Counter 2';
    END IF;
  END IF;

  INSERT INTO public.service_counters(shop_id, name, created_by)
  VALUES (_shop, normalized_name, auth.uid())
  RETURNING * INTO c;
  PERFORM public.write_audit_event(_shop, 'counter_created', 'service_counter', c.id,
    jsonb_build_object('name', c.name));
  RETURN c;
END $$;

-- Apply the requested count consistently for both legacy and current admin onboarding.
CREATE OR REPLACE FUNCTION public.admin_create_business_with_counter_setup(
  _name text,
  _owner_email text DEFAULT NULL,
  _counter_inventory_mode text DEFAULT 'shared',
  _counter_count int DEFAULT 1
)
RETURNS public.shops
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE s public.shops; i int;
BEGIN
  IF NOT public.is_platform_admin() THEN RAISE EXCEPTION 'forbidden'; END IF;
  IF _counter_inventory_mode NOT IN ('shared', 'per_counter') THEN RAISE EXCEPTION 'invalid_counter_inventory_mode'; END IF;
  IF _counter_count IS NULL OR _counter_count NOT BETWEEN 1 AND 50 THEN RAISE EXCEPTION 'invalid_counter_count'; END IF;
  s := public.admin_create_business(_name, _owner_email);
  UPDATE public.shops SET counter_inventory_mode = _counter_inventory_mode
  WHERE id = s.id RETURNING * INTO s;
  IF _counter_count > 1 THEN
    UPDATE public.service_counters SET name = 'Counter 1'
    WHERE shop_id = s.id AND active AND lower(trim(name)) = 'main counter';
  END IF;
  FOR i IN 2.._counter_count LOOP
    INSERT INTO public.service_counters(shop_id, name, created_by)
    VALUES (s.id, 'Counter ' || i, auth.uid());
  END LOOP;
  PERFORM public.write_audit_event(s.id, 'counter_inventory_setup', 'shop', s.id,
    jsonb_build_object('mode', _counter_inventory_mode, 'counter_count', _counter_count));
  RETURN s;
END $$;

CREATE OR REPLACE FUNCTION public.admin_create_business_profile(
  _name text,
  _owner_email text DEFAULT NULL,
  _business_type text DEFAULT 'big_club',
  _business_size text DEFAULT 'medium',
  _counter_inventory_mode text DEFAULT 'shared',
  _counter_count int DEFAULT 1
)
RETURNS public.shops
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE s public.shops; i int;
BEGIN
  IF NOT public.is_platform_admin() THEN RAISE EXCEPTION 'forbidden'; END IF;
  IF length(trim(coalesce(_name, ''))) NOT BETWEEN 1 AND 120 THEN RAISE EXCEPTION 'invalid_business_name'; END IF;
  IF _business_type IS NULL OR _business_type NOT IN ('big_club', 'counter_seller') THEN RAISE EXCEPTION 'invalid_business_type'; END IF;
  IF _business_size IS NULL OR _business_size NOT IN ('small', 'medium', 'large') THEN RAISE EXCEPTION 'invalid_business_size'; END IF;
  IF _counter_inventory_mode IS NULL OR _counter_inventory_mode NOT IN ('shared', 'per_counter') THEN RAISE EXCEPTION 'invalid_counter_inventory_mode'; END IF;
  IF _counter_count IS NULL OR _counter_count NOT BETWEEN 1 AND 50 THEN RAISE EXCEPTION 'invalid_counter_count'; END IF;

  s := public.admin_create_business(_name, _owner_email, _business_type, _business_size);
  UPDATE public.shops SET counter_inventory_mode = _counter_inventory_mode
  WHERE id = s.id RETURNING * INTO s;
  IF _counter_count > 1 THEN
    UPDATE public.service_counters SET name = 'Counter 1'
    WHERE shop_id = s.id AND active AND lower(trim(name)) = 'main counter';
  END IF;
  FOR i IN 2.._counter_count LOOP
    INSERT INTO public.service_counters(shop_id, name, created_by)
    VALUES (s.id, 'Counter ' || i, auth.uid());
  END LOOP;
  PERFORM public.write_audit_event(s.id, 'business_profile_created_by_admin', 'shop', s.id,
    jsonb_build_object('business_type', _business_type, 'business_size', _business_size,
      'counter_inventory_mode', _counter_inventory_mode, 'counter_count', _counter_count));
  RETURN s;
END $$;

-- Correct overnight shifts by checking the previous weekday's schedule after midnight.
CREATE OR REPLACE FUNCTION public.can_sell_for_shop(_shop uuid)
RETURNS boolean
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = public AS $$
DECLARE
  tz text;
  local_now timestamp;
  dow int;
  current_time_value time;
  schedule_count int;
BEGIN
  IF NOT public.is_shop_member(_shop) THEN RETURN false; END IF;
  SELECT timezone INTO tz FROM public.shops WHERE id = _shop;
  local_now := now() AT TIME ZONE coalesce(nullif(tz, ''), 'Africa/Nairobi');
  dow := extract(dow FROM local_now)::int;
  current_time_value := local_now::time;

  SELECT count(*) INTO schedule_count
  FROM public.employee_working_hours
  WHERE shop_id = _shop AND user_id = auth.uid() AND enabled;
  IF schedule_count = 0 THEN RETURN true; END IF;

  RETURN EXISTS (
    SELECT 1 FROM public.employee_working_hours h
    WHERE h.shop_id = _shop AND h.user_id = auth.uid() AND h.weekday = dow AND h.enabled
      AND (
        h.start_time = h.end_time
        OR (h.start_time < h.end_time AND current_time_value >= h.start_time AND current_time_value < h.end_time)
        OR (h.start_time > h.end_time AND current_time_value >= h.start_time)
      )
  ) OR EXISTS (
    SELECT 1 FROM public.employee_working_hours previous_day
    WHERE previous_day.shop_id = _shop AND previous_day.user_id = auth.uid()
      AND previous_day.weekday = (dow + 6) % 7 AND previous_day.enabled
      AND previous_day.start_time > previous_day.end_time
      AND current_time_value < previous_day.end_time
  );
END $$;

GRANT EXECUTE ON FUNCTION public.can_sell_for_shop(uuid),
  public.create_service_counter(uuid, text),
  public.admin_create_business_with_counter_setup(text, text, text, int),
  public.admin_create_business_profile(text, text, text, text, text, int)
TO authenticated;

REVOKE EXECUTE ON FUNCTION public.seed_default_service_counter(),
  public.can_sell_for_shop(uuid),
  public.admin_create_business_with_counter_setup(text, text, text, int),
  public.admin_create_business_profile(text, text, text, text, text, int)
FROM PUBLIC, anon;
