-- Paste after setup_admin.sql if Lovable does not automatically apply 0013_owner_settings_audit_history.sql.
DROP POLICY IF EXISTS "platform admins and shop managers read audit events" ON public.audit_events;
CREATE POLICY "platform admins and shop managers read audit events"
  ON public.audit_events FOR SELECT TO authenticated
  USING (public.is_platform_admin() OR public.is_shop_manager(shop_id));

CREATE OR REPLACE FUNCTION public.set_employee_role(_shop uuid, _user uuid, _role text)
RETURNS void LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE target_role public.shop_role;
BEGIN
  IF NOT public.is_shop_manager(_shop) THEN RAISE EXCEPTION 'forbidden'; END IF;
  IF _role NOT IN ('manager', 'inventory_clerk', 'cashier') THEN RAISE EXCEPTION 'invalid_employee_role'; END IF;
  SELECT role INTO target_role FROM public.shop_members WHERE shop_id = _shop AND user_id = _user;
  IF target_role IS NULL THEN RAISE EXCEPTION 'employee_not_found'; END IF;
  IF target_role = 'owner' OR _user = auth.uid() THEN RAISE EXCEPTION 'owner_role_cannot_be_changed'; END IF;
  UPDATE public.shop_members SET role = _role::public.shop_role WHERE shop_id = _shop AND user_id = _user;
  PERFORM public.write_audit_event(_shop, 'employee_role_changed', 'user', _user, jsonb_build_object('role', _role));
END $$;

CREATE OR REPLACE FUNCTION public.remove_employee(_shop uuid, _user uuid)
RETURNS void LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE target_role public.shop_role;
BEGIN
  IF NOT public.is_shop_manager(_shop) THEN RAISE EXCEPTION 'forbidden'; END IF;
  SELECT role INTO target_role FROM public.shop_members WHERE shop_id = _shop AND user_id = _user;
  IF target_role IS NULL THEN RAISE EXCEPTION 'employee_not_found'; END IF;
  IF target_role = 'owner' OR _user = auth.uid() THEN RAISE EXCEPTION 'owner_cannot_be_removed'; END IF;
  DELETE FROM public.employee_working_hours WHERE shop_id = _shop AND user_id = _user;
  DELETE FROM public.shop_members WHERE shop_id = _shop AND user_id = _user;
  PERFORM public.write_audit_event(_shop, 'employee_removed', 'user', _user, '{}'::jsonb);
END $$;

GRANT EXECUTE ON FUNCTION public.set_employee_role(uuid, uuid, text), public.remove_employee(uuid, uuid) TO authenticated;
REVOKE EXECUTE ON FUNCTION public.set_employee_role(uuid, uuid, text), public.remove_employee(uuid, uuid) FROM anon;
