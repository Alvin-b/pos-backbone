-- Admin subscription management RPC used by the Superadmin billing workspace.
-- This is intentionally a single unambiguous seven-parameter signature.

CREATE OR REPLACE FUNCTION public.admin_update_shop_subscription(
  p_shop_id uuid,
  p_price_ksh integer DEFAULT NULL,
  p_ends_at timestamptz DEFAULT NULL,
  p_status text DEFAULT NULL,
  p_plan_days integer DEFAULT NULL,
  p_trial_ends_at timestamptz DEFAULT NULL,
  p_note text DEFAULT NULL
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, public, pg_temp
AS $$
DECLARE
  v_shop public.shops;
  v_status text := nullif(lower(btrim(p_status)), '');
BEGIN
  IF NOT public.is_platform_admin() THEN
    RAISE EXCEPTION 'Only platform administrators can update subscriptions.';
  END IF;
  IF p_price_ksh IS NOT NULL AND p_price_ksh <= 0 THEN
    RAISE EXCEPTION 'Subscription price must be greater than zero.';
  END IF;
  IF p_plan_days IS NOT NULL AND p_plan_days <= 0 THEN
    RAISE EXCEPTION 'Subscription plan days must be greater than zero.';
  END IF;
  IF v_status IS NOT NULL AND v_status NOT IN ('trial', 'active', 'expired') THEN
    RAISE EXCEPTION 'Invalid subscription status: %.', v_status;
  END IF;

  UPDATE public.shops
  SET subscription_price_ksh = coalesce(p_price_ksh, subscription_price_ksh),
      subscription_ends_at = coalesce(p_ends_at, subscription_ends_at),
      subscription_status = coalesce(v_status, subscription_status),
      subscription_plan_days = coalesce(p_plan_days, subscription_plan_days),
      trial_ends_at = coalesce(p_trial_ends_at, trial_ends_at),
      custom_billing_note = coalesce(p_note, custom_billing_note)
  WHERE id = p_shop_id
  RETURNING * INTO v_shop;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'Business not found.';
  END IF;

  PERFORM public.write_audit_event(
    p_shop_id,
    'subscription_updated',
    'shop',
    NULL,
    jsonb_build_object(
      'price_ksh', p_price_ksh,
      'ends_at', p_ends_at,
      'status', v_status,
      'plan_days', p_plan_days,
      'trial_ends_at', p_trial_ends_at
    )
  );

  RETURN jsonb_build_object(
    'success', true,
    'shop_id', v_shop.id,
    'subscription_status', v_shop.subscription_status,
    'subscription_price_ksh', v_shop.subscription_price_ksh,
    'subscription_ends_at', v_shop.subscription_ends_at,
    'trial_ends_at', v_shop.trial_ends_at,
    'subscription_plan_days', v_shop.subscription_plan_days,
    'custom_billing_note', v_shop.custom_billing_note
  );
END;
$$;

REVOKE ALL ON FUNCTION public.admin_update_shop_subscription(uuid, integer, timestamptz, text, integer, timestamptz, text)
  FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.admin_update_shop_subscription(uuid, integer, timestamptz, text, integer, timestamptz, text)
  TO authenticated, service_role;

NOTIFY pgrst, 'reload schema';
