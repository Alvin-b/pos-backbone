ALTER TABLE public.shops
  ADD COLUMN IF NOT EXISTS subscription_status text NOT NULL DEFAULT 'trial',
  ADD COLUMN IF NOT EXISTS trial_ends_at timestamptz,
  ADD COLUMN IF NOT EXISTS subscription_ends_at timestamptz,
  ADD COLUMN IF NOT EXISTS subscription_price_ksh integer NOT NULL DEFAULT 2500,
  ADD COLUMN IF NOT EXISTS subscription_plan_days integer NOT NULL DEFAULT 30,
  ADD COLUMN IF NOT EXISTS last_payment_at timestamptz,
  ADD COLUMN IF NOT EXISTS last_payment_receipt text,
  ADD COLUMN IF NOT EXISTS last_payment_phone text;

UPDATE public.shops
SET trial_ends_at = created_at + interval '14 days'
WHERE trial_ends_at IS NULL;

ALTER TABLE public.shops
  ALTER COLUMN trial_ends_at SET DEFAULT (now() + interval '14 days');

CREATE TABLE IF NOT EXISTS public.mpesa_subscription_payments (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  shop_id uuid NOT NULL REFERENCES public.shops(id) ON DELETE CASCADE,
  initiated_by uuid NOT NULL,
  phone_number text NOT NULL CHECK (phone_number ~ '^254[17][0-9]{8}$'),
  amount_ksh integer NOT NULL CHECK (amount_ksh > 0),
  plan_days integer NOT NULL CHECK (plan_days BETWEEN 1 AND 365),
  merchant_request_id text,
  checkout_request_id text UNIQUE,
  mpesa_receipt text UNIQUE,
  status text NOT NULL DEFAULT 'initiating' CHECK (status IN ('initiating','pending','paid','failed')),
  result_code integer,
  result_description text,
  transaction_at timestamptz,
  created_at timestamptz NOT NULL DEFAULT now(),
  completed_at timestamptz
);

CREATE INDEX IF NOT EXISTS mpesa_subscription_payments_shop_time_idx
  ON public.mpesa_subscription_payments(shop_id, created_at DESC);
CREATE INDEX IF NOT EXISTS mpesa_subscription_payments_pending_idx
  ON public.mpesa_subscription_payments(checkout_request_id) WHERE status = 'pending';

ALTER TABLE public.mpesa_subscription_payments ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON public.mpesa_subscription_payments FROM PUBLIC, anon, authenticated;
GRANT ALL ON public.mpesa_subscription_payments TO service_role;

CREATE OR REPLACE FUNCTION public.get_shop_subscription_status(p_shop_id uuid)
RETURNS jsonb
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = pg_catalog, public, pg_temp
AS $$
DECLARE
  shop_row public.shops;
  role_name text;
  effective_status text;
  latest_payment public.mpesa_subscription_payments;
  effective_end timestamptz;
BEGIN
  IF auth.uid() IS NULL THEN RAISE EXCEPTION 'not_authenticated'; END IF;
  SELECT m.role::text INTO role_name
  FROM public.shop_members m
  WHERE m.shop_id = p_shop_id AND m.user_id = auth.uid();
  IF role_name IS DISTINCT FROM 'owner' AND NOT public.is_platform_admin() THEN
    RAISE EXCEPTION 'owner_or_platform_admin_required';
  END IF;

  SELECT * INTO shop_row FROM public.shops WHERE id = p_shop_id;
  IF NOT FOUND THEN RAISE EXCEPTION 'business_not_found'; END IF;

  effective_end := greatest(
    coalesce(shop_row.subscription_ends_at, '-infinity'::timestamptz),
    coalesce(shop_row.trial_ends_at, '-infinity'::timestamptz)
  );
  effective_status := CASE
    WHEN shop_row.subscription_ends_at > now() THEN 'active'
    WHEN shop_row.trial_ends_at > now() THEN 'trial'
    ELSE 'expired'
  END;

  SELECT * INTO latest_payment
  FROM public.mpesa_subscription_payments p
  WHERE p.shop_id = p_shop_id
  ORDER BY p.created_at DESC
  LIMIT 1;

  RETURN jsonb_build_object(
    'shop_id', shop_row.id,
    'shop_name', shop_row.name,
    'status', effective_status,
    'is_entitled', effective_status IN ('active','trial'),
    'days_left', greatest(0, ceil(extract(epoch FROM (effective_end - now())) / 86400.0)::integer),
    'trial_ends_at', shop_row.trial_ends_at,
    'subscription_ends_at', shop_row.subscription_ends_at,
    'subscription_price_ksh', shop_row.subscription_price_ksh,
    'subscription_plan_days', shop_row.subscription_plan_days,
    'last_payment_at', shop_row.last_payment_at,
    'last_payment_receipt', shop_row.last_payment_receipt,
    'latest_checkout_request_id', latest_payment.checkout_request_id,
    'latest_payment_status', latest_payment.status
  );
END $$;

REVOKE ALL ON FUNCTION public.get_shop_subscription_status(uuid) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.get_shop_subscription_status(uuid) TO authenticated;

CREATE OR REPLACE FUNCTION public.finalize_mpesa_subscription_payment(
  p_checkout_request_id text,
  p_mpesa_receipt text,
  p_amount_ksh integer,
  p_phone_number text,
  p_result_code integer
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, public, pg_temp
AS $$
DECLARE
  payment_row public.mpesa_subscription_payments;
  normalized_phone text := regexp_replace(coalesce(p_phone_number, ''), '[^0-9]', '', 'g');
BEGIN
  IF coalesce(p_checkout_request_id, '') = '' OR coalesce(p_mpesa_receipt, '') = '' THEN
    RAISE EXCEPTION 'missing_mpesa_transaction_fields';
  END IF;
  IF p_result_code <> 0 THEN RAISE EXCEPTION 'mpesa_payment_not_successful'; END IF;

  SELECT * INTO payment_row
  FROM public.mpesa_subscription_payments
  WHERE checkout_request_id = p_checkout_request_id
  FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'payment_not_found'; END IF;

  IF payment_row.status = 'paid' THEN
    IF payment_row.mpesa_receipt = p_mpesa_receipt THEN
      RETURN jsonb_build_object('success', true, 'already_processed', true);
    END IF;
    RAISE EXCEPTION 'payment_already_finalized';
  END IF;
  IF payment_row.status <> 'pending' THEN RAISE EXCEPTION 'payment_not_pending'; END IF;
  IF p_amount_ksh <> payment_row.amount_ksh THEN RAISE EXCEPTION 'payment_amount_mismatch'; END IF;
  IF normalized_phone <> payment_row.phone_number THEN RAISE EXCEPTION 'payment_phone_mismatch'; END IF;

  UPDATE public.mpesa_subscription_payments
  SET status = 'paid', mpesa_receipt = p_mpesa_receipt, result_code = 0,
      result_description = 'Safaricom STK Query confirmed the payment.',
      completed_at = now(), transaction_at = now()
  WHERE id = payment_row.id;

  UPDATE public.shops
  SET subscription_status = 'active',
      subscription_ends_at = greatest(
        coalesce(subscription_ends_at, '-infinity'::timestamptz),
        coalesce(trial_ends_at, '-infinity'::timestamptz),
        now()
      ) + make_interval(days => payment_row.plan_days),
      last_payment_at = now(),
      last_payment_receipt = p_mpesa_receipt,
      last_payment_phone = normalized_phone
  WHERE id = payment_row.shop_id;

  RETURN jsonb_build_object('success', true, 'already_processed', false);
END $$;

REVOKE ALL ON FUNCTION public.finalize_mpesa_subscription_payment(text, text, integer, text, integer) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.finalize_mpesa_subscription_payment(text, text, integer, text, integer) TO service_role;

CREATE OR REPLACE FUNCTION public.my_account()
RETURNS json
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = pg_catalog, public, pg_temp
AS $$
DECLARE result json;
BEGIN
  IF auth.uid() IS NULL THEN RAISE EXCEPTION 'not_authenticated'; END IF;
  SELECT json_build_object(
    'user_id', auth.uid(),
    'email', (SELECT u.email FROM auth.users u WHERE u.id = auth.uid()),
    'is_platform_admin', public.is_platform_admin(),
    'memberships', coalesce((
      SELECT json_agg(json_build_object(
        'shop_id', m.shop_id,
        'shop_name', s.name,
        'role', m.role,
        'status', s.status,
        'employment_status', m.employment_status,
        'business_type', s.business_type,
        'business_size', s.business_size,
        'feature_flags', s.feature_flags,
        'currency', s.currency,
        'low_stock_threshold', s.low_stock_threshold,
        'counter_inventory_mode', s.counter_inventory_mode,
        'owner_phone', CASE WHEN m.role::text = 'owner' THEN s.owner_phone ELSE NULL END,
        'subscription_status', CASE
          WHEN s.subscription_ends_at > now() THEN 'active'
          WHEN s.trial_ends_at > now() THEN 'trial'
          ELSE 'expired'
        END,
        'trial_ends_at', s.trial_ends_at,
        'subscription_ends_at', s.subscription_ends_at,
        'subscription_price_ksh', s.subscription_price_ksh,
        'subscription_plan_days', s.subscription_plan_days,
        'last_payment_at', s.last_payment_at,
        'last_payment_receipt', s.last_payment_receipt,
        'last_payment_phone', s.last_payment_phone,
        'last_verified_entitlement_at', extract(epoch FROM now())::bigint * 1000,
        'counter_count', (
          SELECT count(*)::integer FROM public.service_counters c
          WHERE c.shop_id = s.id AND c.active
        )
      ) ORDER BY s.created_at DESC)
      FROM public.shop_members m
      JOIN public.shops s ON s.id = m.shop_id
      WHERE m.user_id = auth.uid()
    ), '[]'::json)
  ) INTO result;
  RETURN result;
END $$;

REVOKE ALL ON FUNCTION public.my_account() FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.my_account() TO authenticated;
NOTIFY pgrst, 'reload schema';
