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
