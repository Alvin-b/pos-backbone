-- Platform administrators manage businesses but are not business staff.
-- Older onboarding paths could attach the approving admin to shop_members,
-- making the admin appear in Staff/Team. Remove those legacy rows first.
DELETE FROM public.shop_members sm
USING public.platform_admins pa
WHERE pa.user_id = sm.user_id;

-- Do not attach a platform administrator as the owner when an admin enters
-- an email during business registration. The owner must be the enrolled
-- business account, not the platform account that created the tenant.
CREATE OR REPLACE FUNCTION public.admin_create_business(
  _name text,
  _owner_email text DEFAULT NULL,
  _business_type text DEFAULT 'big_club',
  _business_size text DEFAULT 'medium'
)
RETURNS public.shops
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE
  s public.shops;
  owner_id uuid;
  flags jsonb;
  owner_is_platform_admin boolean := false;
BEGIN
  IF NOT public.is_platform_admin() THEN RAISE EXCEPTION 'forbidden'; END IF;
  IF coalesce(length(trim(_name)), 0) NOT BETWEEN 1 AND 120 THEN RAISE EXCEPTION 'invalid_business_name'; END IF;
  IF _business_type NOT IN ('big_club', 'counter_seller') THEN RAISE EXCEPTION 'invalid_business_type'; END IF;
  IF _business_size NOT IN ('small', 'medium', 'large') THEN RAISE EXCEPTION 'invalid_business_size'; END IF;

  flags := CASE _business_type
    WHEN 'big_club' THEN '{"tables":true,"employee_management":true,"working_hours":true,"fifo_inventory":true,"sales_analytics":true}'::jsonb
    ELSE '{"tables":false,"employee_management":true,"working_hours":false,"fifo_inventory":true,"sales_analytics":false}'::jsonb
  END;

  SELECT u.id, EXISTS (
    SELECT 1 FROM public.platform_admins pa WHERE pa.user_id = u.id
  ) INTO owner_id, owner_is_platform_admin
  FROM auth.users u
  WHERE nullif(trim(_owner_email), '') IS NOT NULL
    AND lower(u.email) = lower(trim(_owner_email));

  INSERT INTO public.shops(name, created_by, owner_email, status, business_type, business_size, feature_flags)
  VALUES (
    trim(_name),
    auth.uid(),
    CASE WHEN owner_is_platform_admin THEN NULL ELSE nullif(trim(_owner_email), '') END,
    'active',
    _business_type,
    _business_size,
    flags
  )
  RETURNING * INTO s;

  IF owner_id IS NOT NULL AND NOT owner_is_platform_admin THEN
    INSERT INTO public.shop_members(shop_id, user_id, role, employment_status)
    VALUES (s.id, owner_id, 'owner', 'active')
    ON CONFLICT (shop_id, user_id) DO UPDATE
      SET role = 'owner', employment_status = 'active';
  END IF;

  PERFORM public.write_audit_event(
    s.id,
    'business_created_by_admin',
    'shop',
    s.id,
    jsonb_build_object(
      'owner_email', CASE WHEN owner_is_platform_admin THEN NULL ELSE nullif(lower(trim(_owner_email)), '') END,
      'owner_enrolled', owner_id IS NOT NULL,
      'owner_is_platform_admin', owner_is_platform_admin,
      'business_type', _business_type,
      'business_size', _business_size,
      'feature_flags', flags
    )
  );
  RETURN s;
END $$;

-- Recreate the Staff/Team listing contract while excluding platform accounts.
-- Platform admins retain portfolio access through the admin APIs and should
-- never be shown as employees of an individual business.
CREATE OR REPLACE FUNCTION public.admin_list_shop_members(_shop uuid)
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
  SELECT m.user_id,
    u.email::text,
    m.role::text,
    m.employment_status,
    m.status_reason,
    coalesce((SELECT jsonb_agg(jsonb_build_object(
      'weekday', h.weekday,
      'start_time', h.start_time,
      'end_time', h.end_time,
      'enabled', h.enabled
    ) ORDER BY h.weekday) FROM public.employee_working_hours h
      WHERE h.shop_id = _shop AND h.user_id = m.user_id), '[]'::jsonb),
    m.display_name
  FROM public.shop_members m
  LEFT JOIN auth.users u ON u.id = m.user_id
  WHERE m.shop_id = _shop
    AND NOT EXISTS (
      SELECT 1 FROM public.platform_admins pa WHERE pa.user_id = m.user_id
    )
  ORDER BY CASE m.role WHEN 'owner' THEN 0 WHEN 'manager' THEN 1 ELSE 2 END,
    lower(coalesce(m.display_name, u.email, ''));
END $$;

REVOKE ALL ON FUNCTION public.admin_create_business(text, text, text, text) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.admin_create_business(text, text, text, text) TO authenticated;
REVOKE ALL ON FUNCTION public.admin_list_shop_members(uuid) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.admin_list_shop_members(uuid) TO authenticated;
NOTIFY pgrst, 'reload schema';
