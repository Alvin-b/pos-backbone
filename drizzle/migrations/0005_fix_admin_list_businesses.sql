-- Repair for deployments that already applied 0003 before the explicit casts were added.
CREATE OR REPLACE FUNCTION public.admin_list_businesses()
RETURNS TABLE(
  shop_id uuid, shop_name text, status text, owner_email text,
  member_count bigint, product_count bigint, stock_units bigint,
  created_at timestamptz, suspended_at timestamptz, closed_at timestamptz,
  lifecycle_reason text
)
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
BEGIN
  IF NOT public.is_platform_admin() THEN RAISE EXCEPTION 'forbidden'; END IF;
  RETURN QUERY
  SELECT s.id::uuid, s.name::text, s.status::text,
    coalesce(
      s.owner_email,
      (SELECT u.email FROM auth.users u
       JOIN public.shop_members om ON om.user_id = u.id
       WHERE om.shop_id = s.id AND om.role = 'owner' LIMIT 1),
      'Pending owner enrollment'
    )::text,
    (SELECT count(*)::bigint FROM public.shop_members m WHERE m.shop_id = s.id),
    (SELECT count(*)::bigint FROM public.products p WHERE p.shop_id = s.id AND NOT p.archived),
    (SELECT coalesce(sum(p.stock), 0)::bigint FROM public.products p WHERE p.shop_id = s.id AND NOT p.archived),
    s.created_at::timestamptz, s.suspended_at::timestamptz, s.closed_at::timestamptz,
    coalesce(s.suspension_reason, s.closure_reason)::text
  FROM public.shops s ORDER BY s.created_at DESC;
END $$;

REVOKE EXECUTE ON FUNCTION public.admin_list_businesses() FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.admin_list_businesses() TO authenticated;
