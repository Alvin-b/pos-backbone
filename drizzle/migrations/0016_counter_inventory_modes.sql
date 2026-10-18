-- Counter inventory modes layered on the service_counters/reporting schema from 0015.
-- Shared mode retains one shop-wide product stock balance. Per-counter mode keeps
-- balances per physical counter while products.stock and FIFO cost layers remain
-- the shop-wide aggregate.

ALTER TABLE public.shops
  ADD COLUMN IF NOT EXISTS counter_inventory_mode text NOT NULL DEFAULT 'shared';

DO $$
BEGIN
  ALTER TABLE public.shops
    ADD CONSTRAINT shops_counter_inventory_mode_check
    CHECK (counter_inventory_mode IN ('shared', 'per_counter'));
EXCEPTION WHEN duplicate_object THEN NULL;
END $$;

CREATE TABLE IF NOT EXISTS public.counter_stock_balances (
  shop_id uuid NOT NULL REFERENCES public.shops(id) ON DELETE CASCADE,
  service_counter_id uuid NOT NULL REFERENCES public.service_counters(id) ON DELETE CASCADE,
  product_id uuid NOT NULL REFERENCES public.products(id) ON DELETE CASCADE,
  quantity int NOT NULL DEFAULT 0 CHECK (quantity >= 0),
  updated_at timestamptz NOT NULL DEFAULT now(),
  PRIMARY KEY (service_counter_id, product_id)
);

CREATE INDEX IF NOT EXISTS counter_stock_balances_shop_product_idx
  ON public.counter_stock_balances(shop_id, product_id);

CREATE TABLE IF NOT EXISTS public.counter_stock_movements (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  shop_id uuid NOT NULL REFERENCES public.shops(id) ON DELETE CASCADE,
  service_counter_id uuid NOT NULL REFERENCES public.service_counters(id) ON DELETE RESTRICT,
  product_id uuid NOT NULL REFERENCES public.products(id) ON DELETE RESTRICT,
  movement_type text NOT NULL CHECK (movement_type IN ('receipt', 'sale', 'adjustment', 'transfer_in', 'transfer_out', 'sale_undo')),
  quantity_delta int NOT NULL CHECK (quantity_delta <> 0),
  related_counter_id uuid REFERENCES public.service_counters(id) ON DELETE SET NULL,
  actor_user_id uuid,
  note text,
  created_at timestamptz NOT NULL DEFAULT now()
);

CREATE INDEX IF NOT EXISTS counter_stock_movements_shop_time_idx
  ON public.counter_stock_movements(shop_id, created_at DESC);
CREATE INDEX IF NOT EXISTS counter_stock_movements_counter_product_idx
  ON public.counter_stock_movements(service_counter_id, product_id, created_at DESC);

ALTER TABLE public.counter_stock_balances ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.counter_stock_movements ENABLE ROW LEVEL SECURITY;
GRANT ALL ON public.counter_stock_balances, public.counter_stock_movements TO service_role;

-- CREATE TABLE IF NOT EXISTS above migration 0015 cannot repair a pre-existing
-- service_counters table. Ensure the conflict target exists before seed inserts.
CREATE UNIQUE INDEX IF NOT EXISTS service_counters_shop_name_uidx
  ON public.service_counters(shop_id, name);

-- Every new business gets one initial service counter. Existing businesses with no
-- counters receive the same default; businesses already configured are untouched.
CREATE OR REPLACE FUNCTION public.seed_default_service_counter()
RETURNS trigger
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
BEGIN
  INSERT INTO public.service_counters(shop_id, name, created_by)
  VALUES (NEW.id, 'Counter 1', NEW.created_by)
  ON CONFLICT (shop_id, name) DO NOTHING;
  RETURN NEW;
END $$;

DROP TRIGGER IF EXISTS seed_default_service_counter_trigger ON public.shops;
CREATE TRIGGER seed_default_service_counter_trigger
  AFTER INSERT ON public.shops
  FOR EACH ROW EXECUTE FUNCTION public.seed_default_service_counter();

INSERT INTO public.service_counters(shop_id, name, created_by)
SELECT s.id, 'Counter 1', s.created_by
FROM public.shops s
WHERE NOT EXISTS (
  SELECT 1 FROM public.service_counters c WHERE c.shop_id = s.id AND c.active
)
ON CONFLICT (shop_id, name) DO NOTHING;

-- Registration-time setup for the platform administrator.
CREATE OR REPLACE FUNCTION public.admin_create_business_with_counter_setup(
  _name text,
  _owner_email text DEFAULT NULL,
  _counter_inventory_mode text DEFAULT 'shared',
  _counter_count int DEFAULT 1
)
RETURNS public.shops
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE s public.shops; i int;
BEGIN
  IF NOT public.is_platform_admin() THEN RAISE EXCEPTION 'forbidden'; END IF;
  IF _counter_inventory_mode NOT IN ('shared', 'per_counter') THEN RAISE EXCEPTION 'invalid_counter_inventory_mode'; END IF;
  IF _counter_count IS NULL OR _counter_count NOT BETWEEN 1 AND 50 THEN RAISE EXCEPTION 'invalid_counter_count'; END IF;
  s := public.admin_create_business(_name, _owner_email);
  UPDATE public.shops SET counter_inventory_mode = _counter_inventory_mode
  WHERE id = s.id RETURNING * INTO s;
  FOR i IN 2.._counter_count LOOP
    INSERT INTO public.service_counters(shop_id, name, created_by)
    VALUES (s.id, 'Counter ' || i, auth.uid());
  END LOOP;
  PERFORM public.write_audit_event(s.id, 'counter_inventory_setup', 'shop', s.id,
    jsonb_build_object('mode', _counter_inventory_mode, 'counter_count', _counter_count));
  RETURN s;
END $$;

CREATE OR REPLACE FUNCTION public.rename_service_counter(_shop uuid, _counter uuid, _name text)
RETURNS public.service_counters
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE c public.service_counters;
BEGIN
  IF NOT public.is_shop_manager(_shop) THEN RAISE EXCEPTION 'forbidden'; END IF;
  IF length(trim(coalesce(_name, ''))) NOT BETWEEN 1 AND 60 THEN RAISE EXCEPTION 'invalid_counter_name'; END IF;
  SELECT * INTO c FROM public.service_counters
  WHERE id = _counter AND shop_id = _shop AND active FOR UPDATE;
  IF c.id IS NULL THEN RAISE EXCEPTION 'counter_not_found_or_inactive'; END IF;
  UPDATE public.service_counters SET name = trim(_name) WHERE id = _counter RETURNING * INTO c;
  PERFORM public.write_audit_event(_shop, 'counter_renamed', 'service_counter', c.id,
    jsonb_build_object('name', c.name));
  RETURN c;
END $$;

-- Do not allow counters with stock to be hidden, or the last active counter to be disabled.
CREATE OR REPLACE FUNCTION public.set_service_counter_active(_counter uuid, _active boolean)
RETURNS public.service_counters
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE c public.service_counters;
BEGIN
  SELECT * INTO c FROM public.service_counters WHERE id = _counter FOR UPDATE;
  IF c.id IS NULL OR NOT public.is_shop_manager(c.shop_id) THEN RAISE EXCEPTION 'forbidden'; END IF;
  IF coalesce(_active, true) = false AND c.active THEN
    IF EXISTS (SELECT 1 FROM public.counter_stock_balances b WHERE b.service_counter_id = c.id AND b.quantity > 0) THEN
      RAISE EXCEPTION 'counter_has_stock';
    END IF;
    IF (SELECT count(*) FROM public.service_counters x WHERE x.shop_id = c.shop_id AND x.active) <= 1 THEN
      RAISE EXCEPTION 'last_active_counter_required';
    END IF;
  END IF;
  UPDATE public.service_counters SET active = coalesce(_active, true) WHERE id = c.id RETURNING * INTO c;
  PERFORM public.write_audit_event(c.shop_id, 'counter_status_changed', 'service_counter', c.id,
    jsonb_build_object('active', c.active));
  RETURN c;
END $$;

-- Stock balances are updated in the sales INSERT trigger. The explicit counter
-- wrapper sets a transaction-local counter id; direct legacy calls cannot bypass
-- counter stock enforcement for businesses configured for per-counter inventory.
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
    INSERT INTO public.counter_stock_movements(shop_id, service_counter_id, product_id, movement_type, quantity_delta, actor_user_id, note)
    VALUES (NEW.shop_id, selected_counter, NEW.product_id, 'sale', -NEW.stock_qty, auth.uid(), 'Sale');
  END IF;

  NEW.source_counter_id := selected_counter;
  RETURN NEW;
END $$;

DROP TRIGGER IF EXISTS enforce_counter_stock_on_sale_trigger ON public.sales;
CREATE TRIGGER enforce_counter_stock_on_sale_trigger
  BEFORE INSERT ON public.sales
  FOR EACH ROW EXECUTE FUNCTION public.enforce_counter_stock_on_sale();

CREATE OR REPLACE FUNCTION public.record_sale_unit_from_counter(
  _product uuid, _counter uuid, _qty int DEFAULT 1,
  _unit_name text DEFAULT 'Bottle', _unit_price int DEFAULT NULL
)
RETURNS public.sales
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE p public.products; c public.service_counters; s public.sales;
BEGIN
  SELECT * INTO p FROM public.products WHERE id = _product AND NOT archived;
  IF p.id IS NULL THEN RAISE EXCEPTION 'product_not_found'; END IF;
  SELECT * INTO c FROM public.service_counters WHERE id = _counter AND shop_id = p.shop_id AND active FOR SHARE;
  IF c.id IS NULL THEN RAISE EXCEPTION 'counter_not_found_or_inactive'; END IF;
  PERFORM set_config('counterpos.selected_counter_id', c.id::text, true);
  SELECT * INTO s FROM public.record_sale_unit(_product, _qty, _unit_name, _unit_price);
  RETURN s;
END $$;

CREATE OR REPLACE FUNCTION public.record_table_sale_from_counter(
  _shop uuid, _table uuid, _product uuid, _counter uuid,
  _qty int, _unit_name text, _unit_price int
)
RETURNS public.table_orders
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE c public.service_counters; o public.table_orders;
BEGIN
  SELECT * INTO c FROM public.service_counters WHERE id = _counter AND shop_id = _shop AND active FOR SHARE;
  IF c.id IS NULL THEN RAISE EXCEPTION 'counter_not_found_or_inactive'; END IF;
  PERFORM set_config('counterpos.selected_counter_id', c.id::text, true);
  SELECT * INTO o FROM public.record_table_sale(_shop, _table, _product, _qty, _unit_name, _unit_price);
  RETURN o;
END $$;

CREATE OR REPLACE FUNCTION public.receive_stock_at_counter(
  _counter uuid, _product uuid, _qty int, _unit_cost int DEFAULT 0,
  _supplier text DEFAULT NULL, _reference text DEFAULT NULL, _notes text DEFAULT NULL
)
RETURNS public.products
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE p public.products; c public.service_counters; mode text;
BEGIN
  SELECT * INTO p FROM public.products WHERE id = _product AND NOT archived FOR UPDATE;
  IF p.id IS NULL THEN RAISE EXCEPTION 'product_not_found'; END IF;
  SELECT * INTO c FROM public.service_counters WHERE id = _counter AND shop_id = p.shop_id AND active FOR SHARE;
  IF c.id IS NULL THEN RAISE EXCEPTION 'counter_not_found_or_inactive'; END IF;
  SELECT counter_inventory_mode INTO mode FROM public.shops WHERE id = p.shop_id;
  p := public.receive_stock_with_cost(_product, _qty, _unit_cost, _supplier, _reference, _notes);
  IF mode = 'per_counter' THEN
    INSERT INTO public.counter_stock_balances(shop_id, service_counter_id, product_id, quantity)
    VALUES (p.shop_id, c.id, p.id, _qty)
    ON CONFLICT (service_counter_id, product_id) DO UPDATE
      SET quantity = public.counter_stock_balances.quantity + EXCLUDED.quantity, updated_at = now();
    INSERT INTO public.counter_stock_movements(shop_id, service_counter_id, product_id, movement_type, quantity_delta, actor_user_id, note)
    VALUES (p.shop_id, c.id, p.id, 'receipt', _qty, auth.uid(), nullif(trim(_notes), ''));
  END IF;
  RETURN p;
END $$;

CREATE OR REPLACE FUNCTION public.add_from_catalog_at_counter(
  _shop uuid, _catalog uuid, _counter uuid, _qty int, _price int, _unit_cost int DEFAULT 0
)
RETURNS public.products
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE p public.products; c public.service_counters; mode text;
BEGIN
  SELECT * INTO c FROM public.service_counters WHERE id = _counter AND shop_id = _shop AND active FOR SHARE;
  IF c.id IS NULL THEN RAISE EXCEPTION 'counter_not_found_or_inactive'; END IF;
  SELECT counter_inventory_mode INTO mode FROM public.shops WHERE id = _shop;
  p := public.add_from_catalog_with_cost(_shop, _catalog, _qty, _price, _unit_cost);
  IF mode = 'per_counter' THEN
    INSERT INTO public.counter_stock_balances(shop_id, service_counter_id, product_id, quantity)
    VALUES (_shop, c.id, p.id, _qty)
    ON CONFLICT (service_counter_id, product_id) DO UPDATE
      SET quantity = public.counter_stock_balances.quantity + EXCLUDED.quantity, updated_at = now();
    INSERT INTO public.counter_stock_movements(shop_id, service_counter_id, product_id, movement_type, quantity_delta, actor_user_id, note)
    VALUES (_shop, c.id, p.id, 'receipt', _qty, auth.uid(), 'Added from beverage library');
  END IF;
  RETURN p;
END $$;

CREATE OR REPLACE FUNCTION public.register_product_at_counter(
  _shop uuid, _code text, _name text, _price int, _qty int, _counter uuid,
  _photo_path text, _unit_cost int DEFAULT 0, _size text DEFAULT NULL,
  _type public.product_type DEFAULT 'beer', _brand text DEFAULT NULL, _category text DEFAULT NULL
)
RETURNS public.products
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE p public.products; c public.service_counters; mode text;
BEGIN
  SELECT * INTO c FROM public.service_counters WHERE id = _counter AND shop_id = _shop AND active FOR SHARE;
  IF c.id IS NULL THEN RAISE EXCEPTION 'counter_not_found_or_inactive'; END IF;
  SELECT counter_inventory_mode INTO mode FROM public.shops WHERE id = _shop;
  p := public.register_product_with_cost(_shop, _code, _name, _price, _qty, _photo_path, _unit_cost, _size, _type, _brand, _category);
  IF mode = 'per_counter' THEN
    INSERT INTO public.counter_stock_balances(shop_id, service_counter_id, product_id, quantity)
    VALUES (_shop, c.id, p.id, _qty)
    ON CONFLICT (service_counter_id, product_id) DO UPDATE
      SET quantity = public.counter_stock_balances.quantity + EXCLUDED.quantity, updated_at = now();
    INSERT INTO public.counter_stock_movements(shop_id, service_counter_id, product_id, movement_type, quantity_delta, actor_user_id, note)
    VALUES (_shop, c.id, p.id, 'receipt', _qty, auth.uid(), 'New product opening stock');
  END IF;
  RETURN p;
END $$;

CREATE OR REPLACE FUNCTION public.adjust_counter_stock(_counter uuid, _product uuid, _new_stock int, _reason text DEFAULT NULL)
RETURNS public.products
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE p public.products; c public.service_counters; mode text; current_counter_stock int := 0; delta int; total_target int;
BEGIN
  SELECT * INTO p FROM public.products WHERE id = _product AND NOT archived FOR UPDATE;
  IF p.id IS NULL OR NOT public.is_shop_manager(p.shop_id) THEN RAISE EXCEPTION 'forbidden'; END IF;
  IF _new_stock IS NULL OR _new_stock < 0 THEN RAISE EXCEPTION 'invalid_stock_count'; END IF;
  SELECT * INTO c FROM public.service_counters WHERE id = _counter AND shop_id = p.shop_id AND active;
  IF c.id IS NULL THEN RAISE EXCEPTION 'counter_not_found_or_inactive'; END IF;
  SELECT counter_inventory_mode INTO mode FROM public.shops WHERE id = p.shop_id;
  IF mode = 'shared' THEN RETURN public.adjust_stock(_product, _new_stock, _reason); END IF;

  INSERT INTO public.counter_stock_balances(shop_id, service_counter_id, product_id, quantity)
  VALUES (p.shop_id, c.id, p.id, 0)
  ON CONFLICT (service_counter_id, product_id) DO NOTHING;
  SELECT quantity INTO current_counter_stock FROM public.counter_stock_balances
  WHERE service_counter_id = c.id AND product_id = p.id FOR UPDATE;
  delta := _new_stock - current_counter_stock;
  IF delta = 0 THEN RETURN p; END IF;
  total_target := p.stock + delta;
  IF total_target < 0 THEN RAISE EXCEPTION 'invalid_stock_count'; END IF;
  p := public.adjust_stock(_product, total_target, coalesce(_reason, 'Counter stock count adjustment'));
  UPDATE public.counter_stock_balances SET quantity = _new_stock, updated_at = now()
  WHERE service_counter_id = c.id AND product_id = p.id;
  INSERT INTO public.counter_stock_movements(shop_id, service_counter_id, product_id, movement_type, quantity_delta, actor_user_id, note)
  VALUES (p.shop_id, c.id, p.id, 'adjustment', delta, auth.uid(), coalesce(_reason, 'Counter stock count adjustment'));
  PERFORM public.write_audit_event(p.shop_id, 'counter_stock_adjusted', 'product', p.id,
    jsonb_build_object('counter_id', c.id, 'quantity', _new_stock, 'delta', delta, 'reason', _reason));
  RETURN p;
END $$;

CREATE OR REPLACE FUNCTION public.transfer_counter_stock(
  _shop uuid, _product uuid, _from_counter uuid, _to_counter uuid, _qty int, _reason text DEFAULT NULL
)
RETURNS void
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE source_qty int := 0;
BEGIN
  IF NOT public.is_shop_manager(_shop) THEN RAISE EXCEPTION 'forbidden'; END IF;
  IF _qty IS NULL OR _qty < 1 OR _from_counter = _to_counter THEN RAISE EXCEPTION 'invalid_counter_transfer'; END IF;
  IF NOT EXISTS (SELECT 1 FROM public.shops WHERE id = _shop AND counter_inventory_mode = 'per_counter') THEN
    RAISE EXCEPTION 'counter_transfer_requires_per_counter_stock';
  END IF;
  IF NOT EXISTS (SELECT 1 FROM public.products WHERE id = _product AND shop_id = _shop AND NOT archived) THEN RAISE EXCEPTION 'product_not_found'; END IF;
  IF NOT EXISTS (SELECT 1 FROM public.service_counters WHERE id = _from_counter AND shop_id = _shop AND active)
     OR NOT EXISTS (SELECT 1 FROM public.service_counters WHERE id = _to_counter AND shop_id = _shop AND active) THEN
    RAISE EXCEPTION 'counter_not_found_or_inactive';
  END IF;

  INSERT INTO public.counter_stock_balances(shop_id, service_counter_id, product_id, quantity)
  VALUES (_shop, _from_counter, _product, 0), (_shop, _to_counter, _product, 0)
  ON CONFLICT (service_counter_id, product_id) DO NOTHING;
  PERFORM 1 FROM public.counter_stock_balances
  WHERE product_id = _product AND service_counter_id IN (_from_counter, _to_counter)
  ORDER BY service_counter_id FOR UPDATE;
  SELECT quantity INTO source_qty FROM public.counter_stock_balances
  WHERE service_counter_id = _from_counter AND product_id = _product;
  IF coalesce(source_qty, 0) < _qty THEN RAISE EXCEPTION 'insufficient_counter_stock'; END IF;
  UPDATE public.counter_stock_balances SET quantity = quantity - _qty, updated_at = now()
  WHERE service_counter_id = _from_counter AND product_id = _product;
  UPDATE public.counter_stock_balances SET quantity = quantity + _qty, updated_at = now()
  WHERE service_counter_id = _to_counter AND product_id = _product;
  INSERT INTO public.counter_stock_movements(shop_id, service_counter_id, product_id, movement_type, quantity_delta, related_counter_id, actor_user_id, note)
  VALUES
    (_shop, _from_counter, _product, 'transfer_out', -_qty, _to_counter, auth.uid(), nullif(trim(_reason), '')),
    (_shop, _to_counter, _product, 'transfer_in', _qty, _from_counter, auth.uid(), nullif(trim(_reason), ''));
  PERFORM public.write_audit_event(_shop, 'counter_stock_transferred', 'product', _product,
    jsonb_build_object('from_counter', _from_counter, 'to_counter', _to_counter, 'qty', _qty, 'reason', _reason));
END $$;

CREATE OR REPLACE FUNCTION public.undo_sale_from_counter(_shop uuid)
RETURNS public.sales
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE s public.sales; mode text;
BEGIN
  s := public.undo_sale(_shop, NULL);
  IF s.id IS NULL THEN RETURN s; END IF;
  SELECT counter_inventory_mode INTO mode FROM public.shops WHERE id = _shop;
  IF mode = 'per_counter' THEN
    IF s.source_counter_id IS NULL THEN RAISE EXCEPTION 'legacy_sale_has_no_counter'; END IF;
    INSERT INTO public.counter_stock_balances(shop_id, service_counter_id, product_id, quantity)
    VALUES (_shop, s.source_counter_id, s.product_id, s.stock_qty)
    ON CONFLICT (service_counter_id, product_id) DO UPDATE
      SET quantity = public.counter_stock_balances.quantity + EXCLUDED.quantity, updated_at = now();
    INSERT INTO public.counter_stock_movements(shop_id, service_counter_id, product_id, movement_type, quantity_delta, actor_user_id, note)
    VALUES (_shop, s.source_counter_id, s.product_id, 'sale_undo', s.stock_qty, auth.uid(), 'Sale undone');
  END IF;
  RETURN s;
END $$;

CREATE OR REPLACE FUNCTION public.counter_stock_report(_shop uuid, _counter uuid)
RETURNS TABLE(product_id uuid, quantity int)
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = public AS $$
BEGIN
  IF NOT public.is_shop_member(_shop) THEN RAISE EXCEPTION 'forbidden'; END IF;
  IF NOT EXISTS (SELECT 1 FROM public.service_counters WHERE id = _counter AND shop_id = _shop AND active) THEN
    RAISE EXCEPTION 'counter_not_found_or_inactive';
  END IF;
  RETURN QUERY
  SELECT b.product_id, b.quantity FROM public.counter_stock_balances b
  WHERE b.shop_id = _shop AND b.service_counter_id = _counter;
END $$;

-- Count sale quantities (including glasses/cups), not bottle-equivalent stock depletion.
CREATE OR REPLACE FUNCTION public.counter_sales_report(
  _shop uuid, _from timestamptz DEFAULT date_trunc('day', now()), _to timestamptz DEFAULT now()
)
RETURNS TABLE(counter_id uuid, counter_name text, sale_count bigint, units bigint, revenue bigint)
LANGUAGE sql STABLE SECURITY DEFINER SET search_path = public AS $$
  SELECT c.id, coalesce(c.name, 'Unassigned')::text,
         count(s.id), coalesce(sum(s.qty), 0)::bigint, coalesce(sum(s.total), 0)::bigint
  FROM (SELECT id, name FROM public.service_counters WHERE shop_id = _shop AND active
        UNION ALL SELECT NULL::uuid, 'Unassigned') c
  LEFT JOIN public.sales s
    ON s.shop_id = _shop
   AND s.source_counter_id IS NOT DISTINCT FROM c.id
   AND s.undone_at IS NULL
   AND s.created_at >= coalesce(_from, date_trunc('day', now()))
   AND s.created_at < coalesce(_to, now())
  WHERE public.is_shop_member(_shop)
  GROUP BY c.id, c.name
  ORDER BY c.id NULLS LAST, c.name;
$$;

-- Extend the existing platform business list without changing other account fields.
DROP FUNCTION IF EXISTS public.admin_list_businesses();
CREATE FUNCTION public.admin_list_businesses()
RETURNS TABLE(
  shop_id uuid, shop_name text, status text, business_type text, business_size text, feature_flags jsonb,
  owner_email text, member_count bigint, product_count bigint, stock_units bigint,
  created_at timestamptz, suspended_at timestamptz, closed_at timestamptz, lifecycle_reason text,
  counter_inventory_mode text, counter_count bigint
)
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
BEGIN
  IF NOT public.is_platform_admin() THEN RAISE EXCEPTION 'forbidden'; END IF;
  RETURN QUERY
  SELECT s.id::uuid, s.name::text, s.status::text, s.business_type::text, s.business_size::text, s.feature_flags,
    coalesce(s.owner_email, (SELECT u.email FROM auth.users u JOIN public.shop_members om ON om.user_id = u.id
      WHERE om.shop_id = s.id AND om.role = 'owner' LIMIT 1), 'Pending owner enrollment')::text,
    (SELECT count(*)::bigint FROM public.shop_members m WHERE m.shop_id = s.id),
    (SELECT count(*)::bigint FROM public.products p WHERE p.shop_id = s.id AND NOT p.archived),
    (SELECT coalesce(sum(p.stock), 0)::bigint FROM public.products p WHERE p.shop_id = s.id AND NOT p.archived),
    s.created_at::timestamptz, s.suspended_at::timestamptz, s.closed_at::timestamptz,
    coalesce(s.suspension_reason, s.closure_reason)::text,
    s.counter_inventory_mode,
    (SELECT count(*)::bigint FROM public.service_counters c WHERE c.shop_id = s.id AND c.active)
  FROM public.shops s ORDER BY s.created_at DESC;
END $$;

CREATE OR REPLACE FUNCTION public.my_account()
RETURNS json LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = public AS $$
DECLARE result json;
BEGIN
  IF auth.uid() IS NULL THEN RAISE EXCEPTION 'not_authenticated'; END IF;
  SELECT json_build_object(
    'user_id', auth.uid(), 'email', (SELECT email FROM auth.users WHERE id = auth.uid()),
    'is_platform_admin', public.is_platform_admin(),
    'memberships', coalesce((SELECT json_agg(json_build_object(
      'shop_id', m.shop_id, 'shop_name', s.name, 'role', m.role, 'status', s.status,
      'employment_status', m.employment_status, 'business_type', s.business_type, 'business_size', s.business_size,
      'feature_flags', s.feature_flags, 'currency', s.currency, 'low_stock_threshold', s.low_stock_threshold,
      'counter_inventory_mode', s.counter_inventory_mode
    ) ORDER BY s.created_at DESC) FROM public.shop_members m JOIN public.shops s ON s.id = m.shop_id
      WHERE m.user_id = auth.uid()), '[]'::json)
  ) INTO result;
  RETURN result;
END $$;

-- Keep direct legacy RPCs from bypassing per-counter inventory and audit records.
REVOKE EXECUTE ON FUNCTION public.receive_stock_with_cost(uuid,int,int,text,text,text),
  public.receive_stock(uuid,int),
  public.add_from_catalog_with_cost(uuid,uuid,int,int,int),
  public.add_from_catalog(uuid,uuid,int,int),
  public.register_product_with_cost(uuid,text,text,int,int,text,int,text,public.product_type,text,text),
  public.register_product(uuid,text,text,int,int,text,text,public.product_type,text,text),
  public.adjust_stock(uuid,int,text),
  public.record_sale_unit(uuid,int,text,int),
  public.record_sale(uuid,int),
  public.record_table_sale(uuid,uuid,uuid,int,text,int),
  public.undo_sale(uuid,uuid)
FROM PUBLIC, anon, authenticated;

REVOKE EXECUTE ON FUNCTION public.seed_default_service_counter(),
  public.admin_list_businesses(),
  public.admin_create_business_with_counter_setup(text,text,text,int),
  public.create_service_counter(uuid,text),
  public.rename_service_counter(uuid,uuid,text),
  public.set_service_counter_active(uuid,boolean),
  public.receive_stock_at_counter(uuid,uuid,int,int,text,text,text),
  public.add_from_catalog_at_counter(uuid,uuid,uuid,int,int,int),
  public.register_product_at_counter(uuid,text,text,int,int,uuid,text,int,text,public.product_type,text,text),
  public.adjust_counter_stock(uuid,uuid,int,text),
  public.transfer_counter_stock(uuid,uuid,uuid,uuid,int,text),
  public.undo_sale_from_counter(uuid),
  public.counter_stock_report(uuid,uuid),
  public.record_sale_unit_from_counter(uuid,uuid,int,text,int),
  public.record_table_sale_from_counter(uuid,uuid,uuid,uuid,int,text,int),
  public.my_account()
FROM PUBLIC, anon;

GRANT EXECUTE ON FUNCTION public.admin_list_businesses(),
  public.admin_create_business_with_counter_setup(text,text,text,int),
  public.create_service_counter(uuid,text),
  public.rename_service_counter(uuid,uuid,text),
  public.set_service_counter_active(uuid,boolean),
  public.receive_stock_at_counter(uuid,uuid,int,int,text,text,text),
  public.add_from_catalog_at_counter(uuid,uuid,uuid,int,int,int),
  public.register_product_at_counter(uuid,text,text,int,int,uuid,text,int,text,public.product_type,text,text),
  public.adjust_counter_stock(uuid,uuid,int,text),
  public.transfer_counter_stock(uuid,uuid,uuid,uuid,int,text),
  public.undo_sale_from_counter(uuid),
  public.counter_stock_report(uuid,uuid),
  public.record_sale_unit_from_counter(uuid,uuid,int,text,int),
  public.record_table_sale_from_counter(uuid,uuid,uuid,uuid,int,text,int),
  public.my_account()
TO authenticated;

REVOKE EXECUTE ON FUNCTION public.admin_list_businesses(),
  public.admin_create_business_with_counter_setup(text,text,text,int),
  public.rename_service_counter(uuid,uuid,text),
  public.set_service_counter_active(uuid,boolean),
  public.receive_stock_at_counter(uuid,uuid,int,int,text,text,text),
  public.add_from_catalog_at_counter(uuid,uuid,uuid,int,int,int),
  public.register_product_at_counter(uuid,text,text,int,int,uuid,text,int,text,public.product_type,text,text),
  public.adjust_counter_stock(uuid,uuid,int,text),
  public.transfer_counter_stock(uuid,uuid,uuid,uuid,int,text),
  public.undo_sale_from_counter(uuid),
  public.counter_stock_report(uuid,uuid),
  public.record_sale_unit_from_counter(uuid,uuid,int,text,int),
  public.record_table_sale_from_counter(uuid,uuid,uuid,uuid,int,text,int),
  public.my_account()
FROM anon;

REVOKE EXECUTE ON FUNCTION public.counter_sales_report(uuid,timestamptz,timestamptz) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.counter_sales_report(uuid,timestamptz,timestamptz) TO authenticated;
