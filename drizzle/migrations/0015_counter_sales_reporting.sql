-- Multi-counter club support.
-- A sale keeps the waiter in sold_by and the physical source counter in source_counter_id.
-- Existing sales remain valid and are reported under "Unassigned" until attributed.

CREATE TABLE IF NOT EXISTS public.service_counters (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  shop_id uuid NOT NULL REFERENCES public.shops(id) ON DELETE CASCADE,
  name text NOT NULL CHECK (length(trim(name)) BETWEEN 1 AND 60),
  active boolean NOT NULL DEFAULT true,
  created_by uuid NOT NULL,
  created_at timestamptz NOT NULL DEFAULT now(),
  UNIQUE (shop_id, name)
);

ALTER TABLE public.sales
  ADD COLUMN IF NOT EXISTS source_counter_id uuid REFERENCES public.service_counters(id) ON DELETE SET NULL;

CREATE INDEX IF NOT EXISTS service_counters_shop_idx
  ON public.service_counters(shop_id, active, name);
CREATE INDEX IF NOT EXISTS sales_source_counter_time_idx
  ON public.sales(source_counter_id, created_at DESC)
  WHERE source_counter_id IS NOT NULL;

ALTER TABLE public.service_counters ENABLE ROW LEVEL SECURITY;
DROP POLICY IF EXISTS "members read service counters" ON public.service_counters;
CREATE POLICY "members read service counters" ON public.service_counters
  FOR SELECT TO authenticated USING (public.is_shop_member(shop_id));
GRANT SELECT ON public.service_counters TO authenticated;
GRANT ALL ON public.service_counters TO service_role;

CREATE OR REPLACE FUNCTION public.create_service_counter(_shop uuid, _name text)
RETURNS public.service_counters
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE c public.service_counters;
BEGIN
  IF NOT public.is_shop_manager(_shop) THEN RAISE EXCEPTION 'forbidden'; END IF;
  IF length(trim(coalesce(_name, ''))) NOT BETWEEN 1 AND 60 THEN RAISE EXCEPTION 'invalid_counter_name'; END IF;
  INSERT INTO public.service_counters(shop_id, name, created_by)
  VALUES (_shop, trim(_name), auth.uid())
  RETURNING * INTO c;
  PERFORM public.write_audit_event(_shop, 'counter_created', 'service_counter', c.id, jsonb_build_object('name', c.name));
  RETURN c;
END $$;

CREATE OR REPLACE FUNCTION public.set_service_counter_active(_counter uuid, _active boolean)
RETURNS public.service_counters
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE c public.service_counters;
BEGIN
  SELECT * INTO c FROM public.service_counters WHERE id = _counter FOR UPDATE;
  IF c.id IS NULL OR NOT public.is_shop_manager(c.shop_id) THEN RAISE EXCEPTION 'forbidden'; END IF;
  UPDATE public.service_counters SET active = coalesce(_active, true) WHERE id = _counter RETURNING * INTO c;
  RETURN c;
END $$;

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
  IF NOT public.has_shop_role(p.shop_id, ARRAY['owner','manager','cashier']::public.shop_role[]) THEN RAISE EXCEPTION 'forbidden'; END IF;
  SELECT * INTO s FROM public.record_sale_unit(_product, _qty, _unit_name, _unit_price);
  UPDATE public.sales SET source_counter_id = c.id WHERE id = s.id RETURNING * INTO s;
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
  SELECT * INTO o FROM public.record_table_sale(_shop, _table, _product, _qty, _unit_name, _unit_price);
  UPDATE public.sales SET source_counter_id = c.id WHERE id = o.sale_id;
  RETURN o;
END $$;

CREATE OR REPLACE FUNCTION public.counter_sales_report(
  _shop uuid, _from timestamptz DEFAULT date_trunc('day', now()), _to timestamptz DEFAULT now()
)
RETURNS TABLE(
  counter_id uuid,
  counter_name text,
  sale_count bigint,
  units bigint,
  revenue bigint
)
LANGUAGE sql STABLE SECURITY DEFINER SET search_path = public AS $$
  SELECT c.id, coalesce(c.name, 'Unassigned')::text,
         count(s.id), coalesce(sum(s.stock_qty), 0)::bigint, coalesce(sum(s.total), 0)::bigint
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

GRANT EXECUTE ON FUNCTION public.create_service_counter(uuid,text),
  public.set_service_counter_active(uuid,boolean),
  public.record_sale_unit_from_counter(uuid,uuid,int,text,int),
  public.record_table_sale_from_counter(uuid,uuid,uuid,uuid,int,text,int),
  public.counter_sales_report(uuid,timestamptz,timestamptz) TO authenticated;
