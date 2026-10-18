-- The platform administrator enrolls each business owner. Business owners manage
-- their own staff; Waiter is the only employee position currently offered.

CREATE OR REPLACE FUNCTION public.add_member_by_email(
  _shop uuid,
  _email text,
  _role public.shop_role DEFAULT 'cashier'
)
RETURNS void
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE uid uuid;
BEGIN
  IF NOT public.has_shop_role(_shop, ARRAY['owner']::public.shop_role[]) THEN
    RAISE EXCEPTION 'forbidden';
  END IF;
  IF _role IS DISTINCT FROM 'cashier'::public.shop_role THEN
    RAISE EXCEPTION 'only_waiter_role_supported';
  END IF;

  SELECT id INTO uid
  FROM auth.users
  WHERE lower(email) = lower(trim(_email));
  IF uid IS NULL THEN RAISE EXCEPTION 'user_not_found'; END IF;
  IF EXISTS (
    SELECT 1 FROM public.shop_members
    WHERE shop_id = _shop AND user_id = uid AND role = 'owner'
  ) THEN
    RAISE EXCEPTION 'owner_role_is_managed_by_platform';
  END IF;

  INSERT INTO public.shop_members(shop_id, user_id, role)
  VALUES (_shop, uid, 'cashier')
  ON CONFLICT (shop_id, user_id) DO UPDATE SET role = EXCLUDED.role;
  PERFORM public.write_audit_event(
    _shop, 'member_role_changed', 'user', uid,
    jsonb_build_object('email', lower(trim(_email)), 'role', 'cashier', 'display_role', 'Waiter')
  );
END $$;

CREATE OR REPLACE FUNCTION public.set_employee_role(_shop uuid, _user uuid, _role text)
RETURNS void
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE previous_role public.shop_role;
BEGIN
  IF NOT public.has_shop_role(_shop, ARRAY['owner']::public.shop_role[]) THEN
    RAISE EXCEPTION 'forbidden';
  END IF;
  IF _user = auth.uid() THEN RAISE EXCEPTION 'cannot_change_own_role'; END IF;
  IF _role IS DISTINCT FROM 'cashier' THEN
    RAISE EXCEPTION 'only_waiter_role_supported';
  END IF;

  SELECT role INTO previous_role
  FROM public.shop_members
  WHERE shop_id = _shop AND user_id = _user AND employment_status <> 'terminated'
  FOR UPDATE;
  IF previous_role IS NULL THEN RAISE EXCEPTION 'employee_not_found'; END IF;
  IF previous_role = 'owner' THEN RAISE EXCEPTION 'owner_role_is_managed_by_platform'; END IF;

  UPDATE public.shop_members
  SET role = 'cashier'
  WHERE shop_id = _shop AND user_id = _user;

  IF previous_role <> 'cashier' THEN
    PERFORM public.write_audit_event(
      _shop, 'employee_role_changed', 'user', _user,
      jsonb_build_object('old_role', previous_role, 'new_role', 'cashier', 'display_role', 'Waiter')
    );
  END IF;
END;
$$;
