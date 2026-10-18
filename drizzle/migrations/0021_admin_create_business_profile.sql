-- Forward-only platform-admin onboarding for a complete business profile.
-- admin_create_business() owns tenant/profile creation and the 0016 trigger seeds
-- Counter 1; this wrapper only adds Counter 2..N.
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
BEGIN
  IF NOT public.is_platform_admin() THEN
    RAISE EXCEPTION 'forbidden';
  END IF;
  IF length(trim(coalesce(_name, ''))) NOT BETWEEN 1 AND 120 THEN
    RAISE EXCEPTION 'invalid_business_name';
  END IF;
  IF _business_type IS NULL OR _business_type NOT IN ('big_club', 'counter_seller') THEN
    RAISE EXCEPTION 'invalid_business_type';
  END IF;
  IF _business_size IS NULL OR _business_size NOT IN ('small', 'medium', 'large') THEN
    RAISE EXCEPTION 'invalid_business_size';
  END IF;
  IF _counter_inventory_mode IS NULL OR _counter_inventory_mode NOT IN ('shared', 'per_counter') THEN
    RAISE EXCEPTION 'invalid_counter_inventory_mode';
  END IF;
  IF _counter_count IS NULL OR _counter_count NOT BETWEEN 1 AND 50 THEN
    RAISE EXCEPTION 'invalid_counter_count';
  END IF;

  s := public.admin_create_business(_name, _owner_email, _business_type, _business_size);

  UPDATE public.shops
  SET counter_inventory_mode = _counter_inventory_mode
  WHERE id = s.id
  RETURNING * INTO s;

  -- admin_create_business() fires seed_default_service_counter(), so Counter 1
  -- is retained and the requested count is the total number of active counters.
  FOR i IN 2.._counter_count LOOP
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
      'counter_inventory_mode', _counter_inventory_mode,
      'counter_count', _counter_count
    )
  );

  RETURN s;
END $$;

REVOKE EXECUTE ON FUNCTION public.admin_create_business_profile(text, text, text, text, text, int)
FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.admin_create_business_profile(text, text, text, text, text, int)
TO authenticated;
