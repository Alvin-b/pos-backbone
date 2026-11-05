-- Counter sales must record whether the customer paid with cash or M-Pesa.
ALTER TABLE public.sales
  ADD COLUMN IF NOT EXISTS payment_method text NOT NULL DEFAULT 'cash';

UPDATE public.sales
SET payment_method = 'cash'
WHERE payment_method IS NULL OR lower(trim(payment_method)) NOT IN ('cash', 'mpesa');

ALTER TABLE public.sales
  DROP CONSTRAINT IF EXISTS sales_payment_method_check;
ALTER TABLE public.sales
  ADD CONSTRAINT sales_payment_method_check
  CHECK (payment_method IN ('cash', 'mpesa'));

-- Six-argument overloads preserve compatibility with older clients that still
-- call the original five/seven-argument RPCs; new Android clients send the
-- selected payment method explicitly.
CREATE OR REPLACE FUNCTION public.record_sale_unit_from_counter(
  _product uuid, _counter uuid, _qty int,
  _unit_name text, _unit_price int,
  _payment_method text
)
RETURNS public.sales
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public
AS $$
DECLARE p public.products; c public.service_counters; s public.sales; method text;
BEGIN
  method := lower(trim(coalesce(_payment_method, '')));
  IF method NOT IN ('cash', 'mpesa') THEN RAISE EXCEPTION 'invalid_payment_method'; END IF;
  SELECT * INTO p FROM public.products WHERE id = _product AND NOT archived;
  IF p.id IS NULL THEN RAISE EXCEPTION 'product_not_found'; END IF;
  SELECT * INTO c FROM public.service_counters WHERE id = _counter AND shop_id = p.shop_id AND active FOR SHARE;
  IF c.id IS NULL THEN RAISE EXCEPTION 'counter_not_found_or_inactive'; END IF;
  IF NOT public.has_shop_role(p.shop_id, ARRAY['owner','manager','cashier']::public.shop_role[]) THEN RAISE EXCEPTION 'forbidden'; END IF;
  PERFORM set_config('counterpos.selected_counter_id', c.id::text, true);
  SELECT * INTO s FROM public.record_sale_unit(_product, _qty, _unit_name, _unit_price);
  UPDATE public.sales SET payment_method = method WHERE id = s.id RETURNING * INTO s;
  RETURN s;
END $$;

CREATE OR REPLACE FUNCTION public.record_table_sale_from_counter(
  _shop uuid, _table uuid, _product uuid, _counter uuid,
  _qty int, _unit_name text, _unit_price int, _payment_method text
)
RETURNS public.table_orders
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public
AS $$
DECLARE c public.service_counters; o public.table_orders; method text;
BEGIN
  method := lower(trim(coalesce(_payment_method, 'cash')));
  IF method NOT IN ('cash', 'mpesa') THEN RAISE EXCEPTION 'invalid_payment_method'; END IF;
  SELECT * INTO c FROM public.service_counters WHERE id = _counter AND shop_id = _shop AND active FOR SHARE;
  IF c.id IS NULL THEN RAISE EXCEPTION 'counter_not_found_or_inactive'; END IF;
  PERFORM set_config('counterpos.selected_counter_id', c.id::text, true);
  SELECT * INTO o FROM public.record_table_sale(_shop, _table, _product, _qty, _unit_name, _unit_price);
  UPDATE public.sales SET payment_method = method WHERE id = o.sale_id;
  RETURN o;
END $$;

GRANT EXECUTE ON FUNCTION public.record_sale_unit_from_counter(uuid,uuid,int,text,int,text) TO authenticated;
GRANT EXECUTE ON FUNCTION public.record_table_sale_from_counter(uuid,uuid,uuid,uuid,int,text,int,text) TO authenticated;

-- Apply the selected payment method to idempotent offline counter sales.
-- Preserve the original idempotency implementation for non-sale operations.
DO $$
BEGIN
  IF to_regprocedure('public.apply_pos_operation_legacy(uuid,uuid,text,jsonb)') IS NULL
     AND to_regprocedure('public.apply_pos_operation(uuid,uuid,text,jsonb)') IS NOT NULL THEN
    EXECUTE 'ALTER FUNCTION public.apply_pos_operation(uuid,uuid,text,jsonb) RENAME TO apply_pos_operation_legacy';
  END IF;
END $$;

ALTER TABLE public.client_operations
  DROP CONSTRAINT IF EXISTS client_operations_kind_check;
ALTER TABLE public.client_operations
  ADD CONSTRAINT client_operations_kind_check CHECK (kind IN (
    'create_dining_table', 'sale', 'table_sale', 'receive_stock',
    'add_catalog_product', 'register_product', 'adjust_stock', 'undo_sale',
    'transfer_stock', 'update_product'
  ));

CREATE OR REPLACE FUNCTION public.apply_pos_operation(
  _shop uuid, _operation_id uuid, _kind text, _payload jsonb
)
RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = pg_catalog, public, pg_temp
AS $$
DECLARE
  actor uuid := auth.uid();
  entry public.client_operations;
  response jsonb;
  request jsonb := _payload;
  method text;
BEGIN
  IF actor IS NULL THEN RAISE EXCEPTION 'not_authenticated'; END IF;
  IF _shop IS NULL OR _operation_id IS NULL THEN RAISE EXCEPTION 'shop_and_operation_id_required'; END IF;
  IF NOT public.is_shop_member(_shop) THEN RAISE EXCEPTION 'forbidden'; END IF;
  IF _kind NOT IN ('sale','table_sale') THEN
    -- Preserve the existing implementation for non-sale operations.
    RETURN public.apply_pos_operation_legacy(_shop, _operation_id, _kind, _payload);
  END IF;
  method := lower(trim(coalesce(request->>'payment_method', 'cash')));
  IF method NOT IN ('cash', 'mpesa') THEN RAISE EXCEPTION 'invalid_payment_method'; END IF;
  request := jsonb_set(request, '{payment_method}', to_jsonb(method), true);
  SELECT * INTO entry FROM public.client_operations WHERE shop_id = _shop AND operation_id = _operation_id FOR UPDATE;
  IF entry.operation_id IS NOT NULL THEN
    IF entry.request_payload IS DISTINCT FROM request OR entry.kind IS DISTINCT FROM _kind THEN RAISE EXCEPTION 'operation_id_reused'; END IF;
    IF entry.completed_at IS NULL THEN RAISE EXCEPTION 'operation_in_progress'; END IF;
    RETURN entry.result;
  END IF;
  INSERT INTO public.client_operations(shop_id, operation_id, actor_user_id, kind, request_payload)
  VALUES (_shop, _operation_id, actor, _kind, request);
  IF _kind = 'sale' THEN
    SELECT to_jsonb(s) INTO response FROM public.record_sale_unit_from_counter(
      (request->>'product_id')::uuid, (request->>'counter_id')::uuid,
      coalesce((request->>'qty')::int, 1), coalesce(request->>'unit_name', 'Bottle'),
      (request->>'unit_price')::int, method) AS s;
  ELSE
    SELECT to_jsonb(o) INTO response FROM public.record_table_sale_from_counter(
      _shop, (request->>'table_id')::uuid, (request->>'product_id')::uuid,
      (request->>'counter_id')::uuid, (request->>'qty')::int,
      request->>'unit_name', (request->>'unit_price')::int, method) AS o;
  END IF;
  UPDATE public.client_operations SET result = response, completed_at = now()
  WHERE shop_id = _shop AND operation_id = _operation_id;
  RETURN response;
EXCEPTION WHEN OTHERS THEN
  DELETE FROM public.client_operations WHERE shop_id = _shop AND operation_id = _operation_id AND completed_at IS NULL;
  RAISE;
END $$;

