-- Self-service owner onboarding. The caller's identity and ownership are always
-- derived from auth.uid() through create_shop; clients cannot choose another owner
-- or call the platform-admin-only business provisioning RPC.
CREATE OR REPLACE FUNCTION public.create_owner_business_profile(
  _name text,
  _business_type text DEFAULT 'big_club',
  _business_size text DEFAULT 'medium',
  _counter_inventory_mode text DEFAULT 'shared',
  _counter_count int DEFAULT 1
)
RETURNS public.shops
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, public, pg_temp
AS $$
DECLARE
  s public.shops;
  existing_shop public.shops;
  flags jsonb;
  i int;
BEGIN
  IF auth.uid() IS NULL THEN
    RAISE EXCEPTION 'not_authenticated';
  END IF;
  IF coalesce(length(trim(_name)), 0) NOT BETWEEN 1 AND 120 THEN
    RAISE EXCEPTION 'invalid_business_name';
  END IF;
  IF _business_type IS NULL OR _business_type NOT IN ('big_club', 'counter_seller') THEN
    RAISE EXCEPTION 'invalid_business_type';
  END IF;

  -- Retail stores use one shared-stock counter and do not expose club-only
  -- sizing, table, working-hours, or analytics features.
  IF _business_type = 'counter_seller' THEN
    _business_size := 'medium';
    _counter_inventory_mode := 'shared';
    _counter_count := 1;
  ELSE
    IF _business_size IS NULL OR _business_size NOT IN ('small', 'medium', 'large') THEN
      RAISE EXCEPTION 'invalid_business_size';
    END IF;
    IF _counter_inventory_mode IS NULL OR _counter_inventory_mode NOT IN ('shared', 'per_counter') THEN
      RAISE EXCEPTION 'invalid_counter_inventory_mode';
    END IF;
    IF _counter_count IS NULL OR _counter_count NOT BETWEEN 1 AND 50 THEN
      RAISE EXCEPTION 'invalid_counter_count';
    END IF;
  END IF;

  flags := CASE _business_type
    WHEN 'big_club' THEN '{"tables":true,"employee_management":true,"working_hours":true,"fifo_inventory":true,"sales_analytics":true}'::jsonb
    ELSE '{"tables":false,"employee_management":true,"working_hours":false,"fifo_inventory":true,"sales_analytics":false}'::jsonb
  END;

  -- Serialize retries for the same signed-in owner and business name. If a
  -- previous request committed but its response was lost, return that profile.
  PERFORM pg_advisory_xact_lock(
    hashtextextended(auth.uid()::text || ':' || lower(trim(_name)), 0)
  );
  SELECT sh.* INTO existing_shop
  FROM public.shops sh
  JOIN public.shop_members m ON m.shop_id = sh.id
  WHERE m.user_id = auth.uid()
    AND m.role = 'owner'
    AND lower(sh.name) = lower(trim(_name))
  ORDER BY sh.created_at DESC
  LIMIT 1
  FOR UPDATE OF sh;
  IF existing_shop.id IS NOT NULL THEN
    IF existing_shop.business_type = _business_type
      AND existing_shop.business_size = _business_size
      AND existing_shop.counter_inventory_mode = _counter_inventory_mode
      AND (SELECT count(*) FROM public.service_counters c WHERE c.shop_id = existing_shop.id AND c.active) = _counter_count THEN
      RETURN existing_shop;
    END IF;
    RAISE EXCEPTION 'business_name_already_exists';
  END IF;

  -- create_shop validates the authenticated caller and atomically creates an
  -- active shop plus that same caller's owner membership and audit event.
  s := public.create_shop(trim(_name));

  UPDATE public.shops
  SET business_type = _business_type,
      business_size = _business_size,
      feature_flags = flags,
      counter_inventory_mode = _counter_inventory_mode
  WHERE id = s.id
    AND EXISTS (
      SELECT 1 FROM public.shop_members m
      WHERE m.shop_id = s.id AND m.user_id = auth.uid() AND m.role = 'owner'
    )
  RETURNING * INTO s;
  IF s.id IS NULL THEN
    RAISE EXCEPTION 'owner_business_profile_not_created';
  END IF;

  IF _counter_count > 1 THEN
    UPDATE public.service_counters
    SET name = 'Counter 1'
    WHERE shop_id = s.id
      AND active
      AND lower(trim(name)) = 'main counter';
    FOR i IN 2.._counter_count LOOP
      INSERT INTO public.service_counters(shop_id, name, created_by)
      VALUES (s.id, 'Counter ' || i, auth.uid());
    END LOOP;
  END IF;

  PERFORM public.write_audit_event(
    s.id,
    'business_profile_created_by_owner',
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

REVOKE ALL ON FUNCTION public.create_owner_business_profile(text, text, text, text, int)
FROM PUBLIC;
REVOKE EXECUTE ON FUNCTION public.create_owner_business_profile(text, text, text, text, int)
FROM anon;
GRANT EXECUTE ON FUNCTION public.create_owner_business_profile(text, text, text, text, int)
TO authenticated;

-- Return the configured active counter count in the account bootstrap. Older
-- Android clients consume this field, while the backend keeps counter inventory
-- canonical in service_counters rather than trusting a duplicated shops column.
CREATE OR REPLACE FUNCTION public.my_account()
RETURNS json
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = pg_catalog, public, pg_temp
AS $$
DECLARE
  result json;
BEGIN
  IF auth.uid() IS NULL THEN
    RAISE EXCEPTION 'not_authenticated';
  END IF;

  SELECT json_build_object(
    'user_id', auth.uid(),
    'email', (SELECT u.email FROM auth.users u WHERE u.id = auth.uid()),
    'is_platform_admin', public.is_platform_admin(),
    'memberships', coalesce((
      SELECT json_agg(json_build_object(
        'shop_id', m.shop_id,
        'shop_name', s.name,
        'role', m.role,
        'status', s.status,
        'employment_status', m.employment_status,
        'business_type', s.business_type,
        'business_size', s.business_size,
        'feature_flags', s.feature_flags,
        'currency', s.currency,
        'low_stock_threshold', s.low_stock_threshold,
        'counter_inventory_mode', s.counter_inventory_mode,
        'counter_count', (
          SELECT count(*)::int
          FROM public.service_counters c
          WHERE c.shop_id = s.id AND c.active
        )
      ) ORDER BY s.created_at DESC)
      FROM public.shop_members m
      JOIN public.shops s ON s.id = m.shop_id
      WHERE m.user_id = auth.uid()
    ), '[]'::json)
  ) INTO result;
  RETURN result;
END $$;

REVOKE ALL ON FUNCTION public.my_account() FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.my_account() TO authenticated;
NOTIFY pgrst, 'reload schema';
