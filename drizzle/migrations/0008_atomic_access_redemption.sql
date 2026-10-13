-- Atomic access-pass redemption. The row lock makes concurrent redemption one-time.
CREATE OR REPLACE FUNCTION public.redeem_access_pass_atomic(_pass_hash text, _user uuid)
RETURNS json
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE p public.access_passes; s public.shops;
BEGIN
  SELECT * INTO p FROM public.access_passes WHERE pass_hash = lower(trim(_pass_hash)) FOR UPDATE;
  IF p.id IS NULL OR p.redeemed_at IS NOT NULL OR p.revoked_at IS NOT NULL OR p.expires_at <= now() THEN
    RAISE EXCEPTION 'passkey_expired_or_used';
  END IF;
  SELECT * INTO s FROM public.shops WHERE id = p.shop_id FOR SHARE;
  IF s.id IS NULL OR s.status <> 'active' THEN RAISE EXCEPTION 'business_not_active'; END IF;
  INSERT INTO public.shop_members(shop_id, user_id, role, employment_status)
  VALUES (p.shop_id, _user, p.role, 'active')
  ON CONFLICT (shop_id, user_id) DO UPDATE SET role = EXCLUDED.role
  WHERE public.shop_members.employment_status = 'active';
  IF NOT EXISTS (SELECT 1 FROM public.shop_members WHERE shop_id = p.shop_id AND user_id = _user AND employment_status = 'active') THEN
    RAISE EXCEPTION 'employee_inactive';
  END IF;
  UPDATE public.access_passes SET redeemed_at = now(), redeemed_by = _user WHERE id = p.id;
  RETURN json_build_object('business_id', s.id, 'business_name', s.name, 'role', p.role);
END $$;
GRANT EXECUTE ON FUNCTION public.redeem_access_pass_atomic(text, uuid) TO service_role;
REVOKE EXECUTE ON FUNCTION public.redeem_access_pass_atomic(text, uuid) FROM anon, authenticated;
