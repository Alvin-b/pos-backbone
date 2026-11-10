-- Superadmin-controlled payment lock for a tenant business.
-- A lock is separate from normal subscription expiry so an administrator can
-- require a specific amount while disabling POS operations for every member.

ALTER TABLE public.shops
  ADD COLUMN IF NOT EXISTS payment_lock_active boolean NOT NULL DEFAULT false,
  ADD COLUMN IF NOT EXISTS payment_lock_amount_ksh integer NOT NULL DEFAULT 0,
  ADD COLUMN IF NOT EXISTS payment_lock_reason text,
  ADD COLUMN IF NOT EXISTS payment_lock_started_at timestamptz,
  ADD COLUMN IF NOT EXISTS payment_lock_started_by uuid;

CREATE OR REPLACE FUNCTION public.admin_set_shop_payment_lock(
  p_shop_id uuid,
  p_locked boolean,
  p_amount_ksh integer DEFAULT NULL,
  p_reason text DEFAULT NULL
)
RETURNS json
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE
  row public.shops;
  amount integer := coalesce(p_amount_ksh, 0);
  reason text := nullif(trim(coalesce(p_reason, '')), '');
BEGIN
  IF NOT public.is_platform_admin() THEN RAISE EXCEPTION 'forbidden'; END IF;
  IF p_locked AND (amount < 1 OR amount > 250000) THEN
    RAISE EXCEPTION 'payment_lock_amount_invalid';
  END IF;

  UPDATE public.shops
  SET payment_lock_active = p_locked,
      payment_lock_amount_ksh = CASE WHEN p_locked THEN amount ELSE 0 END,
      payment_lock_reason = CASE WHEN p_locked THEN reason ELSE NULL END,
      payment_lock_started_at = CASE WHEN p_locked THEN now() ELSE NULL END,
      payment_lock_started_by = CASE WHEN p_locked THEN auth.uid() ELSE NULL END
  WHERE id = p_shop_id
  RETURNING * INTO row;

  IF NOT FOUND THEN RAISE EXCEPTION 'business_not_found'; END IF;

  PERFORM public.write_audit_event(
    p_shop_id,
    CASE WHEN p_locked THEN 'business_payment_lock_started' ELSE 'business_payment_lock_cleared' END,
    'shop',
    p_shop_id,
    jsonb_build_object('amount_ksh', CASE WHEN p_locked THEN amount ELSE 0 END, 'reason', reason)
  );

  RETURN json_build_object(
    'shop_id', row.id,
    'payment_lock_active', row.payment_lock_active,
    'payment_lock_amount_ksh', row.payment_lock_amount_ksh,
    'payment_lock_reason', row.payment_lock_reason,
    'payment_lock_started_at', row.payment_lock_started_at
  );
END $$;

REVOKE ALL ON FUNCTION public.admin_set_shop_payment_lock(uuid, boolean, integer, text) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.admin_set_shop_payment_lock(uuid, boolean, integer, text) TO authenticated;

-- Include lock information in the owner/employee bootstrap payload.
CREATE OR REPLACE FUNCTION public.my_account()
RETURNS json
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = pg_catalog, public, pg_temp AS $$
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
        'counter_inventory_mode', s.counter_inventory_mode,
        'feature_flags', s.feature_flags,
        'currency', s.currency,
        'low_stock_threshold', s.low_stock_threshold,
        'owner_phone', CASE WHEN m.role::text = 'owner' THEN s.owner_phone ELSE NULL END,
        'payment_lock_active', s.payment_lock_active,
        'payment_lock_amount_ksh', s.payment_lock_amount_ksh,
        'payment_lock_reason', s.payment_lock_reason,
        'payment_lock_started_at', s.payment_lock_started_at,
        'subscription_status', CASE WHEN s.payment_lock_active THEN 'payment_locked'
          WHEN s.subscription_ends_at > now() THEN 'active'
          WHEN s.trial_ends_at > now() THEN 'trial' ELSE 'expired' END,
        'trial_ends_at', s.trial_ends_at,
        'subscription_ends_at', s.subscription_ends_at,
        'subscription_price_ksh', s.subscription_price_ksh,
        'subscription_plan_days', s.subscription_plan_days,
        'last_payment_at', s.last_payment_at,
        'last_payment_receipt', s.last_payment_receipt,
        'last_payment_phone', s.last_payment_phone,
        'last_verified_entitlement_at', extract(epoch FROM now())::bigint * 1000,
        'counter_count', (SELECT count(*)::integer FROM public.service_counters c WHERE c.shop_id = s.id AND c.active)
      ) ORDER BY s.created_at DESC)
      FROM public.shop_members m JOIN public.shops s ON s.id = m.shop_id WHERE m.user_id = auth.uid()
    ), '[]'::json)
  ) INTO result;
  RETURN result;
END $$;
REVOKE ALL ON FUNCTION public.my_account() FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.my_account() TO authenticated;

CREATE OR REPLACE FUNCTION public.get_shop_subscription_status(p_shop_id uuid)
RETURNS jsonb LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = pg_catalog, public, pg_temp AS $$
DECLARE shop_row public.shops; role_name text; effective_status text; latest_payment public.mpesa_subscription_payments; effective_end timestamptz;
BEGIN
  IF auth.uid() IS NULL THEN RAISE EXCEPTION 'not_authenticated'; END IF;
  SELECT m.role::text INTO role_name FROM public.shop_members m WHERE m.shop_id=p_shop_id AND m.user_id=auth.uid();
  IF role_name IS DISTINCT FROM 'owner' AND NOT public.is_platform_admin() THEN RAISE EXCEPTION 'owner_or_platform_admin_required'; END IF;
  SELECT * INTO shop_row FROM public.shops WHERE id=p_shop_id;
  IF NOT FOUND THEN RAISE EXCEPTION 'business_not_found'; END IF;
  effective_end := greatest(coalesce(shop_row.subscription_ends_at, '-infinity'::timestamptz), coalesce(shop_row.trial_ends_at, '-infinity'::timestamptz));
  effective_status := CASE WHEN shop_row.payment_lock_active THEN 'payment_locked' WHEN shop_row.subscription_ends_at > now() THEN 'active' WHEN shop_row.trial_ends_at > now() THEN 'trial' ELSE 'expired' END;
  SELECT * INTO latest_payment FROM public.mpesa_subscription_payments p WHERE p.shop_id=p_shop_id ORDER BY p.created_at DESC LIMIT 1;
  RETURN jsonb_build_object('shop_id',shop_row.id,'shop_name',shop_row.name,'status',effective_status,'is_entitled',effective_status IN ('active','trial'),
    'days_left',greatest(0,ceil(extract(epoch FROM (effective_end-now()))/86400.0)::integer),'trial_ends_at',shop_row.trial_ends_at,'subscription_ends_at',shop_row.subscription_ends_at,
    'subscription_price_ksh',CASE WHEN shop_row.payment_lock_active AND shop_row.payment_lock_amount_ksh > 0 THEN shop_row.payment_lock_amount_ksh ELSE shop_row.subscription_price_ksh END,
    'subscription_plan_days',shop_row.subscription_plan_days,'last_payment_at',shop_row.last_payment_at,'last_payment_receipt',shop_row.last_payment_receipt,
    'latest_checkout_request_id',latest_payment.checkout_request_id,'latest_payment_status',latest_payment.status,
    'payment_lock_active',shop_row.payment_lock_active,'payment_lock_amount_ksh',shop_row.payment_lock_amount_ksh,'payment_lock_reason',shop_row.payment_lock_reason);
END $$;
REVOKE ALL ON FUNCTION public.get_shop_subscription_status(uuid) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.get_shop_subscription_status(uuid) TO authenticated;

-- Replace the admin portfolio projection with lock columns while preserving its API.
DROP FUNCTION IF EXISTS public.admin_list_businesses();
CREATE FUNCTION public.admin_list_businesses()
RETURNS TABLE(
  shop_id uuid, shop_name text, status text, business_type text, business_size text, feature_flags jsonb,
  owner_email text, member_count bigint, product_count bigint, stock_units bigint,
  created_at timestamptz, suspended_at timestamptz, closed_at timestamptz, lifecycle_reason text,
  counter_inventory_mode text, counter_count bigint, subscription_status text, trial_ends_at timestamptz,
  subscription_ends_at timestamptz, subscription_price_ksh integer, subscription_plan_days integer,
  last_payment_at timestamptz, last_payment_receipt text, last_payment_phone text, custom_billing_note text,
  payment_lock_active boolean, payment_lock_amount_ksh integer, payment_lock_reason text, payment_lock_started_at timestamptz
)
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
BEGIN
  IF NOT public.is_platform_admin() THEN RAISE EXCEPTION 'forbidden'; END IF;
  RETURN QUERY SELECT s.id, s.name, s.status, s.business_type, s.business_size, s.feature_flags,
    coalesce(s.owner_email, (SELECT u.email FROM auth.users u JOIN public.shop_members om ON om.user_id=u.id WHERE om.shop_id=s.id AND om.role='owner' AND om.employment_status <> 'terminated' LIMIT 1), 'Pending owner enrollment'),
    (SELECT count(*) FROM public.shop_members m WHERE m.shop_id=s.id AND m.employment_status <> 'terminated' AND NOT EXISTS (SELECT 1 FROM public.platform_admins pa WHERE pa.user_id=m.user_id)),
    (SELECT count(*) FROM public.products p WHERE p.shop_id=s.id AND NOT p.archived),
    (SELECT coalesce(sum(p.stock),0) FROM public.products p WHERE p.shop_id=s.id AND NOT p.archived),
    s.created_at, s.suspended_at, s.closed_at, coalesce(s.suspension_reason,s.closure_reason), s.counter_inventory_mode,
    (SELECT count(*) FROM public.service_counters c WHERE c.shop_id=s.id AND c.active),
    CASE WHEN s.payment_lock_active THEN 'payment_locked' WHEN s.subscription_ends_at > now() THEN 'active' WHEN s.trial_ends_at > now() THEN 'trial' ELSE 'expired' END,
    s.trial_ends_at, s.subscription_ends_at, s.subscription_price_ksh, s.subscription_plan_days, s.last_payment_at, s.last_payment_receipt, s.last_payment_phone,
    NULL::text, s.payment_lock_active, s.payment_lock_amount_ksh, s.payment_lock_reason, s.payment_lock_started_at
  FROM public.shops s ORDER BY s.created_at DESC;
END $$;
REVOKE ALL ON FUNCTION public.admin_list_businesses() FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.admin_list_businesses() TO authenticated;

CREATE OR REPLACE FUNCTION public.reject_payment_locked_mutation()
RETURNS trigger
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE target_shop uuid;
BEGIN
  IF public.is_platform_admin() THEN
    RETURN CASE WHEN TG_OP = 'DELETE' THEN OLD ELSE NEW END;
  END IF;
  target_shop := CASE WHEN TG_OP = 'DELETE' THEN OLD.shop_id ELSE NEW.shop_id END;
  IF EXISTS (SELECT 1 FROM public.shops WHERE id = target_shop AND payment_lock_active) THEN
    RAISE EXCEPTION 'business_payment_locked';
  END IF;
  RETURN CASE WHEN TG_OP = 'DELETE' THEN OLD ELSE NEW END;
END $$;

-- These are the tables that mutate inventory, sales, tables, counters, and
-- tenant operations. Authentication/account and payment tables remain usable
-- so the owner can pay and every member can see the lock notice.
DO $$
DECLARE table_name text;
BEGIN
  FOREACH table_name IN ARRAY ARRAY[
    'products','sales','stock_receipts','stock_batches','dining_tables','table_orders',
    'service_counters','counter_stock_balances','counter_stock_movements',
    'table_bill_settlements','client_operations','shop_business_hours','employee_working_hours'
  ] LOOP
    EXECUTE format('DROP TRIGGER IF EXISTS payment_lock_guard ON public.%I', table_name);
    EXECUTE format('CREATE TRIGGER payment_lock_guard BEFORE INSERT OR UPDATE OR DELETE ON public.%I FOR EACH ROW EXECUTE FUNCTION public.reject_payment_locked_mutation()', table_name);
  END LOOP;
END $$;

-- A successful subscription payment clears a superadmin payment lock.
CREATE OR REPLACE FUNCTION public.finalize_mpesa_subscription_payment(
  p_checkout_request_id text, p_mpesa_receipt text, p_amount_ksh integer,
  p_phone_number text, p_result_code integer
)
RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path = pg_catalog, public, pg_temp AS $$
DECLARE payment_row public.mpesa_subscription_payments; normalized_phone text := regexp_replace(coalesce(p_phone_number, ''), '[^0-9]', '', 'g');
BEGIN
  IF coalesce(p_checkout_request_id, '') = '' OR coalesce(p_mpesa_receipt, '') = '' THEN RAISE EXCEPTION 'missing_mpesa_transaction_fields'; END IF;
  IF p_result_code <> 0 THEN RAISE EXCEPTION 'mpesa_payment_not_successful'; END IF;
  SELECT * INTO payment_row FROM public.mpesa_subscription_payments WHERE checkout_request_id = p_checkout_request_id FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'payment_not_found'; END IF;
  IF payment_row.status = 'paid' THEN
    IF payment_row.mpesa_receipt = p_mpesa_receipt THEN RETURN jsonb_build_object('success', true, 'already_processed', true); END IF;
    RAISE EXCEPTION 'payment_already_finalized';
  END IF;
  IF payment_row.status <> 'pending' THEN RAISE EXCEPTION 'payment_not_pending'; END IF;
  IF p_amount_ksh <> payment_row.amount_ksh THEN RAISE EXCEPTION 'payment_amount_mismatch'; END IF;
  IF normalized_phone <> payment_row.phone_number THEN RAISE EXCEPTION 'payment_phone_mismatch'; END IF;
  UPDATE public.mpesa_subscription_payments SET status = 'paid', mpesa_receipt = p_mpesa_receipt, result_code = 0,
    result_description = 'Safaricom STK Query confirmed the payment.', completed_at = now(), transaction_at = now() WHERE id = payment_row.id;
  UPDATE public.shops SET subscription_status = 'active', subscription_ends_at = greatest(coalesce(subscription_ends_at, '-infinity'::timestamptz), coalesce(trial_ends_at, '-infinity'::timestamptz), now()) + make_interval(days => payment_row.plan_days),
    last_payment_at = now(), last_payment_receipt = p_mpesa_receipt, last_payment_phone = normalized_phone,
    payment_lock_active = false, payment_lock_amount_ksh = 0, payment_lock_reason = NULL, payment_lock_started_at = NULL, payment_lock_started_by = NULL
    WHERE id = payment_row.shop_id;
  RETURN jsonb_build_object('success', true, 'already_processed', false);
END $$;
REVOKE ALL ON FUNCTION public.finalize_mpesa_subscription_payment(text,text,integer,text,integer) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.finalize_mpesa_subscription_payment(text,text,integer,text,integer) TO service_role;
NOTIFY pgrst, 'reload schema';
