-- Compatibility repair for deployments that applied the profile changes before
-- the employee-controls migration. Safe to run repeatedly.
ALTER TABLE public.shops
  ADD COLUMN IF NOT EXISTS timezone text NOT NULL DEFAULT 'Africa/Nairobi',
  ADD COLUMN IF NOT EXISTS business_type text NOT NULL DEFAULT 'big_club',
  ADD COLUMN IF NOT EXISTS business_size text NOT NULL DEFAULT 'medium',
  ADD COLUMN IF NOT EXISTS feature_flags jsonb NOT NULL DEFAULT '{"tables":true,"employee_management":true,"working_hours":true,"fifo_inventory":true,"sales_analytics":true}'::jsonb;

ALTER TABLE public.shop_members
  ADD COLUMN IF NOT EXISTS employment_status text NOT NULL DEFAULT 'active',
  ADD COLUMN IF NOT EXISTS status_reason text,
  ADD COLUMN IF NOT EXISTS status_changed_at timestamptz,
  ADD COLUMN IF NOT EXISTS status_changed_by uuid;

UPDATE public.shop_members SET employment_status = 'active' WHERE employment_status IS NULL;

DO $$
BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_constraint WHERE conname = 'shop_members_employment_status_check') THEN
    ALTER TABLE public.shop_members ADD CONSTRAINT shop_members_employment_status_check
      CHECK (employment_status IN ('active', 'suspended', 'terminated'));
  END IF;
END $$;

CREATE TABLE IF NOT EXISTS public.employee_working_hours (
  shop_id uuid NOT NULL REFERENCES public.shops(id) ON DELETE CASCADE,
  user_id uuid NOT NULL,
  weekday smallint NOT NULL CHECK (weekday BETWEEN 0 AND 6),
  start_time time NOT NULL,
  end_time time NOT NULL,
  enabled boolean NOT NULL DEFAULT true,
  updated_at timestamptz NOT NULL DEFAULT now(),
  updated_by uuid,
  PRIMARY KEY (shop_id, user_id, weekday)
);
ALTER TABLE public.employee_working_hours ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON public.employee_working_hours FROM anon, authenticated;
GRANT ALL ON public.employee_working_hours TO service_role;

CREATE OR REPLACE FUNCTION public.is_shop_member(_shop uuid)
RETURNS boolean LANGUAGE sql STABLE SECURITY DEFINER SET search_path = public AS $$
  SELECT public.is_shop_active(_shop) AND EXISTS (
    SELECT 1 FROM public.shop_members WHERE shop_id = _shop AND user_id = auth.uid() AND employment_status = 'active'
  )
$$;

CREATE OR REPLACE FUNCTION public.has_shop_role(_shop uuid, _roles public.shop_role[])
RETURNS boolean LANGUAGE sql STABLE SECURITY DEFINER SET search_path = public AS $$
  SELECT public.is_shop_active(_shop) AND EXISTS (
    SELECT 1 FROM public.shop_members WHERE shop_id = _shop AND user_id = auth.uid()
      AND employment_status = 'active' AND role = ANY(_roles)
  )
$$;

CREATE OR REPLACE FUNCTION public.can_sell_for_shop(_shop uuid)
RETURNS boolean LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = public AS $$
DECLARE tz text; local_now timestamp; dow int; current_time_value time; schedule_count int;
BEGIN
  IF NOT public.is_shop_member(_shop) THEN RETURN false; END IF;
  SELECT timezone INTO tz FROM public.shops WHERE id = _shop;
  local_now := now() AT TIME ZONE coalesce(nullif(tz, ''), 'Africa/Nairobi');
  dow := extract(dow FROM local_now)::int; current_time_value := local_now::time;
  SELECT count(*) INTO schedule_count FROM public.employee_working_hours
    WHERE shop_id = _shop AND user_id = auth.uid() AND enabled;
  IF schedule_count = 0 THEN RETURN true; END IF;
  RETURN EXISTS (SELECT 1 FROM public.employee_working_hours h
    WHERE h.shop_id = _shop AND h.user_id = auth.uid() AND h.weekday = dow AND h.enabled
      AND CASE WHEN h.start_time <= h.end_time THEN current_time_value BETWEEN h.start_time AND h.end_time
        ELSE current_time_value >= h.start_time OR current_time_value <= h.end_time END);
END $$;

CREATE OR REPLACE FUNCTION public.admin_list_shop_members(_shop uuid)
RETURNS TABLE(member_user_id uuid, email text, role text, employment_status text, status_reason text, schedule jsonb)
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
BEGIN
  IF NOT public.is_shop_manager(_shop) THEN RAISE EXCEPTION 'forbidden'; END IF;
  RETURN QUERY SELECT m.user_id, u.email::text, m.role::text, m.employment_status::text, m.status_reason::text,
    coalesce((SELECT jsonb_agg(jsonb_build_object('weekday', h.weekday, 'start_time', h.start_time, 'end_time', h.end_time, 'enabled', h.enabled) ORDER BY h.weekday)
      FROM public.employee_working_hours h WHERE h.shop_id = _shop AND h.user_id = m.user_id), '[]'::jsonb)
  FROM public.shop_members m LEFT JOIN auth.users u ON u.id = m.user_id
  WHERE m.shop_id = _shop
  ORDER BY CASE m.role WHEN 'owner' THEN 0 WHEN 'manager' THEN 1 ELSE 2 END, lower(coalesce(u.email, ''));
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
      'employment_status', coalesce(m.employment_status, 'active'),
      'business_type', coalesce(s.business_type, 'big_club'), 'business_size', coalesce(s.business_size, 'medium'),
      'feature_flags', coalesce(s.feature_flags, '{}'::jsonb), 'currency', s.currency, 'low_stock_threshold', s.low_stock_threshold
    ) ORDER BY s.created_at DESC) FROM public.shop_members m JOIN public.shops s ON s.id = m.shop_id
      WHERE m.user_id = auth.uid()), '[]'::json)
  ) INTO result;
  RETURN result;
END $$;

GRANT EXECUTE ON FUNCTION public.my_account(), public.admin_list_shop_members(uuid), public.can_sell_for_shop(uuid) TO authenticated;
REVOKE EXECUTE ON FUNCTION public.my_account(), public.admin_list_shop_members(uuid), public.can_sell_for_shop(uuid) FROM anon;
-- Tenant profile controls which business dashboard and features the owner receives.
ALTER TABLE public.shop_members
  ADD COLUMN IF NOT EXISTS employment_status text NOT NULL DEFAULT 'active',
  ADD COLUMN IF NOT EXISTS status_reason text,
  ADD COLUMN IF NOT EXISTS status_changed_at timestamptz,
  ADD COLUMN IF NOT EXISTS status_changed_by uuid;

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
