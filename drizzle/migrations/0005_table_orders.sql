-- Production table service persistence. All rows are tenant-scoped and all writes go through RPCs.
CREATE TABLE IF NOT EXISTS public.dining_tables (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  shop_id uuid NOT NULL REFERENCES public.shops(id) ON DELETE CASCADE,
  name text NOT NULL CHECK (length(trim(name)) BETWEEN 1 AND 40),
  created_at timestamptz NOT NULL DEFAULT now(),
  UNIQUE (shop_id, name)
);

CREATE TABLE IF NOT EXISTS public.table_orders (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  shop_id uuid NOT NULL REFERENCES public.shops(id) ON DELETE CASCADE,
  table_id uuid NOT NULL REFERENCES public.dining_tables(id) ON DELETE CASCADE,
  sale_id uuid NOT NULL REFERENCES public.sales(id) ON DELETE CASCADE,
  product_id uuid NOT NULL REFERENCES public.products(id) ON DELETE RESTRICT,
  product_name text NOT NULL,
  unit_name text NOT NULL DEFAULT 'Bottle',
  qty int NOT NULL CHECK (qty > 0),
  unit_price int NOT NULL CHECK (unit_price > 0),
  total int NOT NULL CHECK (total > 0),
  served_at timestamptz NOT NULL DEFAULT now(),
  UNIQUE (sale_id)
);

CREATE INDEX IF NOT EXISTS dining_tables_shop_idx ON public.dining_tables(shop_id, created_at, name);
CREATE INDEX IF NOT EXISTS table_orders_shop_time_idx ON public.table_orders(shop_id, served_at DESC);

ALTER TABLE public.dining_tables ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.table_orders ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS "members read dining tables" ON public.dining_tables;
CREATE POLICY "members read dining tables" ON public.dining_tables
  FOR SELECT TO authenticated USING (public.is_shop_member(shop_id));
DROP POLICY IF EXISTS "members read table orders" ON public.table_orders;
CREATE POLICY "members read table orders" ON public.table_orders
  FOR SELECT TO authenticated USING (public.is_shop_member(shop_id));

CREATE OR REPLACE FUNCTION public.create_dining_table(_shop uuid, _name text)
RETURNS public.dining_tables
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE t public.dining_tables;
BEGIN
  IF NOT public.is_shop_manager(_shop) THEN RAISE EXCEPTION 'forbidden'; END IF;
  IF length(trim(coalesce(_name, ''))) NOT BETWEEN 1 AND 40 THEN RAISE EXCEPTION 'invalid_table_name'; END IF;
  INSERT INTO public.dining_tables(shop_id, name) VALUES (_shop, trim(_name)) RETURNING * INTO t;
  PERFORM public.write_audit_event(_shop, 'create', 'dining_table', t.id,
    jsonb_build_object('name', t.name));
  RETURN t;
END $$;

CREATE OR REPLACE FUNCTION public.record_table_sale(
  _shop uuid, _table uuid, _product uuid, _qty int, _unit_name text, _unit_price int
)
RETURNS public.table_orders
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE t public.dining_tables; p public.products; s public.sales; o public.table_orders;
BEGIN
  IF NOT public.is_shop_member(_shop) THEN RAISE EXCEPTION 'forbidden'; END IF;
  SELECT * INTO t FROM public.dining_tables WHERE id = _table AND shop_id = _shop;
  IF t.id IS NULL THEN RAISE EXCEPTION 'table_not_found'; END IF;
  SELECT * INTO p FROM public.products WHERE id = _product AND shop_id = _shop AND NOT archived;
  IF p.id IS NULL THEN RAISE EXCEPTION 'product_not_found'; END IF;
  IF _qty IS NULL OR _qty < 1 OR _unit_price IS NULL OR _unit_price < 1 THEN RAISE EXCEPTION 'invalid_sale'; END IF;
  SELECT * INTO s FROM public.record_sale_unit(_product, _qty, coalesce(nullif(trim(_unit_name), ''), 'Bottle'), _unit_price);
  INSERT INTO public.table_orders(shop_id, table_id, sale_id, product_id, product_name, unit_name, qty, unit_price, total)
  VALUES (_shop, t.id, s.id, p.id, p.name, coalesce(nullif(trim(_unit_name), ''), 'Bottle'), _qty, _unit_price, _qty * _unit_price)
  RETURNING * INTO o;
  RETURN o;
END $$;

GRANT EXECUTE ON FUNCTION public.create_dining_table(uuid,text), public.record_table_sale(uuid,uuid,uuid,int,text,int) TO authenticated;
