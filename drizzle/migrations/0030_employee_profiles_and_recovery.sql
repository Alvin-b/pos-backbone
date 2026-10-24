-- Owner-managed employee identity and safe re-enrollment on a replacement device.
-- Recovery codes are single-use, short-lived, and scoped to one existing Auth user.

ALTER TABLE public.shop_members
  ADD COLUMN IF NOT EXISTS display_name text;

DO $$
BEGIN
  IF NOT EXISTS (
    SELECT 1 FROM pg_constraint
    WHERE conname = 'shop_members_display_name_length_check'
      AND conrelid = 'public.shop_members'::regclass
  ) THEN
    ALTER TABLE public.shop_members
      ADD CONSTRAINT shop_members_display_name_length_check
      CHECK (display_name IS NULL OR length(btrim(display_name)) BETWEEN 1 AND 80);
  END IF;
END $$;

CREATE TABLE IF NOT EXISTS public.employee_recovery_passes (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  shop_id uuid NOT NULL REFERENCES public.shops(id) ON DELETE CASCADE,
  user_id uuid NOT NULL,
  pass_hash text NOT NULL UNIQUE CHECK (length(pass_hash) = 64),
  created_by uuid NOT NULL,
  created_at timestamptz NOT NULL DEFAULT now(),
  expires_at timestamptz NOT NULL DEFAULT (now() + interval '20 minutes'),
  claim_token uuid,
  claim_expires_at timestamptz,
  redeemed_at timestamptz,
  revoked_at timestamptz
);

CREATE INDEX IF NOT EXISTS employee_recovery_passes_target_idx
  ON public.employee_recovery_passes(shop_id, user_id, created_at DESC);

ALTER TABLE public.employee_recovery_passes ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON public.employee_recovery_passes FROM PUBLIC, anon, authenticated;
GRANT ALL ON public.employee_recovery_passes TO service_role;

CREATE OR REPLACE FUNCTION public.revoke_employee_recovery_on_membership_change()
RETURNS trigger
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
BEGIN
  IF TG_OP = 'DELETE' THEN
    UPDATE public.employee_recovery_passes
    SET revoked_at = now()
    WHERE shop_id = OLD.shop_id AND user_id = OLD.user_id
      AND redeemed_at IS NULL AND revoked_at IS NULL;
    RETURN OLD;
  END IF;
  IF NEW.employment_status <> 'active' THEN
    UPDATE public.employee_recovery_passes
    SET revoked_at = now()
    WHERE shop_id = NEW.shop_id AND user_id = NEW.user_id
      AND redeemed_at IS NULL AND revoked_at IS NULL;
  END IF;
  RETURN NEW;
END $$;

DROP TRIGGER IF EXISTS revoke_employee_recovery_on_membership_change_trigger ON public.shop_members;
CREATE TRIGGER revoke_employee_recovery_on_membership_change_trigger
AFTER UPDATE OF employment_status OR DELETE ON public.shop_members
FOR EACH ROW EXECUTE FUNCTION public.revoke_employee_recovery_on_membership_change();
REVOKE ALL ON FUNCTION public.revoke_employee_recovery_on_membership_change() FROM PUBLIC, anon, authenticated;

-- A business-local label avoids changing the employee's global Auth identity.
CREATE OR REPLACE FUNCTION public.set_employee_display_name(
  _shop uuid,
  _user uuid,
  _display_name text
)
RETURNS void
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE
  actor_role public.shop_role;
  target_role public.shop_role;
  old_name text;
  next_name text := nullif(btrim(coalesce(_display_name, '')), '');
BEGIN
  IF NOT public.is_shop_manager(_shop) THEN RAISE EXCEPTION 'forbidden'; END IF;
  IF length(coalesce(next_name, '')) NOT BETWEEN 1 AND 80 THEN
    RAISE EXCEPTION 'invalid_employee_display_name';
  END IF;

  SELECT role INTO actor_role
  FROM public.shop_members
  WHERE shop_id = _shop AND user_id = auth.uid() AND employment_status = 'active';
  SELECT role, display_name INTO target_role, old_name
  FROM public.shop_members
  WHERE shop_id = _shop AND user_id = _user AND employment_status <> 'terminated'
  FOR UPDATE;
  IF target_role IS NULL THEN RAISE EXCEPTION 'employee_not_found'; END IF;
  IF target_role = 'owner' THEN RAISE EXCEPTION 'owner_profile_is_managed_separately'; END IF;
  IF actor_role <> 'owner' AND target_role = 'manager' THEN
    RAISE EXCEPTION 'manager_cannot_manage_manager';
  END IF;

  UPDATE public.shop_members SET display_name = next_name
  WHERE shop_id = _shop AND user_id = _user;
  IF old_name IS DISTINCT FROM next_name THEN
    PERFORM public.write_audit_event(
      _shop, 'employee_display_name_changed', 'user', _user,
      jsonb_build_object('old_name', old_name, 'new_name', next_name)
    );
  END IF;
END $$;

-- Recreate the table-returning RPC to add display_name to its result contract.
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
  IF NOT public.is_shop_manager(_shop) THEN RAISE EXCEPTION 'forbidden'; END IF;
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
  ORDER BY CASE m.role WHEN 'owner' THEN 0 WHEN 'manager' THEN 1 ELSE 2 END,
    lower(coalesce(m.display_name, u.email, ''));
END $$;

-- Called only by a service-role Edge Function after validating the signed-in owner.
-- The actor is rechecked in SQL so a caller cannot mint codes for another business.
CREATE OR REPLACE FUNCTION public.issue_employee_recovery_pass(
  _shop uuid,
  _user uuid,
  _pass_hash text,
  _actor uuid
)
RETURNS timestamptz
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE
  target_role public.shop_role;
  target_status text;
  shop_status text;
  expires timestamptz := now() + interval '20 minutes';
BEGIN
  IF _actor IS NULL OR NOT EXISTS (
    SELECT 1 FROM public.shop_members
    WHERE shop_id = _shop AND user_id = _actor
      AND role = 'owner' AND employment_status = 'active'
  ) THEN
    RAISE EXCEPTION 'forbidden';
  END IF;
  IF _pass_hash IS NULL OR length(_pass_hash) <> 64 THEN RAISE EXCEPTION 'invalid_pass_hash'; END IF;

  SELECT status INTO shop_status FROM public.shops WHERE id = _shop FOR SHARE;
  IF shop_status IS DISTINCT FROM 'active' THEN RAISE EXCEPTION 'business_not_active'; END IF;
  SELECT role, employment_status INTO target_role, target_status
  FROM public.shop_members
  WHERE shop_id = _shop AND user_id = _user
  FOR UPDATE;
  IF target_role IS NULL OR target_role = 'owner' OR target_status = 'terminated' THEN
    RAISE EXCEPTION 'employee_not_found';
  END IF;
  IF target_status <> 'active' THEN RAISE EXCEPTION 'employee_inactive'; END IF;

  UPDATE public.employee_recovery_passes
  SET revoked_at = now()
  WHERE shop_id = _shop AND user_id = _user
    AND redeemed_at IS NULL AND revoked_at IS NULL;
  INSERT INTO public.employee_recovery_passes(shop_id, user_id, pass_hash, created_by, expires_at)
  VALUES (_shop, _user, lower(_pass_hash), _actor, expires);
  INSERT INTO public.audit_events(shop_id, actor_user_id, action, entity_type, entity_id, metadata)
  VALUES (_shop, _actor, 'employee_recovery_issued', 'user', _user,
    jsonb_build_object('expires_at', expires));
  RETURN expires;
END $$;

-- Claims atomically before the Edge Function rotates the password on this same
-- Auth user. Failed rotations require the owner to issue a fresh code.
CREATE OR REPLACE FUNCTION public.redeem_employee_recovery_pass_atomic(_pass_hash text)
RETURNS json
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE
  p public.employee_recovery_passes;
  s public.shops;
  member_role public.shop_role;
  member_status text;
  employee_name text;
  claim_id uuid := gen_random_uuid();
BEGIN
  SELECT * INTO p FROM public.employee_recovery_passes
  WHERE pass_hash = lower(trim(_pass_hash)) FOR UPDATE;
  IF p.id IS NULL THEN RAISE EXCEPTION 'employee_recovery_pass_not_found'; END IF;
  IF p.redeemed_at IS NOT NULL OR p.revoked_at IS NOT NULL OR p.expires_at <= now() THEN
    RAISE EXCEPTION 'passkey_expired_or_used';
  END IF;
  IF p.claim_expires_at IS NOT NULL AND p.claim_expires_at > now() THEN
    RAISE EXCEPTION 'employee_recovery_in_progress';
  END IF;
  SELECT * INTO s FROM public.shops WHERE id = p.shop_id FOR SHARE;
  IF s.id IS NULL OR s.status <> 'active' THEN RAISE EXCEPTION 'business_not_active'; END IF;
  SELECT role, employment_status, display_name
  INTO member_role, member_status, employee_name
  FROM public.shop_members
  WHERE shop_id = p.shop_id AND user_id = p.user_id FOR SHARE;
  IF member_role IS NULL OR member_role = 'owner' OR member_status = 'terminated' THEN
    RAISE EXCEPTION 'employee_not_found';
  END IF;
  IF member_status <> 'active' THEN RAISE EXCEPTION 'employee_inactive'; END IF;

  UPDATE public.employee_recovery_passes
  SET claim_token = claim_id, claim_expires_at = now() + interval '3 minutes'
  WHERE id = p.id;
  RETURN json_build_object(
    'user_id', p.user_id,
    'business_id', s.id,
    'business_name', s.name,
    'role', member_role,
    'display_name', employee_name,
    'claim_token', claim_id
  );
END $$;

CREATE OR REPLACE FUNCTION public.complete_employee_recovery_pass(_pass_hash text, _claim_token uuid)
RETURNS void
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE p public.employee_recovery_passes;
  shop_status text;
  member_status text;
BEGIN
  SELECT * INTO p FROM public.employee_recovery_passes
  WHERE pass_hash = lower(trim(_pass_hash))
    AND claim_token = _claim_token
    AND claim_expires_at > now()
    AND redeemed_at IS NULL
    AND revoked_at IS NULL
    AND expires_at > now()
  FOR UPDATE;
  IF p.id IS NULL THEN RAISE EXCEPTION 'employee_recovery_claim_expired'; END IF;
  SELECT status INTO shop_status FROM public.shops WHERE id = p.shop_id FOR SHARE;
  IF shop_status IS DISTINCT FROM 'active' THEN RAISE EXCEPTION 'business_not_active'; END IF;
  SELECT employment_status INTO member_status FROM public.shop_members
  WHERE shop_id = p.shop_id AND user_id = p.user_id FOR SHARE;
  IF member_status IS DISTINCT FROM 'active' THEN RAISE EXCEPTION 'employee_inactive'; END IF;

  UPDATE public.employee_recovery_passes
  SET redeemed_at = now(), claim_token = NULL, claim_expires_at = NULL
  WHERE id = p.id;
  INSERT INTO public.audit_events(shop_id, actor_user_id, action, entity_type, entity_id, metadata)
  VALUES (p.shop_id, p.created_by, 'employee_recovery_completed', 'user', p.user_id,
    jsonb_build_object('employee_user_id', p.user_id));
END $$;

REVOKE ALL ON FUNCTION public.set_employee_display_name(uuid, uuid, text) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.set_employee_display_name(uuid, uuid, text) TO authenticated;
REVOKE ALL ON FUNCTION public.admin_list_shop_members(uuid) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.admin_list_shop_members(uuid) TO authenticated;
REVOKE ALL ON FUNCTION public.issue_employee_recovery_pass(uuid, uuid, text, uuid) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.issue_employee_recovery_pass(uuid, uuid, text, uuid) TO service_role;
REVOKE ALL ON FUNCTION public.redeem_employee_recovery_pass_atomic(text) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.redeem_employee_recovery_pass_atomic(text) TO service_role;
REVOKE ALL ON FUNCTION public.complete_employee_recovery_pass(text, uuid) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.complete_employee_recovery_pass(text, uuid) TO service_role;

NOTIFY pgrst, 'reload schema';
