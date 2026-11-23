-- Enforce the butchery package entitlement at the sale RPC boundary.
-- Cashiers remain enrolled through the shared waiter/cashier flow, but cannot
-- sell through a disabled workspace or bypass the Android feature gate.
CREATE OR REPLACE FUNCTION public.record_butchery_sale(
  _shop uuid, _cut_id text, _weight_grams integer, _payment_method text, _entry_mode text,
  _operation_id text DEFAULT NULL, _cut_name text DEFAULT NULL, _category text DEFAULT NULL,
  _price_per_kg_ksh integer DEFAULT NULL, _total_ksh integer DEFAULT NULL, _attendant_name text DEFAULT NULL
)
RETURNS public.butchery_sales LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE cut_row public.butchery_cuts; existing public.butchery_sales; result public.butchery_sales;
DECLARE total_value integer; operation_key text;
BEGIN
  IF NOT public.has_shop_role(_shop, ARRAY['owner','manager','cashier']::public.shop_role[]) AND NOT public.is_platform_admin() THEN RAISE EXCEPTION 'forbidden'; END IF;
  IF NOT public.is_platform_admin() AND NOT EXISTS (
    SELECT 1 FROM public.butchery_config WHERE shop_id = _shop AND enabled
  ) THEN RAISE EXCEPTION 'butchery_disabled'; END IF;
  IF _weight_grams IS NULL OR _weight_grams <= 0 THEN RAISE EXCEPTION 'invalid_weight'; END IF;
  operation_key := coalesce(nullif(trim(_operation_id), ''), gen_random_uuid()::text);
  SELECT * INTO existing FROM public.butchery_sales WHERE shop_id = _shop AND operation_id = operation_key;
  IF existing.id IS NOT NULL THEN
    IF existing.cut_id <> _cut_id OR existing.weight_grams <> _weight_grams OR existing.total_ksh <> coalesce(_total_ksh, existing.total_ksh) THEN RAISE EXCEPTION 'operation_payload_mismatch'; END IF;
    RETURN existing;
  END IF;
  SELECT * INTO cut_row FROM public.butchery_cuts WHERE id = _cut_id AND shop_id = _shop AND active FOR UPDATE;
  IF cut_row.id IS NULL THEN RAISE EXCEPTION 'cut_not_found'; END IF;
  IF cut_row.stock_grams < _weight_grams THEN RAISE EXCEPTION 'insufficient_stock'; END IF;
  total_value := coalesce(_total_ksh, ((_weight_grams::numeric * coalesce(_price_per_kg_ksh, cut_row.price_per_kg_ksh) / 1000)::numeric)::integer);
  IF total_value < 0 THEN RAISE EXCEPTION 'invalid_total'; END IF;
  UPDATE public.butchery_cuts SET stock_grams = stock_grams - _weight_grams, updated_at = now() WHERE id = cut_row.id;
  INSERT INTO public.butchery_sales(shop_id, operation_id, cut_id, cut_name, category, price_per_kg_ksh, weight_grams, total_ksh, payment_method, entry_mode, stock_deducted_grams, attendant_user_id, attendant_name)
  VALUES (_shop, operation_key, cut_row.id, coalesce(nullif(trim(_cut_name), ''), cut_row.name), coalesce(nullif(trim(_category), ''), cut_row.category), coalesce(_price_per_kg_ksh, cut_row.price_per_kg_ksh), _weight_grams, total_value, coalesce(nullif(trim(_payment_method), ''), 'cash'), coalesce(nullif(trim(_entry_mode), ''), 'weight'), _weight_grams, auth.uid(), nullif(trim(_attendant_name), ''))
  RETURNING * INTO result;
  PERFORM public.write_audit_event(_shop, 'butchery_sale_recorded', 'butchery_sale', NULL, jsonb_build_object('sale_id', result.id, 'cut_id', result.cut_id, 'weight_grams', result.weight_grams, 'operation_id', result.operation_id));
  RETURN result;
EXCEPTION WHEN unique_violation THEN
  SELECT * INTO existing FROM public.butchery_sales WHERE shop_id = _shop AND operation_id = operation_key;
  IF existing.id IS NOT NULL THEN RETURN existing; END IF;
  RAISE;
END $$;

GRANT EXECUTE ON FUNCTION public.record_butchery_sale(uuid, text, integer, text, text, text, text, text, integer, integer, text) TO authenticated, service_role;
NOTIFY pgrst, 'reload schema';
