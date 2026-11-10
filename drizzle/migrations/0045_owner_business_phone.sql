ALTER TABLE public.shops
  ADD COLUMN IF NOT EXISTS owner_phone text;

CREATE OR REPLACE FUNCTION public.set_owner_business_phone(_shop_id uuid, _phone text)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, public, pg_temp
AS $$
DECLARE
  normalized_phone text := regexp_replace(coalesce(_phone, ''), '[^0-9]', '', 'g');
BEGIN
  IF auth.uid() IS NULL THEN RAISE EXCEPTION 'not_authenticated'; END IF;
  IF normalized_phone !~ '^254[17][0-9]{8}$' THEN RAISE EXCEPTION 'invalid_owner_phone'; END IF;
  IF NOT public.is_platform_admin() AND NOT EXISTS (
    SELECT 1 FROM public.shop_members m
    WHERE m.shop_id = _shop_id AND m.user_id = auth.uid() AND m.role = 'owner'
  ) THEN RAISE EXCEPTION 'owner_or_platform_admin_required'; END IF;

  UPDATE public.shops SET owner_phone = normalized_phone WHERE id = _shop_id;
  IF NOT FOUND THEN RAISE EXCEPTION 'business_not_found'; END IF;
  PERFORM public.write_audit_event(
    _shop_id,
    'owner_business_phone_updated',
    'shop',
    _shop_id,
    jsonb_build_object('phone_last_four', right(normalized_phone, 4))
  );
  RETURN jsonb_build_object('success', true, 'shop_id', _shop_id);
END $$;

REVOKE ALL ON FUNCTION public.set_owner_business_phone(uuid, text) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.set_owner_business_phone(uuid, text) TO authenticated;

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
  IF auth.uid() IS NULL THEN RAISE EXCEPTION 'not_authenticated'; END IF;

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
        'owner_phone', CASE WHEN m.role = 'owner' THEN s.owner_phone ELSE NULL END,
        'counter_count', (
          SELECT count(*)::int FROM public.service_counters c
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
