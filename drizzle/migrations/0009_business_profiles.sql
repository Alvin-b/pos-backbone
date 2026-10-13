-- Tenant profile controls which business dashboard and features the owner receives.
ALTER TABLE public.shops
  ADD COLUMN IF NOT EXISTS business_type text NOT NULL DEFAULT 'big_club'
    CHECK (business_type IN ('big_club', 'counter_seller')),
  ADD COLUMN IF NOT EXISTS business_size text NOT NULL DEFAULT 'medium'
    CHECK (business_size IN ('small', 'medium', 'large')),
  ADD COLUMN IF NOT EXISTS feature_flags jsonb NOT NULL DEFAULT '{"tables":true,"employee_management":true,"working_hours":true,"fifo_inventory":true,"sales_analytics":true}'::jsonb;

CREATE INDEX IF NOT EXISTS shops_profile_idx ON public.shops(business_type, business_size, status);

DROP FUNCTION IF EXISTS public.admin_list_businesses();
CREATE OR REPLACE FUNCTION public.admin_list_businesses()
RETURNS TABLE(
  shop_id uuid, shop_name text, status text, business_type text, business_size text, feature_flags jsonb,
  owner_email text, member_count bigint, product_count bigint, stock_units bigint,
  created_at timestamptz, suspended_at timestamptz, closed_at timestamptz, lifecycle_reason text
)
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
BEGIN
  IF NOT public.is_platform_admin() THEN RAISE EXCEPTION 'forbidden'; END IF;
  RETURN QUERY
  SELECT s.id::uuid, s.name::text, s.status::text, s.business_type::text, s.business_size::text, s.feature_flags,
    coalesce(s.owner_email, (SELECT u.email FROM auth.users u JOIN public.shop_members om ON om.user_id = u.id
      WHERE om.shop_id = s.id AND om.role = 'owner' LIMIT 1), 'Pending owner enrollment')::text,
    (SELECT count(*)::bigint FROM public.shop_members m WHERE m.shop_id = s.id),
    (SELECT count(*)::bigint FROM public.products p WHERE p.shop_id = s.id AND NOT p.archived),
    (SELECT coalesce(sum(p.stock), 0)::bigint FROM public.products p WHERE p.shop_id = s.id AND NOT p.archived),
    s.created_at::timestamptz, s.suspended_at::timestamptz, s.closed_at::timestamptz,
    coalesce(s.suspension_reason, s.closure_reason)::text
  FROM public.shops s ORDER BY s.created_at DESC;
END $$;

DROP FUNCTION IF EXISTS public.admin_create_business(text, text);
CREATE OR REPLACE FUNCTION public.admin_create_business(
  _name text, _owner_email text DEFAULT NULL, _business_type text DEFAULT 'big_club', _business_size text DEFAULT 'medium'
)
RETURNS public.shops
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE s public.shops; owner_id uuid; flags jsonb;
BEGIN
  IF NOT public.is_platform_admin() THEN RAISE EXCEPTION 'forbidden'; END IF;
  IF coalesce(length(trim(_name)), 0) NOT BETWEEN 1 AND 120 THEN RAISE EXCEPTION 'invalid_business_name'; END IF;
  IF _business_type NOT IN ('big_club', 'counter_seller') THEN RAISE EXCEPTION 'invalid_business_type'; END IF;
  IF _business_size NOT IN ('small', 'medium', 'large') THEN RAISE EXCEPTION 'invalid_business_size'; END IF;
  flags := CASE _business_type
    WHEN 'big_club' THEN '{"tables":true,"employee_management":true,"working_hours":true,"fifo_inventory":true,"sales_analytics":true}'::jsonb
    ELSE '{"tables":false,"employee_management":true,"working_hours":false,"fifo_inventory":true,"sales_analytics":false}'::jsonb
  END;
  SELECT id INTO owner_id FROM auth.users WHERE nullif(trim(_owner_email), '') IS NOT NULL AND lower(email) = lower(trim(_owner_email));
  INSERT INTO public.shops(name, created_by, owner_email, status, business_type, business_size, feature_flags)
  VALUES (trim(_name), auth.uid(), nullif(trim(_owner_email), ''), 'active', _business_type, _business_size, flags)
  RETURNING * INTO s;
  IF owner_id IS NOT NULL THEN
    INSERT INTO public.shop_members(shop_id, user_id, role, employment_status) VALUES (s.id, owner_id, 'owner', 'active');
  END IF;
  PERFORM public.write_audit_event(s.id, 'business_created_by_admin', 'shop', s.id,
    jsonb_build_object('owner_email', nullif(lower(trim(_owner_email)), ''), 'owner_enrolled', owner_id IS NOT NULL,
      'business_type', _business_type, 'business_size', _business_size, 'feature_flags', flags));
  RETURN s;
END $$;

CREATE OR REPLACE FUNCTION public.my_account()
RETURNS json LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = public AS $$
DECLARE result json;
BEGIN
  IF auth.uid() IS NULL THEN RAISE EXCEPTION 'not_authenticated'; END IF;
  SELECT json_build_object(
    'user_id', auth.uid(), 'email', (SELECT email FROM auth.users WHERE id = auth.uid()),
    'is_platform_admin', public.is_platform_admin(),
    'memberships', coalesce((SELECT json_agg(json_build_object(
      'shop_id', m.shop_id, 'shop_name', s.name, 'role', m.role, 'status', s.status,
      'employment_status', m.employment_status, 'business_type', s.business_type, 'business_size', s.business_size,
      'feature_flags', s.feature_flags, 'currency', s.currency, 'low_stock_threshold', s.low_stock_threshold
    ) ORDER BY s.created_at DESC) FROM public.shop_members m JOIN public.shops s ON s.id = m.shop_id
      WHERE m.user_id = auth.uid()), '[]'::json)
  ) INTO result;
  RETURN result;
END $$;

GRANT EXECUTE ON FUNCTION public.admin_list_businesses(), public.admin_create_business(text,text,text,text), public.my_account() TO authenticated;
REVOKE EXECUTE ON FUNCTION public.admin_list_businesses(), public.admin_create_business(text,text,text,text), public.my_account() FROM anon;
