-- Enforce the product distinction at the database boundary, not only in UI.
-- Liquor Stores are direct retail: one shared-stock counter, no extra service counters.

CREATE OR REPLACE FUNCTION public.admin_create_business_profile(
  _name text,
  _owner_email text DEFAULT NULL,
  _business_type text DEFAULT 'big_club',
  _business_size text DEFAULT 'medium',
  _counter_inventory_mode text DEFAULT 'shared',
  _counter_count int DEFAULT 1
)
RETURNS public.shops
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  s public.shops;
  i int;
  effective_mode text := coalesce(_counter_inventory_mode, 'shared');
  effective_count int := coalesce(_counter_count, 1);
BEGIN
  IF NOT public.is_platform_admin() THEN RAISE EXCEPTION 'forbidden'; END IF;
  IF length(trim(coalesce(_name, ''))) NOT BETWEEN 1 AND 120 THEN RAISE EXCEPTION 'invalid_business_name'; END IF;
  IF _business_type IS NULL OR _business_type NOT IN ('big_club', 'counter_seller') THEN RAISE EXCEPTION 'invalid_business_type'; END IF;
  IF _business_size IS NULL OR _business_size NOT IN ('small', 'medium', 'large') THEN RAISE EXCEPTION 'invalid_business_size'; END IF;

  IF _business_type = 'counter_seller' THEN
    effective_mode := 'shared';
    effective_count := 1;
  ELSE
    IF effective_mode NOT IN ('shared', 'per_counter') THEN RAISE EXCEPTION 'invalid_counter_inventory_mode'; END IF;
    IF effective_count NOT BETWEEN 1 AND 50 THEN RAISE EXCEPTION 'invalid_counter_count'; END IF;
  END IF;

  s := public.admin_create_business(_name, _owner_email, _business_type, _business_size);
  UPDATE public.shops
  SET counter_inventory_mode = effective_mode
  WHERE id = s.id
  RETURNING * INTO s;

  -- The shop-insert trigger seeds Main Counter. Number stations only when there is more than one.
  IF effective_count > 1 THEN
    UPDATE public.service_counters
    SET name = 'Counter 1'
    WHERE shop_id = s.id AND active AND lower(trim(name)) = 'main counter';
  END IF;
  FOR i IN 2..effective_count LOOP
    INSERT INTO public.service_counters(shop_id, name, created_by)
    VALUES (s.id, 'Counter ' || i, auth.uid());
  END LOOP;

  PERFORM public.write_audit_event(
    s.id,
    'business_profile_created_by_admin',
    'shop',
    s.id,
    jsonb_build_object(
      'business_type', _business_type,
      'business_size', _business_size,
      'counter_inventory_mode', effective_mode,
      'counter_count', effective_count
    )
  );
  RETURN s;
END $$;

REVOKE EXECUTE ON FUNCTION public.admin_create_business_profile(text, text, text, text, text, int)
FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.admin_create_business_profile(text, text, text, text, text, int)
TO authenticated;

CREATE OR REPLACE FUNCTION public.create_service_counter(_shop uuid, _name text)
RETURNS public.service_counters
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE
  c public.service_counters;
  active_count int;
  normalized_name text := trim(coalesce(_name, ''));
  shop_type text;
BEGIN
  PERFORM 1 FROM public.shops WHERE id = _shop FOR UPDATE;
  IF NOT FOUND OR NOT public.is_shop_manager(_shop) THEN RAISE EXCEPTION 'forbidden'; END IF;
  SELECT business_type INTO shop_type FROM public.shops WHERE id = _shop;
  IF shop_type = 'counter_seller' THEN RAISE EXCEPTION 'liquor_store_single_counter'; END IF;
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
    IF lower(normalized_name) = 'counter 1' THEN normalized_name := 'Counter 2'; END IF;
  END IF;

  INSERT INTO public.service_counters(shop_id, name, created_by)
  VALUES (_shop, normalized_name, auth.uid())
  RETURNING * INTO c;
  PERFORM public.write_audit_event(_shop, 'counter_created', 'service_counter', c.id, jsonb_build_object('name', c.name));
  RETURN c;
END $$;

REVOKE EXECUTE ON FUNCTION public.create_service_counter(uuid,text) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.create_service_counter(uuid,text) TO authenticated;

NOTIFY pgrst, 'reload schema';
