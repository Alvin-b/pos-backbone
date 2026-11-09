-- Persist named POS sale units and make unmeasured bulk products first-class.
ALTER TABLE public.products
  ADD COLUMN IF NOT EXISTS sale_units jsonb NOT NULL DEFAULT '[]'::jsonb;
--> statement-breakpoint
DO $$ BEGIN
  IF NOT EXISTS (
    SELECT 1 FROM pg_constraint
    WHERE conrelid = 'public.products'::regclass AND conname = 'products_sale_units_array_check'
  ) THEN
    ALTER TABLE public.products ADD CONSTRAINT products_sale_units_array_check
      CHECK (jsonb_typeof(sale_units) = 'array');
  END IF;
END $$;
--> statement-breakpoint
COMMENT ON COLUMN public.products.sale_units IS
  'Configured POS sale units: name, priceKsh, and stockUnitsPerSale. A zero factor marks manually depleted bulk/container inventory.';
--> statement-breakpoint
CREATE OR REPLACE FUNCTION public.validate_product_sale_units(_sale_units jsonb)
RETURNS jsonb
LANGUAGE plpgsql IMMUTABLE SET search_path = pg_catalog, public, pg_temp AS $$
DECLARE
  units jsonb := coalesce(_sale_units, '[]'::jsonb);
  entry jsonb;
  unit_name text;
  price_value numeric;
  factor_value numeric;
  seen_names text[] := ARRAY[]::text[];
BEGIN
  IF jsonb_typeof(units) <> 'array' THEN RAISE EXCEPTION 'invalid_sale_units'; END IF;
  FOR entry IN SELECT value FROM jsonb_array_elements(units) AS item(value) LOOP
    IF jsonb_typeof(entry) <> 'object' THEN RAISE EXCEPTION 'invalid_sale_unit'; END IF;
    unit_name := trim(coalesce(entry->>'name', ''));
    IF unit_name = '' OR length(unit_name) > 80 THEN RAISE EXCEPTION 'invalid_sale_unit_name'; END IF;
    IF lower(unit_name) = ANY(seen_names) THEN RAISE EXCEPTION 'duplicate_sale_unit_name'; END IF;
    seen_names := array_append(seen_names, lower(unit_name));

    IF jsonb_typeof(entry->'priceKsh') <> 'number' AND jsonb_typeof(entry->'price_ksh') <> 'number' THEN
      RAISE EXCEPTION 'invalid_sale_unit_price';
    END IF;
    price_value := coalesce(nullif(entry->>'priceKsh', '')::numeric, nullif(entry->>'price_ksh', '')::numeric);
    IF price_value < 1 OR price_value > 2147483647 OR price_value <> trunc(price_value) THEN
      RAISE EXCEPTION 'invalid_sale_unit_price';
    END IF;

    IF jsonb_typeof(entry->'stockUnitsPerSale') = 'number' THEN
      factor_value := (entry->>'stockUnitsPerSale')::numeric;
    ELSIF jsonb_typeof(entry->'stock_units_per_sale') = 'number' THEN
      factor_value := (entry->>'stock_units_per_sale')::numeric;
    ELSE
      factor_value := 1;
    END IF;
    IF factor_value < 0 OR factor_value > 2147483647 OR factor_value <> trunc(factor_value) THEN
      RAISE EXCEPTION 'invalid_sale_unit_stock_factor';
    END IF;
  END LOOP;
  RETURN units;
END $$;
--> statement-breakpoint
CREATE OR REPLACE FUNCTION public.record_sale_unit(
  _product uuid,
  _qty int DEFAULT 1,
  _unit_name text DEFAULT 'Bottle',
  _unit_price int DEFAULT NULL
)
RETURNS public.sales
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE
  p public.products;
  s public.sales;
  b public.stock_batches;
  remaining int;
  stock_used int;
  take_qty int;
  cost_total int := 0;
  sale_price int;
  unit_config jsonb;
  units_per_sale int;
  unit_factor_text text;
BEGIN
  IF _qty IS NULL OR _qty < 1 THEN RAISE EXCEPTION 'invalid_quantity'; END IF;
  SELECT * INTO p FROM public.products WHERE id = _product FOR UPDATE;
  IF p.id IS NULL OR NOT public.has_shop_role(
    p.shop_id, ARRAY['owner','manager','cashier']::public.shop_role[]
  ) THEN RAISE EXCEPTION 'product_not_found'; END IF;
  IF p.archived THEN RAISE EXCEPTION 'product_not_found'; END IF;
  SELECT entry.value INTO unit_config
  FROM jsonb_array_elements(coalesce(p.sale_units, '[]'::jsonb)) AS entry(value)
  WHERE lower(trim(coalesce(entry.value->>'name', ''))) = lower(trim(coalesce(_unit_name, 'Bottle')))
  LIMIT 1;
  IF unit_config IS NULL THEN
    -- Preserve legacy behavior for products without saved sale-unit definitions.
    stock_used := CASE
      WHEN lower(coalesce(_unit_name, 'Bottle')) IN ('bottle', 'can', 'unit') THEN _qty
      ELSE 1
    END;
  ELSE
    unit_factor_text := coalesce(
      nullif(unit_config->>'stockUnitsPerSale', ''),
      nullif(unit_config->>'stock_units_per_sale', ''),
      '1'
    );
    BEGIN
      units_per_sale := unit_factor_text::int;
    EXCEPTION WHEN others THEN
      RAISE EXCEPTION 'invalid_sale_unit_stock_factor';
    END;
    IF units_per_sale < 0 THEN RAISE EXCEPTION 'invalid_sale_unit_stock_factor'; END IF;
    stock_used := _qty * units_per_sale;
  END IF;
  IF p.stock < stock_used THEN RAISE EXCEPTION 'out_of_stock'; END IF;
  sale_price := coalesce(_unit_price, p.price);
  IF sale_price < 0 THEN RAISE EXCEPTION 'invalid_price'; END IF;

  INSERT INTO public.sales(
    shop_id, product_id, product_name, qty, unit_price, total, sold_by,
    unit_name, stock_qty, unit_cost_total, profit_total
  )
  VALUES (
    p.shop_id, p.id, p.name, _qty, sale_price, _qty * sale_price, auth.uid(),
    coalesce(nullif(trim(_unit_name), ''), 'Bottle'), stock_used, 0, _qty * sale_price
  ) RETURNING * INTO s;

  remaining := stock_used;
  FOR b IN
    SELECT * FROM public.stock_batches
    WHERE product_id = p.id AND remaining_qty > 0
    ORDER BY received_at ASC, id ASC
    FOR UPDATE
  LOOP
    EXIT WHEN remaining = 0;
    take_qty := LEAST(remaining, b.remaining_qty);
    UPDATE public.stock_batches
    SET remaining_qty = remaining_qty - take_qty
    WHERE id = b.id;
    INSERT INTO public.sale_batch_allocations(sale_id, batch_id, qty, unit_cost)
    VALUES (s.id, b.id, take_qty, b.unit_cost);
    cost_total := cost_total + (take_qty * b.unit_cost);
    remaining := remaining - take_qty;
  END LOOP;
  IF remaining > 0 THEN
    RAISE EXCEPTION 'stock_ledger_out_of_sync';
  END IF;

  UPDATE public.sales
  SET unit_cost_total = cost_total, profit_total = total - cost_total
  WHERE id = s.id
  RETURNING * INTO s;
  UPDATE public.products
  SET stock = stock - stock_used,
      average_cost = CASE WHEN stock_used = 0 THEN p.average_cost ELSE coalesce((
        SELECT round(sum(remaining_qty * unit_cost)::numeric / nullif(sum(remaining_qty), 0))::int
        FROM public.stock_batches WHERE product_id = p.id AND remaining_qty > 0
      ), 0) END,
      updated_at = now()
  WHERE id = p.id;
  PERFORM public.write_audit_event(p.shop_id, 'sale_recorded', 'sale', s.id,
    jsonb_build_object('product_id', p.id, 'stock_qty', stock_used, 'cost_total', cost_total));
  RETURN s;
END $$;
--> statement-breakpoint
CREATE OR REPLACE FUNCTION public.undo_sale(_shop uuid, _sale uuid DEFAULT NULL)
RETURNS public.sales
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE s public.sales; allocation record;
BEGIN
  IF NOT public.is_shop_manager(_shop) THEN RAISE EXCEPTION 'forbidden'; END IF;
  IF _sale IS NULL THEN
    SELECT * INTO s FROM public.sales
    WHERE shop_id = _shop AND undone_at IS NULL
    ORDER BY created_at DESC LIMIT 1 FOR UPDATE;
  ELSE
    SELECT * INTO s FROM public.sales
    WHERE id = _sale AND shop_id = _shop AND undone_at IS NULL FOR UPDATE;
  END IF;
  IF s.id IS NULL THEN RAISE EXCEPTION 'nothing_to_undo'; END IF;

  IF EXISTS (SELECT 1 FROM public.sale_batch_allocations WHERE sale_id = s.id) THEN
    FOR allocation IN
      SELECT * FROM public.sale_batch_allocations WHERE sale_id = s.id FOR UPDATE
    LOOP
      UPDATE public.stock_batches
      SET remaining_qty = remaining_qty + allocation.qty
      WHERE id = allocation.batch_id;
    END LOOP;
  ELSIF s.stock_qty > 0 THEN
    -- Legacy sale created before FIFO migration: restore only consumed stock.
    INSERT INTO public.stock_batches(
      shop_id, product_id, received_qty, remaining_qty, unit_cost, received_by, notes
    )
    VALUES (
      s.shop_id, s.product_id, s.stock_qty, s.stock_qty, 0, auth.uid(),
      'Legacy sale undo opening layer'
    );
  END IF;

  UPDATE public.sales SET undone_at = now(), undone_by = auth.uid()
  WHERE id = s.id RETURNING * INTO s;
  UPDATE public.products
  SET stock = stock + s.stock_qty,
      average_cost = CASE WHEN s.stock_qty = 0 THEN average_cost ELSE coalesce((
        SELECT round(sum(remaining_qty * unit_cost)::numeric / nullif(sum(remaining_qty), 0))::int
        FROM public.stock_batches WHERE product_id = s.product_id AND remaining_qty > 0
      ), 0) END,
      updated_at = now()
  WHERE id = s.product_id;
  PERFORM public.write_audit_event(_shop, 'sale_undone', 'sale', s.id,
    jsonb_build_object('stock_qty_restored', s.stock_qty));
  RETURN s;
END $$;
--> statement-breakpoint
CREATE OR REPLACE FUNCTION public.enforce_counter_stock_on_sale()
RETURNS trigger
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE mode text; selected_counter uuid; available int := 0;
BEGIN
  SELECT counter_inventory_mode INTO mode FROM public.shops WHERE id = NEW.shop_id;
  selected_counter := nullif(current_setting('counterpos.selected_counter_id', true), '')::uuid;
  IF selected_counter IS NOT NULL AND NOT EXISTS (
    SELECT 1 FROM public.service_counters
    WHERE id = selected_counter AND shop_id = NEW.shop_id AND active
  ) THEN RAISE EXCEPTION 'counter_not_found_or_inactive'; END IF;

  IF mode = 'per_counter' THEN
    IF selected_counter IS NULL THEN RAISE EXCEPTION 'counter_required'; END IF;
    INSERT INTO public.counter_stock_balances(shop_id, service_counter_id, product_id, quantity)
    VALUES (NEW.shop_id, selected_counter, NEW.product_id, 0)
    ON CONFLICT (service_counter_id, product_id) DO NOTHING;
    SELECT quantity INTO available FROM public.counter_stock_balances
    WHERE service_counter_id = selected_counter AND product_id = NEW.product_id FOR UPDATE;
    IF coalesce(available, 0) < NEW.stock_qty THEN RAISE EXCEPTION 'insufficient_counter_stock'; END IF;
    UPDATE public.counter_stock_balances SET quantity = quantity - NEW.stock_qty, updated_at = now()
    WHERE service_counter_id = selected_counter AND product_id = NEW.product_id;
    IF NEW.stock_qty <> 0 THEN
      INSERT INTO public.counter_stock_movements(shop_id, service_counter_id, product_id, movement_type, quantity_delta, actor_user_id, note)
      VALUES (NEW.shop_id, selected_counter, NEW.product_id, 'sale', -NEW.stock_qty, auth.uid(), 'Sale');
    END IF;
  END IF;

  NEW.source_counter_id := selected_counter;
  RETURN NEW;
END $$;
--> statement-breakpoint
CREATE OR REPLACE FUNCTION public.register_product_with_units(
  _shop uuid, _code text, _name text, _price int, _qty int, _photo_path text,
  _unit_cost int DEFAULT 0, _size text DEFAULT NULL, _type public.product_type DEFAULT 'beer',
  _brand text DEFAULT NULL, _category text DEFAULT NULL, _sale_units jsonb DEFAULT '[]'::jsonb
)
RETURNS public.products
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE p public.products; units jsonb;
BEGIN
  IF NOT public.is_inventory_operator(_shop) THEN RAISE EXCEPTION 'forbidden'; END IF;
  IF coalesce(trim(_code), '') = '' THEN RAISE EXCEPTION 'code_required'; END IF;
  IF coalesce(trim(_name), '') = '' THEN RAISE EXCEPTION 'name_required'; END IF;
  IF _price IS NULL OR _price < 1 THEN RAISE EXCEPTION 'price_required'; END IF;
  IF _qty IS NULL OR _qty < 0 OR coalesce(_unit_cost, 0) < 0 THEN
    RAISE EXCEPTION 'invalid_quantity';
  END IF;
  units := public.validate_product_sale_units(_sale_units);
  IF EXISTS (SELECT 1 FROM public.products WHERE shop_id = _shop AND code = trim(_code)) THEN
    RAISE EXCEPTION 'code_exists';
  END IF;
  INSERT INTO public.products(
    shop_id, code, barcode, name, brand, size, category, product_type,
    body_color, label_color, label_text_color, price, stock, average_cost, photo_path, sale_units
  ) VALUES (
    _shop, trim(_code), trim(_code), trim(_name), coalesce(_brand, trim(_name)),
    coalesce(nullif(trim(_size), ''), '-'), coalesce(_category, 'Custom beverage'), _type,
    CASE WHEN _type = 'beer' THEN '#5a3a1c' ELSE '#2a2a2a' END,
    '#e8e4d4', '#14181f', _price, 0, coalesce(_unit_cost, 0), _photo_path, units
  ) RETURNING * INTO p;

  IF _qty > 0 THEN
    PERFORM public.receive_stock_with_cost(p.id, _qty, coalesce(_unit_cost, 0), NULL, NULL, 'New product opening stock');
    SELECT * INTO p FROM public.products WHERE id = p.id;
    UPDATE public.stock_receipts SET is_new_product = true WHERE product_id = p.id
      AND received_by = auth.uid() AND notes = 'New product opening stock';
  END IF;
  RETURN p;
END $$;
--> statement-breakpoint
CREATE OR REPLACE FUNCTION public.register_product_at_counter_with_units(
  _shop uuid, _code text, _name text, _price int, _qty int, _counter uuid,
  _photo_path text, _unit_cost int DEFAULT 0, _size text DEFAULT NULL,
  _type public.product_type DEFAULT 'beer', _brand text DEFAULT NULL,
  _category text DEFAULT NULL, _sale_units jsonb DEFAULT '[]'::jsonb
)
RETURNS public.products
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE p public.products; c public.service_counters; mode text;
BEGIN
  SELECT * INTO c FROM public.service_counters
  WHERE id = _counter AND shop_id = _shop AND active FOR SHARE;
  IF c.id IS NULL THEN RAISE EXCEPTION 'counter_not_found_or_inactive'; END IF;
  SELECT counter_inventory_mode INTO mode FROM public.shops WHERE id = _shop;
  p := public.register_product_with_units(
    _shop, _code, _name, _price, _qty, _photo_path, _unit_cost, _size,
    _type, _brand, _category, _sale_units
  );
  IF mode = 'per_counter' THEN
    INSERT INTO public.counter_stock_balances(shop_id, service_counter_id, product_id, quantity)
    VALUES (_shop, c.id, p.id, _qty)
    ON CONFLICT (service_counter_id, product_id) DO UPDATE
      SET quantity = public.counter_stock_balances.quantity + EXCLUDED.quantity, updated_at = now();
    IF _qty > 0 THEN
      INSERT INTO public.counter_stock_movements(shop_id, service_counter_id, product_id, movement_type, quantity_delta, actor_user_id, note)
      VALUES (_shop, c.id, p.id, 'receipt', _qty, auth.uid(), 'New product opening stock');
    END IF;
  END IF;
  RETURN p;
END $$;
--> statement-breakpoint
CREATE OR REPLACE FUNCTION public.apply_pos_operation_legacy(
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
      allowed_keys := ARRAY['code','name','price','qty','counter_id','photo_path','unit_cost','size','type','brand','category','sale_units'];
      required_keys := ARRAY['code','name','price','qty','counter_id','photo_path'];
      defaults := '{"unit_cost":0,"size":null,"type":"beer","brand":null,"category":null,"sale_units":[]}'::jsonb;
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
    ELSIF field.key = 'sale_units' THEN
      PERFORM public.validate_product_sale_units(field.value);
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
      SELECT to_jsonb(p) INTO response FROM public.register_product_at_counter_with_units(
        _shop, request->>'code', request->>'name', (request->>'price')::int,
        (request->>'qty')::int, (request->>'counter_id')::uuid, request->>'photo_path',
        (request->>'unit_cost')::int, request->>'size',
        (request->>'type')::public.product_type, request->>'brand', request->>'category',
        request->'sale_units'
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
        IF sale.stock_qty <> 0 THEN
          INSERT INTO public.counter_stock_movements(
            shop_id, service_counter_id, product_id, movement_type, quantity_delta, actor_user_id, note
          ) VALUES (_shop, sale.source_counter_id, sale.product_id, 'sale_undo', sale.stock_qty, actor, 'Sale undone');
        END IF;
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
        WHERE NOT (key = ANY(ARRAY['name','brand','size','category','price','photo_url','photo_path','archived','barcode','sale_units']))) THEN
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
        ELSIF field.key = 'sale_units' THEN
          PERFORM public.validate_product_sale_units(field.value);
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
        sale_units = product.sale_units, updated_at = now()
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
REVOKE EXECUTE ON FUNCTION public.validate_product_sale_units(jsonb) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.validate_product_sale_units(jsonb) TO authenticated;
REVOKE EXECUTE ON FUNCTION public.register_product_with_units(uuid,text,text,int,int,text,int,text,public.product_type,text,text,jsonb) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.register_product_with_units(uuid,text,text,int,int,text,int,text,public.product_type,text,text,jsonb) TO authenticated;
REVOKE EXECUTE ON FUNCTION public.register_product_at_counter_with_units(uuid,text,text,int,int,uuid,text,int,text,public.product_type,text,text,jsonb) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.register_product_at_counter_with_units(uuid,text,text,int,int,uuid,text,int,text,public.product_type,text,text,jsonb) TO authenticated;
--> statement-breakpoint
GRANT UPDATE (sale_units) ON public.products TO authenticated;
