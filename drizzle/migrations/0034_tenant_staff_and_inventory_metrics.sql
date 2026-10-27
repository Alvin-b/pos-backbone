-- Repair tenant metrics and staff isolation for databases where the earlier
-- platform-admin exclusion migration was present in the repository but was not
-- applied through the Drizzle journal.
DELETE FROM public.shop_members sm
USING public.platform_admins pa
WHERE pa.user_id = sm.user_id;

DROP FUNCTION IF EXISTS public.admin_list_businesses();
CREATE FUNCTION public.admin_list_businesses()
RETURNS TABLE(
  shop_id uuid, shop_name text, status text, business_type text, business_size text, feature_flags jsonb,
  owner_email text, member_count bigint, product_count bigint, stock_units bigint,
  created_at timestamptz, suspended_at timestamptz, closed_at timestamptz, lifecycle_reason text,
  counter_inventory_mode text, counter_count bigint
)
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
BEGIN
  IF NOT public.is_platform_admin() THEN RAISE EXCEPTION 'forbidden'; END IF;
  RETURN QUERY
  SELECT
    s.id::uuid,
    s.name::text,
    s.status::text,
    s.business_type::text,
    s.business_size::text,
    s.feature_flags,
    coalesce(
      s.owner_email,
      (
        SELECT u.email
        FROM auth.users u
        JOIN public.shop_members om ON om.user_id = u.id
        WHERE om.shop_id = s.id AND om.role = 'owner' AND om.employment_status <> 'terminated'
        LIMIT 1
      ),
      'Pending owner enrollment'
    )::text,
    (
      SELECT count(*)::bigint
      FROM public.shop_members m
      WHERE m.shop_id = s.id
        AND m.employment_status <> 'terminated'
        AND NOT EXISTS (SELECT 1 FROM public.platform_admins pa WHERE pa.user_id = m.user_id)
    ),
    (
      SELECT count(*)::bigint
      FROM public.products p
      WHERE p.shop_id = s.id AND NOT p.archived
    ),
    (
      SELECT coalesce(sum(p.stock), 0)::bigint
      FROM public.products p
      WHERE p.shop_id = s.id AND NOT p.archived
    ),
    s.created_at::timestamptz,
    s.suspended_at::timestamptz,
    s.closed_at::timestamptz,
    coalesce(s.suspension_reason, s.closure_reason)::text,
    s.counter_inventory_mode,
    (
      SELECT count(*)::bigint
      FROM public.service_counters c
      WHERE c.shop_id = s.id AND c.active
    )
  FROM public.shops s
  ORDER BY s.created_at DESC;
END $$;

REVOKE ALL ON FUNCTION public.admin_list_businesses() FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.admin_list_businesses() TO authenticated;

DROP FUNCTION IF EXISTS public.admin_list_shop_members(uuid);
CREATE FUNCTION public.admin_list_shop_members(_shop uuid)
RETURNS TABLE(
  member_user_id uuid,
  email text,
  role text,
  employment_status text,
  status_reason text,
  schedule jsonb,
  display_name text
)
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
BEGIN
  IF NOT public.is_shop_manager(_shop) AND NOT public.is_platform_admin() THEN
    RAISE EXCEPTION 'forbidden';
  END IF;
  RETURN QUERY
  SELECT
    m.user_id,
    u.email::text,
    m.role::text,
    m.employment_status,
    m.status_reason,
    coalesce((
      SELECT jsonb_agg(jsonb_build_object(
        'weekday', h.weekday,
        'start_time', h.start_time,
        'end_time', h.end_time,
        'enabled', h.enabled
      ) ORDER BY h.weekday)
      FROM public.employee_working_hours h
      WHERE h.shop_id = _shop AND h.user_id = m.user_id
    ), '[]'::jsonb),
    m.display_name
  FROM public.shop_members m
  LEFT JOIN auth.users u ON u.id = m.user_id
  WHERE m.shop_id = _shop
    AND NOT EXISTS (SELECT 1 FROM public.platform_admins pa WHERE pa.user_id = m.user_id)
  ORDER BY CASE m.role WHEN 'owner' THEN 0 WHEN 'manager' THEN 1 ELSE 2 END,
    lower(coalesce(m.display_name, u.email, ''));
END $$;

REVOKE ALL ON FUNCTION public.admin_list_shop_members(uuid) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.admin_list_shop_members(uuid) TO authenticated;

NOTIFY pgrst, 'reload schema';
