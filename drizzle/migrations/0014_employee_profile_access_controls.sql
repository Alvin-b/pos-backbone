-- Follow-up to 0013_owner_settings_audit_history.sql.
-- Keep the existing RPC signatures where clients depend on them, but prevent
-- destructive employee deletion and enforce role hierarchy server-side.

CREATE OR REPLACE FUNCTION public.update_shop_name(_shop uuid, _name text)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  previous_name text;
  next_name text := trim(coalesce(_name, ''));
BEGIN
  IF NOT public.has_shop_role(_shop, ARRAY['owner']::public.shop_role[]) THEN
    RAISE EXCEPTION 'forbidden';
  END IF;
  IF length(next_name) NOT BETWEEN 1 AND 120 THEN
    RAISE EXCEPTION 'invalid_business_name';
  END IF;

  SELECT name INTO previous_name
  FROM public.shops
  WHERE id = _shop AND status = 'active'
  FOR UPDATE;
  IF previous_name IS NULL THEN
    RAISE EXCEPTION 'business_not_found_or_inactive';
  END IF;

  UPDATE public.shops SET name = next_name WHERE id = _shop;
  IF previous_name IS DISTINCT FROM next_name THEN
    PERFORM public.write_audit_event(
      _shop, 'business_name_changed', 'shop', _shop,
      jsonb_build_object('old_name', previous_name, 'new_name', next_name)
    );
  END IF;
END;
$$;

CREATE OR REPLACE FUNCTION public.set_employee_role(_shop uuid, _user uuid, _role text)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  actor_role public.shop_role;
  previous_role public.shop_role;
BEGIN
  IF NOT public.is_shop_manager(_shop) THEN
    RAISE EXCEPTION 'forbidden';
  END IF;
  IF _user = auth.uid() THEN
    RAISE EXCEPTION 'cannot_change_own_role';
  END IF;
  IF _role IS NULL OR _role NOT IN ('manager', 'inventory_clerk', 'cashier') THEN
    RAISE EXCEPTION 'invalid_employee_role';
  END IF;

  SELECT role INTO actor_role
  FROM public.shop_members
  WHERE shop_id = _shop AND user_id = auth.uid() AND employment_status = 'active';

  SELECT role INTO previous_role
  FROM public.shop_members
  WHERE shop_id = _shop AND user_id = _user AND employment_status <> 'terminated'
  FOR UPDATE;
  IF previous_role IS NULL THEN
    RAISE EXCEPTION 'employee_not_found';
  END IF;
  IF previous_role = 'owner' THEN
    RAISE EXCEPTION 'owner_role_is_managed_by_platform';
  END IF;
  IF actor_role <> 'owner' AND (previous_role = 'manager' OR _role = 'manager') THEN
    RAISE EXCEPTION 'manager_cannot_manage_manager_role';
  END IF;

  UPDATE public.shop_members
  SET role = _role::public.shop_role
  WHERE shop_id = _shop AND user_id = _user;

  IF previous_role::text IS DISTINCT FROM _role THEN
    PERFORM public.write_audit_event(
      _shop, 'employee_role_changed', 'user', _user,
      jsonb_build_object('old_role', previous_role, 'new_role', _role, 'actor_role', actor_role)
    );
  END IF;
END;
$$;

CREATE OR REPLACE FUNCTION public.remove_employee_access(
  _shop uuid,
  _user uuid,
  _reason text DEFAULT NULL
)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  actor_role public.shop_role;
  target_role public.shop_role;
  removal_reason text := nullif(trim(coalesce(_reason, '')), '');
BEGIN
  IF NOT public.is_shop_manager(_shop) THEN
    RAISE EXCEPTION 'forbidden';
  END IF;
  IF _user = auth.uid() THEN
    RAISE EXCEPTION 'cannot_remove_own_access';
  END IF;

  SELECT role INTO actor_role
  FROM public.shop_members
  WHERE shop_id = _shop AND user_id = auth.uid() AND employment_status = 'active';
  SELECT role INTO target_role
  FROM public.shop_members
  WHERE shop_id = _shop AND user_id = _user AND employment_status <> 'terminated'
  FOR UPDATE;
  IF target_role IS NULL THEN
    RAISE EXCEPTION 'employee_not_found';
  END IF;
  IF target_role = 'owner' THEN
    RAISE EXCEPTION 'owner_access_is_managed_by_platform';
  END IF;
  IF actor_role <> 'owner' AND target_role = 'manager' THEN
    RAISE EXCEPTION 'manager_cannot_remove_manager';
  END IF;

  UPDATE public.shop_members
  SET employment_status = 'terminated',
      status_reason = coalesce(removal_reason, 'Access removed by business administrator'),
      status_changed_at = now(),
      status_changed_by = auth.uid()
  WHERE shop_id = _shop AND user_id = _user;

  DELETE FROM public.employee_working_hours
  WHERE shop_id = _shop AND user_id = _user;

  PERFORM public.write_audit_event(
    _shop, 'employee_access_removed', 'user', _user,
    jsonb_build_object('previous_role', target_role, 'reason', removal_reason)
  );
END;
$$;

-- Keep the legacy RPC callable for older app versions, but route it to soft
-- removal so it cannot delete membership or audit-linked employee history.
CREATE OR REPLACE FUNCTION public.remove_employee(_shop uuid, _user uuid)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
BEGIN
  PERFORM public.remove_employee_access(_shop, _user, 'Access removed by business administrator');
END;
$$;

CREATE OR REPLACE FUNCTION public.set_employee_status(
  _shop uuid,
  _user uuid,
  _status text,
  _reason text DEFAULT NULL
)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  actor_role public.shop_role;
  target_role public.shop_role;
BEGIN
  IF NOT public.is_shop_manager(_shop) THEN
    RAISE EXCEPTION 'forbidden';
  END IF;
  IF _user = auth.uid() THEN
    RAISE EXCEPTION 'cannot_change_own_status';
  END IF;
  IF _status NOT IN ('active', 'suspended') THEN
    RAISE EXCEPTION 'invalid_employee_status';
  END IF;

  SELECT role INTO actor_role
  FROM public.shop_members
  WHERE shop_id = _shop AND user_id = auth.uid() AND employment_status = 'active';
  SELECT role INTO target_role
  FROM public.shop_members
  WHERE shop_id = _shop AND user_id = _user
  FOR UPDATE;
  IF target_role IS NULL THEN
    RAISE EXCEPTION 'employee_not_found';
  END IF;
  IF target_role = 'owner' THEN
    RAISE EXCEPTION 'owner_status_must_be_changed_by_platform';
  END IF;
  IF actor_role <> 'owner' AND target_role = 'manager' THEN
    RAISE EXCEPTION 'manager_cannot_manage_manager';
  END IF;

  UPDATE public.shop_members
  SET employment_status = _status,
      status_reason = nullif(trim(coalesce(_reason, '')), ''),
      status_changed_at = now(),
      status_changed_by = auth.uid()
  WHERE shop_id = _shop AND user_id = _user;

  PERFORM public.write_audit_event(
    _shop, 'employee_status_changed', 'user', _user,
    jsonb_build_object('status', _status, 'reason', _reason)
  );
END;
$$;

REVOKE ALL ON FUNCTION public.update_shop_name(uuid, text) FROM PUBLIC, anon;
REVOKE ALL ON FUNCTION public.set_employee_role(uuid, uuid, text) FROM PUBLIC, anon;
REVOKE ALL ON FUNCTION public.remove_employee_access(uuid, uuid, text) FROM PUBLIC, anon;
REVOKE ALL ON FUNCTION public.remove_employee(uuid, uuid) FROM PUBLIC, anon;
REVOKE ALL ON FUNCTION public.set_employee_status(uuid, uuid, text, text) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.update_shop_name(uuid, text),
  public.set_employee_role(uuid, uuid, text),
  public.remove_employee_access(uuid, uuid, text),
  public.remove_employee(uuid, uuid),
  public.set_employee_status(uuid, uuid, text, text)
TO authenticated;
