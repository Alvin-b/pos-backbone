-- Enforce trial/paid entitlement at the database boundary, not only in the APK.
-- The owner account/bootstrap and subscription RPCs remain available so a locked
-- tenant can view its status and pay. The local Android outbox retains rejected
-- operations and retries them after entitlement is restored.

CREATE OR REPLACE FUNCTION public.has_current_shop_subscription(_shop uuid)
RETURNS boolean
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = pg_catalog, public, pg_temp
AS $$
  SELECT EXISTS (
    SELECT 1
    FROM public.shops s
    WHERE s.id = _shop
      AND greatest(
        coalesce(s.subscription_ends_at, '-infinity'::timestamptz),
        coalesce(s.trial_ends_at, '-infinity'::timestamptz)
      ) > now()
  )
$$;

REVOKE ALL ON FUNCTION public.has_current_shop_subscription(uuid) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.has_current_shop_subscription(uuid) TO service_role;

CREATE OR REPLACE FUNCTION public.is_shop_active(_shop uuid)
RETURNS boolean
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = pg_catalog, public, pg_temp
AS $$
  SELECT EXISTS (
    SELECT 1 FROM public.shops s
    WHERE s.id = _shop
      AND s.status = 'active'
      AND NOT s.payment_lock_active
  ) AND public.has_current_shop_subscription(_shop)
$$;

REVOKE ALL ON FUNCTION public.is_shop_active(uuid) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.is_shop_active(uuid) TO authenticated, service_role;

CREATE OR REPLACE FUNCTION public.reject_unentitled_shop_mutation()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, public, pg_temp
AS $$
DECLARE
  target_shop uuid;
BEGIN
  IF auth.role() = 'service_role' OR public.is_platform_admin() THEN
    RETURN CASE WHEN TG_OP = 'DELETE' THEN OLD ELSE NEW END;
  END IF;

  target_shop := CASE WHEN TG_OP = 'DELETE' THEN OLD.shop_id ELSE NEW.shop_id END;
  IF NOT EXISTS (
    SELECT 1 FROM public.shops s WHERE s.id = target_shop AND s.status = 'active'
  ) THEN
    RAISE EXCEPTION 'business_not_active' USING ERRCODE = 'P0001';
  END IF;
  IF NOT public.has_current_shop_subscription(target_shop) THEN
    RAISE EXCEPTION 'subscription_expired' USING ERRCODE = 'P0001';
  END IF;
  RETURN CASE WHEN TG_OP = 'DELETE' THEN OLD ELSE NEW END;
END $$;

-- Defense in depth for SECURITY DEFINER RPCs and direct PostgREST mutations.
-- Account/authentication and subscription-payment records are intentionally not
-- gated, so an owner can renew while the business workspace is locked.
DO $$
DECLARE table_name text;
BEGIN
  FOREACH table_name IN ARRAY ARRAY[
    'products','sales','stock_receipts','stock_batches','dining_tables','table_orders',
    'service_counters','counter_stock_balances','counter_stock_movements',
    'table_bill_settlements','client_operations','shop_business_hours','employee_working_hours'
  ] LOOP
    EXECUTE format('DROP TRIGGER IF EXISTS subscription_entitlement_guard ON public.%I', table_name);
    EXECUTE format(
      'CREATE TRIGGER subscription_entitlement_guard BEFORE INSERT OR UPDATE OR DELETE ON public.%I FOR EACH ROW EXECUTE FUNCTION public.reject_unentitled_shop_mutation()',
      table_name
    );
  END LOOP;
END $$;

COMMENT ON FUNCTION public.has_current_shop_subscription(uuid) IS
  'True only for active lifecycle businesses within their trial or paid-through window; used by RLS/access helpers and mutation guards.';
COMMENT ON FUNCTION public.reject_unentitled_shop_mutation() IS
  'Prevents tenant data mutations after trial/subscription expiry while leaving local Android outbox records on-device for retry after renewal.';
NOTIFY pgrst, 'reload schema';
