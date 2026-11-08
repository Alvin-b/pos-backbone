CREATE OR REPLACE FUNCTION public.record_dispensation_from_counter(
  _shop uuid,
  _product uuid,
  _counter uuid,
  _qty int DEFAULT 1,
  _unit_name text DEFAULT 'Bottle',
  _note text DEFAULT NULL
)
RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE
  p public.products;
  c public.service_counters;
  mode text;
  stock_used int;
  counter_qty int := 0;
  remaining int;
  take_qty int;
  b public.stock_batches;
BEGIN
  IF NOT public.has_shop_role(_shop, ARRAY['owner','manager','cashier']::public.shop_role[]) THEN
    RAISE EXCEPTION 'forbidden';
  END IF;
  IF _qty IS NULL OR _qty < 1 THEN RAISE EXCEPTION 'invalid_quantity'; END IF;

  SELECT * INTO p
  FROM public.products
  WHERE id = _product AND shop_id = _shop AND NOT archived
  FOR UPDATE;
  IF p.id IS NULL THEN RAISE EXCEPTION 'product_not_found'; END IF;

  SELECT * INTO c
  FROM public.service_counters
  WHERE id = _counter AND shop_id = _shop AND active
  FOR SHARE;
  IF c.id IS NULL THEN RAISE EXCEPTION 'counter_not_found_or_inactive'; END IF;

  stock_used := CASE
    WHEN lower(coalesce(_unit_name, 'Bottle')) IN ('bottle', 'can', 'unit') THEN _qty
    ELSE 1
  END;
  SELECT counter_inventory_mode INTO mode FROM public.shops WHERE id = _shop;

  IF mode = 'per_counter' THEN
    SELECT quantity INTO counter_qty
    FROM public.counter_stock_balances
    WHERE service_counter_id = _counter AND product_id = _product
    FOR UPDATE;
    IF coalesce(counter_qty, 0) < stock_used THEN RAISE EXCEPTION 'out_of_stock'; END IF;
  ELSIF p.stock < stock_used THEN
    RAISE EXCEPTION 'out_of_stock';
  END IF;

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
    remaining := remaining - take_qty;
  END LOOP;
  IF remaining > 0 THEN RAISE EXCEPTION 'stock_ledger_out_of_sync'; END IF;

  UPDATE public.products
  SET stock = stock - stock_used,
      average_cost = coalesce((
        SELECT round(sum(remaining_qty * unit_cost)::numeric / nullif(sum(remaining_qty), 0))::int
        FROM public.stock_batches WHERE product_id = p.id AND remaining_qty > 0
      ), 0),
      updated_at = now()
  WHERE id = p.id;

  IF mode = 'per_counter' THEN
    UPDATE public.counter_stock_balances
    SET quantity = quantity - stock_used, updated_at = now()
    WHERE service_counter_id = _counter AND product_id = _product;
    INSERT INTO public.counter_stock_movements(
      shop_id, service_counter_id, product_id, movement_type,
      quantity_delta, actor_user_id, note
    ) VALUES (
      _shop, _counter, _product, 'dispensation', -stock_used, auth.uid(),
      nullif(trim(_note), '')
    );
  END IF;

  PERFORM public.write_audit_event(
    _shop,
    'stock_dispensation_recorded',
    'product',
    _product,
    jsonb_build_object(
      'counter_id', _counter,
      'quantity', _qty,
      'stock_quantity', stock_used,
      'unit_name', _unit_name,
      'note', _note
    )
  );

  RETURN jsonb_build_object(
    'shop_id', _shop,
    'product_id', _product,
    'counter_id', _counter,
    'quantity', _qty,
    'stock_quantity', stock_used,
    'kind', 'dispensation'
  );
END $$;

REVOKE EXECUTE ON FUNCTION public.record_dispensation_from_counter(uuid,uuid,uuid,int,text,text) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.record_dispensation_from_counter(uuid,uuid,uuid,int,text,text) TO authenticated;
