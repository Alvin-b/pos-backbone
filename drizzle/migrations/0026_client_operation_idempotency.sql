-- Forward-only Android outbox API. Existing RPC signatures and grants are untouched.
-- A UUID is unique across ALL mutation kinds within a tenant, not just per kind.
-- IF NOT EXISTS keeps this forward repair safe when the table was created by a
-- previous partial deployment.
CREATE TABLE IF NOT EXISTS public.client_operations (
  shop_id uuid NOT NULL REFERENCES public.shops(id) ON DELETE CASCADE,
  operation_id uuid NOT NULL,
  actor_user_id uuid NOT NULL,
  kind text NOT NULL CHECK (kind IN (
    'create_dining_table', 'sale', 'table_sale', 'receive_stock',
    'add_catalog_product', 'register_product', 'adjust_stock', 'undo_sale',
    'transfer_stock', 'update_product'
  )),
  request_payload jsonb NOT NULL CHECK (jsonb_typeof(request_payload) = 'object'),
  result jsonb,
  created_at timestamptz NOT NULL DEFAULT now(),
  completed_at timestamptz,
  PRIMARY KEY (shop_id, operation_id),
  CHECK ((result IS NULL) = (completed_at IS NULL))
);
--> statement-breakpoint
ALTER TABLE public.client_operations ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON public.client_operations FROM PUBLIC, anon, authenticated;
GRANT ALL ON public.client_operations TO service_role;
COMMENT ON TABLE public.client_operations IS
  'Private idempotency ledger. Retain completed rows for the entire client retry lifetime; deleting one permits execution again.';
--> statement-breakpoint
CREATE OR REPLACE FUNCTION public.apply_pos_operation(
  _shop uuid, _operation_id uuid, _kind text, _payload jsonb
)
RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = pg_catalog, public, pg_temp
AS $$
DECLARE
  actor uuid := auth.uid();
  allowed_keys text[];
  required_keys text[];
  defaults jsonb := '{}'::jsonb;
  request jsonb;
  entry public.client_operations;
  response jsonb;
  field record;
  product public.products;
  sale public.sales;
  mode text;
BEGIN
  IF actor IS NULL THEN RAISE EXCEPTION 'not_authenticated'; END IF;
  IF _shop IS NULL OR _operation_id IS NULL THEN
    RAISE EXCEPTION 'shop_and_operation_id_required' USING ERRCODE = '22023';
  END IF;
  IF NOT public.is_shop_member(_shop) THEN RAISE EXCEPTION 'forbidden'; END IF;
  IF _payload IS NULL OR jsonb_typeof(_payload) <> 'object' THEN
    RAISE EXCEPTION 'operation_payload_must_be_object' USING ERRCODE = '22023';
  END IF;

  -- Validate current tenant/role authorization even for a completed replay.
  -- The called business RPCs retain their own checks (including the sale trigger).
  CASE _kind
    WHEN 'create_dining_table' THEN
      IF NOT public.is_shop_manager(_shop) THEN RAISE EXCEPTION 'forbidden'; END IF;
      allowed_keys := ARRAY['name'];
      required_keys := ARRAY['name'];
    WHEN 'sale' THEN
      IF NOT public.has_shop_role(_shop, ARRAY['owner','manager','cashier']::public.shop_role[]) THEN
        RAISE EXCEPTION 'forbidden';
      END IF;
      IF NOT public.can_sell_for_shop(_shop) THEN RAISE EXCEPTION 'seller_not_allowed_now'; END IF;
      allowed_keys := ARRAY['product_id','counter_id','qty','unit_name','unit_price'];
      required_keys := ARRAY['product_id','counter_id'];
      defaults := '{"qty":1,"unit_name":"Bottle","unit_price":null}'::jsonb;
    WHEN 'table_sale' THEN
      IF NOT public.has_shop_role(_shop, ARRAY['owner','manager','cashier']::public.shop_role[]) THEN
        RAISE EXCEPTION 'forbidden';
      END IF;
      IF NOT public.can_sell_for_shop(_shop) THEN RAISE EXCEPTION 'seller_not_allowed_now'; END IF;
      allowed_keys := ARRAY['table_id','product_id','counter_id','qty','unit_name','unit_price'];
      required_keys := allowed_keys;
    WHEN 'receive_stock' THEN
      IF NOT public.is_inventory_operator(_shop) THEN RAISE EXCEPTION 'forbidden'; END IF;
      allowed_keys := ARRAY['counter_id','product_id','qty','unit_cost','supplier','reference','notes'];
      required_keys := ARRAY['counter_id','product_id','qty'];
      defaults := '{"unit_cost":0,"supplier":null,"reference":null,"notes":null}'::jsonb;
    WHEN 'add_catalog_product' THEN
      IF NOT public.is_inventory_operator(_shop) THEN RAISE EXCEPTION 'forbidden'; END IF;
      allowed_keys := ARRAY['catalog_id','counter_id','qty','price','unit_cost'];
      required_keys := ARRAY['catalog_id','counter_id','qty','price'];
      defaults := '{"unit_cost":0}'::jsonb;
    WHEN 'register_product' THEN
      IF NOT public.is_inventory_operator(_shop) THEN RAISE EXCEPTION 'forbidden'; END IF;
      allowed_keys := ARRAY['code','name','price','qty','counter_id','photo_path','unit_cost','size','type','brand','category'];
      required_keys := ARRAY['code','name','price','qty','counter_id','photo_path'];
      defaults := '{"unit_cost":0,"size":null,"type":"beer","brand":null,"category":null}'::jsonb;
    WHEN 'adjust_stock' THEN
      IF NOT public.is_shop_manager(_shop) THEN RAISE EXCEPTION 'forbidden'; END IF;
      allowed_keys := ARRAY['counter_id','product_id','new_stock','reason'];
      required_keys := ARRAY['counter_id','product_id','new_stock'];
      defaults := '{"reason":null}'::jsonb;
    WHEN 'undo_sale' THEN
      IF NOT public.is_shop_manager(_shop) THEN RAISE EXCEPTION 'forbidden'; END IF;
      allowed_keys := ARRAY['sale_id'];
      required_keys := allowed_keys;
    WHEN 'transfer_stock' THEN
      IF NOT public.is_shop_manager(_shop) THEN RAISE EXCEPTION 'forbidden'; END IF;
      allowed_keys := ARRAY['product_id','from_counter_id','to_counter_id','qty','reason'];
      required_keys := ARRAY['product_id','from_counter_id','to_counter_id','qty'];
      defaults := '{"reason":null}'::jsonb;
    WHEN 'update_product' THEN
      -- Direct UPDATE's existing RLS policy is OWNER-only, not manager-only.
      IF NOT public.is_shop_owner(_shop) THEN RAISE EXCEPTION 'forbidden'; END IF;
      allowed_keys := ARRAY['product_id','patch'];
      required_keys := allowed_keys;
    ELSE
      RAISE EXCEPTION 'invalid_operation_kind' USING ERRCODE = '22023';
  END CASE;

  IF EXISTS (SELECT 1 FROM jsonb_object_keys(_payload) AS keys(key) WHERE NOT (key = ANY(allowed_keys))) THEN
    RAISE EXCEPTION 'unknown_operation_payload_field' USING ERRCODE = '22023';
  END IF;
  IF NOT (_payload ?& required_keys) THEN
    RAISE EXCEPTION 'missing_operation_payload_field' USING ERRCODE = '22023';
  END IF;
  request := defaults || _payload;

  -- Canonicalize typed UUIDs and omitted SQL defaults. JSONB compares object key
  -- order independently. Preserve text, explicit nulls, and patch omissions:
  -- omitted patch field = leave unchanged; null = clear it (where nullable).
  FOR field IN SELECT key, value FROM jsonb_each(request) LOOP
    IF field.key = ANY(ARRAY['product_id','counter_id','table_id','catalog_id','sale_id','from_counter_id','to_counter_id']) THEN
      IF jsonb_typeof(field.value) <> 'string' THEN
        RAISE EXCEPTION 'operation_uuid_field_required: %', field.key USING ERRCODE = '22023';
      END IF;
      request := jsonb_set(request, ARRAY[field.key], to_jsonb((field.value #>> '{}')::uuid));
    ELSIF field.key = ANY(ARRAY['qty','price','unit_price','unit_cost','new_stock']) THEN
      IF jsonb_typeof(field.value) NOT IN ('number','null') THEN
        RAISE EXCEPTION 'operation_integer_field_required: %', field.key USING ERRCODE = '22023';
      END IF;
      -- int cast also rejects fractions and values outside the SQL int range.
      IF field.value <> 'null'::jsonb THEN
        request := jsonb_set(request, ARRAY[field.key], to_jsonb((field.value #>> '{}')::int));
      END IF;
    ELSIF field.key = 'patch' THEN
      IF jsonb_typeof(field.value) <> 'object' THEN
        RAISE EXCEPTION 'product_patch_must_be_object' USING ERRCODE = '22023';
      END IF;
    ELSIF jsonb_typeof(field.value) NOT IN ('string','null') THEN
      RAISE EXCEPTION 'operation_text_field_required: %', field.key USING ERRCODE = '22023';
    END IF;
  END LOOP;

  -- Claim BEFORE taking any product/counter/sale locks. A conflicting INSERT
  -- waits for the other transaction. Under READ COMMITTED the following SELECT
  -- sees its committed response; higher isolation may require a normal retry.
  INSERT INTO public.client_operations(shop_id, operation_id, actor_user_id, kind, request_payload)
  VALUES (_shop, _operation_id, actor, _kind, request)
  ON CONFLICT (shop_id, operation_id) DO NOTHING;
  IF NOT FOUND THEN
    SELECT * INTO entry FROM public.client_operations
    WHERE shop_id = _shop AND operation_id = _operation_id FOR UPDATE;
    IF entry.shop_id IS NULL THEN
      RAISE EXCEPTION 'operation_retry_required' USING ERRCODE = '40001';
    END IF;
    IF entry.actor_user_id IS DISTINCT FROM actor
       OR entry.kind IS DISTINCT FROM _kind
       OR entry.request_payload IS DISTINCT FROM request THEN
      RAISE EXCEPTION 'operation_id_reused' USING ERRCODE = '22023';
    END IF;
    IF entry.completed_at IS NULL THEN RAISE EXCEPTION 'operation_in_progress'; END IF;
    RETURN entry.result;
  END IF;

  -- Only first execution validates mutable entity state. A matching completed
  -- replay returns the frozen response even if a product is later archived.
  IF _kind IN ('sale','receive_stock','adjust_stock','update_product') THEN
    SELECT * INTO product FROM public.products
    WHERE id = (request->>'product_id')::uuid AND shop_id = _shop;
    IF product.id IS NULL THEN RAISE EXCEPTION 'product_not_found'; END IF;
  END IF;

  CASE _kind
    WHEN 'create_dining_table' THEN
      SELECT to_jsonb(t) INTO response
      FROM public.create_dining_table(_shop, request->>'name') AS t;
    WHEN 'sale' THEN
      SELECT to_jsonb(s) INTO response FROM public.record_sale_unit_from_counter(
        (request->>'product_id')::uuid, (request->>'counter_id')::uuid,
        (request->>'qty')::int, request->>'unit_name', (request->>'unit_price')::int
      ) AS s;
    WHEN 'table_sale' THEN
      SELECT to_jsonb(o) INTO response FROM public.record_table_sale_from_counter(
        _shop, (request->>'table_id')::uuid, (request->>'product_id')::uuid,
        (request->>'counter_id')::uuid, (request->>'qty')::int,
        request->>'unit_name', (request->>'unit_price')::int
      ) AS o;
    WHEN 'receive_stock' THEN
      SELECT to_jsonb(p) INTO response FROM public.receive_stock_at_counter(
        (request->>'counter_id')::uuid, (request->>'product_id')::uuid,
        (request->>'qty')::int, (request->>'unit_cost')::int,
        request->>'supplier', request->>'reference', request->>'notes'
      ) AS p;
    WHEN 'add_catalog_product' THEN
      SELECT to_jsonb(p) INTO response FROM public.add_from_catalog_at_counter(
        _shop, (request->>'catalog_id')::uuid, (request->>'counter_id')::uuid,
        (request->>'qty')::int, (request->>'price')::int, (request->>'unit_cost')::int
      ) AS p;
    WHEN 'register_product' THEN
      SELECT to_jsonb(p) INTO response FROM public.register_product_at_counter(
        _shop, request->>'code', request->>'name', (request->>'price')::int,
        (request->>'qty')::int, (request->>'counter_id')::uuid, request->>'photo_path',
        (request->>'unit_cost')::int, request->>'size',
        (request->>'type')::public.product_type, request->>'brand', request->>'category'
      ) AS p;
    WHEN 'adjust_stock' THEN
      SELECT to_jsonb(p) INTO response FROM public.adjust_counter_stock(
        (request->>'counter_id')::uuid, (request->>'product_id')::uuid,
        (request->>'new_stock')::int, request->>'reason'
      ) AS p;
    WHEN 'undo_sale' THEN
      -- Never call undo_sale_from_counter(_shop): it chooses the latest sale.
      -- Lock the product first to serialize FIFO restoration with sales/receipts.
      SELECT * INTO sale FROM public.sales
      WHERE id = (request->>'sale_id')::uuid AND shop_id = _shop;
      IF sale.id IS NULL THEN RAISE EXCEPTION 'nothing_to_undo'; END IF;
      PERFORM 1 FROM public.products WHERE id = sale.product_id AND shop_id = _shop FOR UPDATE;
      sale := public.undo_sale(_shop, (request->>'sale_id')::uuid);
      -- Match 0016's counter restoration, using the explicitly undone row.
      SELECT counter_inventory_mode INTO mode FROM public.shops WHERE id = _shop;
      IF mode = 'per_counter' THEN
        IF sale.source_counter_id IS NULL THEN RAISE EXCEPTION 'legacy_sale_has_no_counter'; END IF;
        INSERT INTO public.counter_stock_balances(shop_id, service_counter_id, product_id, quantity)
        VALUES (_shop, sale.source_counter_id, sale.product_id, sale.stock_qty)
        ON CONFLICT (service_counter_id, product_id) DO UPDATE
          SET quantity = public.counter_stock_balances.quantity + EXCLUDED.quantity, updated_at = now();
        INSERT INTO public.counter_stock_movements(
          shop_id, service_counter_id, product_id, movement_type, quantity_delta, actor_user_id, note
        ) VALUES (_shop, sale.source_counter_id, sale.product_id, 'sale_undo', sale.stock_qty, actor, 'Sale undone');
      END IF;
      response := to_jsonb(sale);
    WHEN 'transfer_stock' THEN
      PERFORM public.transfer_counter_stock(
        _shop, (request->>'product_id')::uuid, (request->>'from_counter_id')::uuid,
        (request->>'to_counter_id')::uuid, (request->>'qty')::int, request->>'reason'
      );
      -- The existing transfer returns void. JSON null is a completed result,
      -- distinct from the SQL NULL used by the private in-transaction claim.
      response := 'null'::jsonb;
    WHEN 'update_product' THEN
      -- Match the existing column-level UPDATE grant exactly; never accept
      -- stock, cost, code, tenant, identity, type, or generated timestamps.
      IF EXISTS (SELECT 1 FROM jsonb_object_keys(request->'patch') AS keys(key)
        WHERE NOT (key = ANY(ARRAY['name','brand','size','category','price','photo_url','photo_path','archived','barcode']))) THEN
        RAISE EXCEPTION 'unsupported_product_patch_field' USING ERRCODE = '22023';
      END IF;
      FOR field IN SELECT key, value FROM jsonb_each(request->'patch') LOOP
        IF field.key = 'price' THEN
          IF jsonb_typeof(field.value) <> 'number' THEN
            RAISE EXCEPTION 'product_price_must_be_integer' USING ERRCODE = '22023';
          END IF;
        ELSIF field.key = 'archived' THEN
          IF jsonb_typeof(field.value) <> 'boolean' THEN
            RAISE EXCEPTION 'product_archived_must_be_boolean' USING ERRCODE = '22023';
          END IF;
        ELSIF jsonb_typeof(field.value) NOT IN ('string','null') THEN
          RAISE EXCEPTION 'product_patch_text_field_required: %', field.key USING ERRCODE = '22023';
        END IF;
      END LOOP;
      SELECT * INTO product FROM public.products
      WHERE id = (request->>'product_id')::uuid AND shop_id = _shop FOR UPDATE;
      IF product.id IS NULL THEN RAISE EXCEPTION 'product_not_found'; END IF;
      IF NOT public.is_shop_owner(_shop) THEN RAISE EXCEPTION 'forbidden'; END IF;
      SELECT * INTO product FROM jsonb_populate_record(product, request->'patch');
      UPDATE public.products SET
        name = product.name, brand = product.brand, size = product.size,
        category = product.category, price = product.price, photo_url = product.photo_url,
        photo_path = product.photo_path, archived = product.archived, barcode = product.barcode,
        updated_at = now()
      WHERE id = product.id AND shop_id = _shop RETURNING * INTO product;
      PERFORM public.write_audit_event(_shop, 'product_updated', 'product', product.id, request->'patch');
      response := to_jsonb(product);
  END CASE;

  IF response IS NULL THEN RAISE EXCEPTION 'operation_result_missing'; END IF;
  UPDATE public.client_operations SET result = response, completed_at = now()
  WHERE shop_id = _shop AND operation_id = _operation_id;
  -- No exception handler: any business error rolls back BOTH mutation and claim.
  RETURN response;
END;
$$;
--> statement-breakpoint
REVOKE EXECUTE ON FUNCTION public.apply_pos_operation(uuid,uuid,text,jsonb) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.apply_pos_operation(uuid,uuid,text,jsonb) TO authenticated;
COMMENT ON FUNCTION public.apply_pos_operation(uuid,uuid,text,jsonb) IS
  'Android outbox: tenant + operation UUID binds actor, kind and canonical payload. Same request replays its first JSON result; changed actor/kind/payload raises operation_id_reused.';
