-- SaaS tenancy, lifecycle controls, platform administration, auditability,
-- and FIFO stock costing. The database remains one shared schema: every
-- business-owned row is scoped by shop_id and every access path is RLS/RPC gated.

ALTER TABLE public.shops
  ADD COLUMN IF NOT EXISTS status text NOT NULL DEFAULT 'active'
    CHECK (status IN ('active', 'suspended', 'closed')),
  ADD COLUMN IF NOT EXISTS suspended_at timestamptz,
  ADD COLUMN IF NOT EXISTS suspended_by uuid,
  ADD COLUMN IF NOT EXISTS suspension_reason text,
  ADD COLUMN IF NOT EXISTS closed_at timestamptz,
  ADD COLUMN IF NOT EXISTS closed_by uuid,
  ADD COLUMN IF NOT EXISTS closure_reason text;

ALTER TABLE public.products
  ADD COLUMN IF NOT EXISTS average_cost int NOT NULL DEFAULT 0
    CHECK (average_cost >= 0);

ALTER TABLE public.sales
  ADD COLUMN IF NOT EXISTS unit_name text NOT NULL DEFAULT 'Bottle',
  ADD COLUMN IF NOT EXISTS stock_qty int NOT NULL DEFAULT 1 CHECK (stock_qty > 0),
  ADD COLUMN IF NOT EXISTS unit_cost_total int NOT NULL DEFAULT 0 CHECK (unit_cost_total >= 0),
  ADD COLUMN IF NOT EXISTS profit_total int NOT NULL DEFAULT 0;

ALTER TABLE public.stock_receipts
  ADD COLUMN IF NOT EXISTS unit_cost int NOT NULL DEFAULT 0 CHECK (unit_cost >= 0),
  ADD COLUMN IF NOT EXISTS supplier text,
  ADD COLUMN IF NOT EXISTS reference text,
  ADD COLUMN IF NOT EXISTS notes text;

CREATE TABLE IF NOT EXISTS public.platform_admins (
  user_id uuid PRIMARY KEY,
  created_at timestamptz NOT NULL DEFAULT now(),
  created_by uuid
);

CREATE TABLE IF NOT EXISTS public.audit_events (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  shop_id uuid REFERENCES public.shops(id) ON DELETE SET NULL,
  actor_user_id uuid,
  action text NOT NULL CHECK (length(action) BETWEEN 1 AND 100),
  entity_type text NOT NULL CHECK (length(entity_type) BETWEEN 1 AND 100),
  entity_id uuid,
  metadata jsonb NOT NULL DEFAULT '{}'::jsonb,
  created_at timestamptz NOT NULL DEFAULT now()
);
CREATE INDEX IF NOT EXISTS audit_events_shop_time_idx
  ON public.audit_events(shop_id, created_at DESC);
CREATE INDEX IF NOT EXISTS audit_events_actor_time_idx
  ON public.audit_events(actor_user_id, created_at DESC);

CREATE TABLE IF NOT EXISTS public.stock_batches (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  shop_id uuid NOT NULL REFERENCES public.shops(id) ON DELETE CASCADE,
  product_id uuid NOT NULL REFERENCES public.products(id) ON DELETE CASCADE,
  received_qty int NOT NULL CHECK (received_qty > 0),
  remaining_qty int NOT NULL CHECK (remaining_qty >= 0 AND remaining_qty <= received_qty),
  unit_cost int NOT NULL DEFAULT 0 CHECK (unit_cost >= 0),
  received_by uuid NOT NULL,
  received_at timestamptz NOT NULL DEFAULT now(),
  receipt_id uuid REFERENCES public.stock_receipts(id) ON DELETE SET NULL,
  reference text,
  notes text
);
CREATE INDEX IF NOT EXISTS stock_batches_fifo_idx
  ON public.stock_batches(product_id, received_at, id)
  WHERE remaining_qty > 0;
CREATE INDEX IF NOT EXISTS stock_batches_shop_idx
  ON public.stock_batches(shop_id, received_at DESC);

CREATE TABLE IF NOT EXISTS public.sale_batch_allocations (
  sale_id uuid NOT NULL REFERENCES public.sales(id) ON DELETE CASCADE,
  batch_id uuid NOT NULL REFERENCES public.stock_batches(id) ON DELETE RESTRICT,
  qty int NOT NULL CHECK (qty > 0),
  unit_cost int NOT NULL CHECK (unit_cost >= 0),
  PRIMARY KEY (sale_id, batch_id)
);
CREATE INDEX IF NOT EXISTS sale_batch_allocations_batch_idx
  ON public.sale_batch_allocations(batch_id);

-- Existing stock was not costed. Preserve it in one zero-cost opening batch so
-- it is still auditable and can be consumed safely after this migration.
INSERT INTO public.stock_batches(
  shop_id, product_id, received_qty, remaining_qty, unit_cost, received_by, received_at, notes
)
SELECT p.shop_id, p.id, p.stock, p.stock, p.average_cost, s.created_by, p.created_at,
       'Opening balance migrated from legacy stock'
FROM public.products p
JOIN public.shops s ON s.id = p.shop_id
WHERE p.stock > 0
  AND NOT EXISTS (
    SELECT 1 FROM public.stock_batches b WHERE b.product_id = p.id
  );

UPDATE public.sales
SET stock_qty = CASE
      WHEN lower(coalesce(unit_name, 'Bottle')) IN ('bottle', 'can', 'unit') THEN qty
      ELSE 1
    END,
    profit_total = total - unit_cost_total;

GRANT SELECT ON public.platform_admins, public.audit_events, public.stock_batches,
  public.sale_batch_allocations TO authenticated;
GRANT ALL ON public.platform_admins, public.audit_events, public.stock_batches,
  public.sale_batch_allocations TO service_role;

ALTER TABLE public.platform_admins ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.audit_events ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.stock_batches ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.sale_batch_allocations ENABLE ROW LEVEL SECURITY;

CREATE OR REPLACE FUNCTION public.is_platform_admin()
RETURNS boolean
LANGUAGE sql STABLE SECURITY DEFINER SET search_path = public AS $$
  SELECT EXISTS (
    SELECT 1 FROM public.platform_admins WHERE user_id = auth.uid()
  )
$$;

CREATE OR REPLACE FUNCTION public.is_shop_active(_shop uuid)
RETURNS boolean
LANGUAGE sql STABLE SECURITY DEFINER SET search_path = public AS $$
  SELECT EXISTS (
    SELECT 1 FROM public.shops WHERE id = _shop AND status = 'active'
  )
$$;

CREATE OR REPLACE FUNCTION public.has_shop_role(_shop uuid, _roles public.shop_role[])
RETURNS boolean
LANGUAGE sql STABLE SECURITY DEFINER SET search_path = public AS $$
  SELECT public.is_shop_active(_shop)
     AND EXISTS (
       SELECT 1
       FROM public.shop_members
       WHERE shop_id = _shop
         AND user_id = auth.uid()
         AND role = ANY(_roles)
     )
$$;

CREATE OR REPLACE FUNCTION public.is_shop_member(_shop uuid)
RETURNS boolean
LANGUAGE sql STABLE SECURITY DEFINER SET search_path = public AS $$
  SELECT public.has_shop_role(
    _shop,
    ARRAY['owner','manager','cashier','inventory_clerk']::public.shop_role[]
  )
$$;

CREATE OR REPLACE FUNCTION public.is_shop_owner(_shop uuid)
RETURNS boolean
LANGUAGE sql STABLE SECURITY DEFINER SET search_path = public AS $$
  SELECT public.has_shop_role(_shop, ARRAY['owner']::public.shop_role[])
$$;

CREATE OR REPLACE FUNCTION public.is_shop_manager(_shop uuid)
RETURNS boolean
LANGUAGE sql STABLE SECURITY DEFINER SET search_path = public AS $$
  SELECT public.has_shop_role(_shop, ARRAY['owner','manager']::public.shop_role[])
$$;

CREATE OR REPLACE FUNCTION public.is_inventory_operator(_shop uuid)
RETURNS boolean
LANGUAGE sql STABLE SECURITY DEFINER SET search_path = public AS $$
  SELECT public.has_shop_role(
    _shop,
    ARRAY['owner','manager','inventory_clerk']::public.shop_role[]
  )
$$;

DROP POLICY IF EXISTS "members read stock batches" ON public.stock_batches;
CREATE POLICY "members read stock batches" ON public.stock_batches
  FOR SELECT TO authenticated USING (public.is_shop_member(shop_id));
DROP POLICY IF EXISTS "members read sale allocations" ON public.sale_batch_allocations;
CREATE POLICY "members read sale allocations" ON public.sale_batch_allocations
  FOR SELECT TO authenticated USING (
    EXISTS (
      SELECT 1 FROM public.sales s
      WHERE s.id = sale_id AND public.is_shop_member(s.shop_id)
    )
  );
DROP POLICY IF EXISTS "admins read platform admins" ON public.platform_admins;
CREATE POLICY "admins read platform admins" ON public.platform_admins
  FOR SELECT TO authenticated USING (public.is_platform_admin());
DROP POLICY IF EXISTS "members read audit events" ON public.audit_events;
CREATE POLICY "members read audit events" ON public.audit_events
  FOR SELECT TO authenticated USING (
    public.is_platform_admin() OR (shop_id IS NOT NULL AND public.is_shop_member(shop_id))
  );

CREATE OR REPLACE FUNCTION public.write_audit_event(
  _shop uuid,
  _action text,
  _entity_type text,
  _entity_id uuid,
  _metadata jsonb DEFAULT '{}'::jsonb
)
RETURNS void
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
BEGIN
  INSERT INTO public.audit_events(shop_id, actor_user_id, action, entity_type, entity_id, metadata)
  VALUES (_shop, auth.uid(), _action, _entity_type, _entity_id, coalesce(_metadata, '{}'::jsonb));
END $$;

-- User session bootstrap. Suspended/closed members are returned with their
-- status so the client can show a useful message, but active-workspace RPCs
-- remain blocked by is_shop_member/is_shop_active.
CREATE OR REPLACE FUNCTION public.my_account()
RETURNS json
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = public AS $$
DECLARE result json;
BEGIN
  IF auth.uid() IS NULL THEN RAISE EXCEPTION 'not_authenticated'; END IF;
  SELECT json_build_object(
    'user_id', auth.uid(),
    'email', (SELECT email FROM auth.users WHERE id = auth.uid()),
    'is_platform_admin', public.is_platform_admin(),
    'memberships', coalesce((
      SELECT json_agg(json_build_object(
        'shop_id', m.shop_id,
        'shop_name', s.name,
        'role', m.role,
        'status', s.status,
        'currency', s.currency,
        'low_stock_threshold', s.low_stock_threshold
      ) ORDER BY s.created_at DESC)
      FROM public.shop_members m
      JOIN public.shops s ON s.id = m.shop_id
      WHERE m.user_id = auth.uid()
    ), '[]'::json)
  ) INTO result;
  RETURN result;
END $$;

-- Re-assert business lifecycle at creation and membership mutation.
CREATE OR REPLACE FUNCTION public.create_shop(_name text)
RETURNS public.shops
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE s public.shops;
BEGIN
  IF auth.uid() IS NULL THEN RAISE EXCEPTION 'not_authenticated'; END IF;
  IF coalesce(length(trim(_name)), 0) NOT BETWEEN 1 AND 120 THEN
    RAISE EXCEPTION 'invalid_business_name';
  END IF;
  INSERT INTO public.shops(name, created_by, status)
  VALUES (trim(_name), auth.uid(), 'active') RETURNING * INTO s;
  INSERT INTO public.shop_members(shop_id, user_id, role)
  VALUES (s.id, auth.uid(), 'owner');
  PERFORM public.write_audit_event(s.id, 'business_created', 'shop', s.id,
    jsonb_build_object('name', s.name));
  RETURN s;
END $$;

CREATE OR REPLACE FUNCTION public.add_member_by_email(
  _shop uuid, _email text, _role public.shop_role DEFAULT 'cashier'
)
RETURNS void
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE uid uuid;
BEGIN
  IF NOT public.is_shop_manager(_shop) THEN RAISE EXCEPTION 'forbidden'; END IF;
  IF _role = 'owner' THEN RAISE EXCEPTION 'owner_role_reserved'; END IF;
  SELECT id INTO uid FROM auth.users WHERE lower(email) = lower(trim(_email));
  IF uid IS NULL THEN RAISE EXCEPTION 'user_not_found'; END IF;
  INSERT INTO public.shop_members(shop_id, user_id, role)
  VALUES (_shop, uid, _role)
  ON CONFLICT (shop_id, user_id) DO UPDATE SET role = EXCLUDED.role;
  PERFORM public.write_audit_event(_shop, 'member_role_changed', 'user', uid,
    jsonb_build_object('email', lower(trim(_email)), 'role', _role));
END $$;

-- Platform administration. "Remove" is a retained closed state instead of
-- a destructive delete, so the owner can be reopened and historical data stays.
CREATE OR REPLACE FUNCTION public.admin_list_businesses()
RETURNS TABLE(
  shop_id uuid,
  shop_name text,
  status text,
  owner_email text,
  member_count bigint,
  product_count bigint,
  stock_units bigint,
  created_at timestamptz,
  suspended_at timestamptz,
  closed_at timestamptz,
  lifecycle_reason text
)
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
BEGIN
  IF NOT public.is_platform_admin() THEN RAISE EXCEPTION 'forbidden'; END IF;
  RETURN QUERY
  SELECT s.id, s.name, s.status,
    (SELECT u.email FROM auth.users u WHERE u.id = s.created_by),
    (SELECT count(*) FROM public.shop_members m WHERE m.shop_id = s.id),
    (SELECT count(*) FROM public.products p WHERE p.shop_id = s.id AND NOT p.archived),
    (SELECT coalesce(sum(p.stock), 0) FROM public.products p WHERE p.shop_id = s.id AND NOT p.archived),
    s.created_at, s.suspended_at, s.closed_at,
    coalesce(s.suspension_reason, s.closure_reason)
  FROM public.shops s
  ORDER BY s.created_at DESC;
END $$;

CREATE OR REPLACE FUNCTION public.admin_create_business(_name text, _owner_email text)
RETURNS public.shops
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE s public.shops; owner_id uuid;
BEGIN
  IF NOT public.is_platform_admin() THEN RAISE EXCEPTION 'forbidden'; END IF;
  IF coalesce(length(trim(_name)), 0) NOT BETWEEN 1 AND 120 THEN
    RAISE EXCEPTION 'invalid_business_name';
  END IF;
  SELECT id INTO owner_id FROM auth.users WHERE lower(email) = lower(trim(_owner_email));
  IF owner_id IS NULL THEN RAISE EXCEPTION 'user_not_found'; END IF;
  INSERT INTO public.shops(name, created_by, status)
  VALUES (trim(_name), owner_id, 'active') RETURNING * INTO s;
  INSERT INTO public.shop_members(shop_id, user_id, role)
  VALUES (s.id, owner_id, 'owner');
  PERFORM public.write_audit_event(s.id, 'business_created_by_admin', 'shop', s.id,
    jsonb_build_object('owner_email', lower(trim(_owner_email))));
  RETURN s;
END $$;

CREATE OR REPLACE FUNCTION public.admin_set_business_status(
  _shop uuid, _status text, _reason text DEFAULT NULL
)
RETURNS public.shops
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE s public.shops;
BEGIN
  IF NOT public.is_platform_admin() THEN RAISE EXCEPTION 'forbidden'; END IF;
  IF _status NOT IN ('active', 'suspended', 'closed') THEN
    RAISE EXCEPTION 'invalid_business_status';
  END IF;
  UPDATE public.shops
  SET status = _status,
      suspended_at = CASE WHEN _status = 'suspended' THEN now() ELSE NULL END,
      suspended_by = CASE WHEN _status = 'suspended' THEN auth.uid() ELSE NULL END,
      suspension_reason = CASE WHEN _status = 'suspended' THEN nullif(trim(_reason), '') ELSE NULL END,
      closed_at = CASE WHEN _status = 'closed' THEN now() ELSE NULL END,
      closed_by = CASE WHEN _status = 'closed' THEN auth.uid() ELSE NULL END,
      closure_reason = CASE WHEN _status = 'closed' THEN nullif(trim(_reason), '') ELSE NULL END
  WHERE id = _shop
  RETURNING * INTO s;
  IF s.id IS NULL THEN RAISE EXCEPTION 'business_not_found'; END IF;
  PERFORM public.write_audit_event(_shop, 'business_status_changed', 'shop', _shop,
    jsonb_build_object('status', _status, 'reason', _reason));
  RETURN s;
END $$;

-- Internal FIFO allocation helper is embedded in the sale/receive functions so
-- callers cannot bypass cost layers or change stock directly.
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
BEGIN
  IF _qty IS NULL OR _qty < 1 THEN RAISE EXCEPTION 'invalid_quantity'; END IF;
  SELECT * INTO p FROM public.products WHERE id = _product FOR UPDATE;
  IF p.id IS NULL OR NOT public.has_shop_role(
    p.shop_id, ARRAY['owner','manager','cashier']::public.shop_role[]
  ) THEN RAISE EXCEPTION 'product_not_found'; END IF;
  IF p.archived THEN RAISE EXCEPTION 'product_not_found'; END IF;
  stock_used := CASE
    WHEN lower(coalesce(_unit_name, 'Bottle')) IN ('bottle', 'can', 'unit') THEN _qty
    ELSE 1
  END;
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
      average_cost = coalesce((
        SELECT round(sum(remaining_qty * unit_cost)::numeric / nullif(sum(remaining_qty), 0))::int
        FROM public.stock_batches WHERE product_id = p.id AND remaining_qty > 0
      ), 0),
      updated_at = now()
  WHERE id = p.id;
  PERFORM public.write_audit_event(p.shop_id, 'sale_recorded', 'sale', s.id,
    jsonb_build_object('product_id', p.id, 'stock_qty', stock_used, 'cost_total', cost_total));
  RETURN s;
END $$;

CREATE OR REPLACE FUNCTION public.record_sale(_product uuid, _qty int DEFAULT 1)
RETURNS public.sales
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
BEGIN
  RETURN public.record_sale_unit(_product, _qty, 'Bottle', NULL);
END $$;

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
  ELSE
    -- Legacy sale created before FIFO migration: restore the quantity directly.
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
      average_cost = coalesce((
        SELECT round(sum(remaining_qty * unit_cost)::numeric / nullif(sum(remaining_qty), 0))::int
        FROM public.stock_batches WHERE product_id = s.product_id AND remaining_qty > 0
      ), 0),
      updated_at = now()
  WHERE id = s.product_id;
  PERFORM public.write_audit_event(_shop, 'sale_undone', 'sale', s.id,
    jsonb_build_object('stock_qty_restored', s.stock_qty));
  RETURN s;
END $$;

CREATE OR REPLACE FUNCTION public.receive_stock_with_cost(
  _product uuid,
  _qty int,
  _unit_cost int DEFAULT 0,
  _supplier text DEFAULT NULL,
  _reference text DEFAULT NULL,
  _notes text DEFAULT NULL
)
RETURNS public.products
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE p public.products; receipt public.stock_receipts;
BEGIN
  IF _qty IS NULL OR _qty < 1 OR coalesce(_unit_cost, 0) < 0 THEN
    RAISE EXCEPTION 'invalid_stock_receipt';
  END IF;
  SELECT * INTO p FROM public.products WHERE id = _product FOR UPDATE;
  IF p.id IS NULL OR NOT public.is_inventory_operator(p.shop_id) THEN
    RAISE EXCEPTION 'product_not_found';
  END IF;
  INSERT INTO public.stock_receipts(
    shop_id, product_id, qty, is_new_product, received_by, unit_cost, supplier, reference, notes
  ) VALUES (
    p.shop_id, p.id, _qty, false, auth.uid(), coalesce(_unit_cost, 0),
    nullif(trim(_supplier), ''), nullif(trim(_reference), ''), nullif(trim(_notes), '')
  ) RETURNING * INTO receipt;
  INSERT INTO public.stock_batches(
    shop_id, product_id, received_qty, remaining_qty, unit_cost, received_by,
    receipt_id, reference, notes
  ) VALUES (
    p.shop_id, p.id, _qty, _qty, coalesce(_unit_cost, 0), auth.uid(),
    receipt.id, nullif(trim(_reference), ''), nullif(trim(_notes), '')
  );
  UPDATE public.products
  SET stock = stock + _qty,
      average_cost = CASE WHEN stock + _qty = 0 THEN 0 ELSE
        round(((stock * average_cost) + (_qty * coalesce(_unit_cost, 0)))::numeric / (stock + _qty))::int
      END,
      archived = false,
      updated_at = now()
  WHERE id = p.id RETURNING * INTO p;
  PERFORM public.write_audit_event(p.shop_id, 'stock_received', 'stock_receipt', receipt.id,
    jsonb_build_object('product_id', p.id, 'qty', _qty, 'unit_cost', _unit_cost));
  RETURN p;
END $$;

CREATE OR REPLACE FUNCTION public.receive_stock(_product uuid, _qty int)
RETURNS public.products
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
BEGIN
  RETURN public.receive_stock_with_cost(_product, _qty, 0, NULL, NULL, NULL);
END $$;

CREATE OR REPLACE FUNCTION public.add_from_catalog_with_cost(
  _shop uuid, _catalog uuid, _qty int DEFAULT 0, _price int DEFAULT NULL, _unit_cost int DEFAULT 0
)
RETURNS public.products
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE c public.catalog_items; p public.products;
BEGIN
  IF NOT public.is_inventory_operator(_shop) THEN RAISE EXCEPTION 'forbidden'; END IF;
  IF coalesce(_qty, 0) < 0 OR coalesce(_price, 0) < 0 OR coalesce(_unit_cost, 0) < 0 THEN
    RAISE EXCEPTION 'invalid_input';
  END IF;
  SELECT * INTO c FROM public.catalog_items WHERE id = _catalog;
  IF c.id IS NULL THEN RAISE EXCEPTION 'catalog_item_not_found'; END IF;
  SELECT * INTO p FROM public.products WHERE shop_id = _shop AND code = c.code FOR UPDATE;
  IF p.id IS NULL THEN
    INSERT INTO public.products(
      shop_id, catalog_item_id, code, barcode, name, brand, size, category, product_type,
      body_color, label_color, label_text_color, price, stock, average_cost, photo_url
    ) VALUES (
      _shop, c.id, c.code, c.barcode, c.name, c.brand, c.size, c.category, c.product_type,
      c.body_color, c.label_color, c.label_text_color, coalesce(_price, c.suggested_price),
      0, 0, c.image_url
    ) RETURNING * INTO p;
  ELSE
    UPDATE public.products
    SET price = coalesce(_price, price), archived = false, updated_at = now()
    WHERE id = p.id RETURNING * INTO p;
  END IF;
  IF coalesce(_qty, 0) > 0 THEN
    PERFORM public.receive_stock_with_cost(p.id, _qty, coalesce(_unit_cost, 0), NULL, NULL, 'Catalog receipt');
    SELECT * INTO p FROM public.products WHERE id = p.id;
  END IF;
  RETURN p;
END $$;

CREATE OR REPLACE FUNCTION public.add_from_catalog(
  _shop uuid, _catalog uuid, _qty int DEFAULT 0, _price int DEFAULT NULL
)
RETURNS public.products
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
BEGIN
  RETURN public.add_from_catalog_with_cost(_shop, _catalog, _qty, _price, 0);
END $$;

CREATE OR REPLACE FUNCTION public.register_product_with_cost(
  _shop uuid, _code text, _name text, _price int, _qty int, _photo_path text,
  _unit_cost int DEFAULT 0, _size text DEFAULT NULL, _type public.product_type DEFAULT 'beer',
  _brand text DEFAULT NULL, _category text DEFAULT NULL
)
RETURNS public.products
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE p public.products;
BEGIN
  IF NOT public.is_inventory_operator(_shop) THEN RAISE EXCEPTION 'forbidden'; END IF;
  IF coalesce(trim(_code), '') = '' THEN RAISE EXCEPTION 'code_required'; END IF;
  IF coalesce(trim(_name), '') = '' THEN RAISE EXCEPTION 'name_required'; END IF;
  IF _price IS NULL OR _price < 1 THEN RAISE EXCEPTION 'price_required'; END IF;
  IF _qty IS NULL OR _qty < 1 OR coalesce(_unit_cost, 0) < 0 THEN
    RAISE EXCEPTION 'invalid_quantity';
  END IF;
  IF EXISTS (SELECT 1 FROM public.products WHERE shop_id = _shop AND code = trim(_code)) THEN
    RAISE EXCEPTION 'code_exists';
  END IF;
  INSERT INTO public.products(
    shop_id, code, barcode, name, brand, size, category, product_type,
    body_color, label_color, label_text_color, price, stock, average_cost, photo_path
  ) VALUES (
    _shop, trim(_code), trim(_code), trim(_name), coalesce(_brand, trim(_name)),
    coalesce(nullif(trim(_size), ''), '-'), coalesce(_category, 'Custom beverage'), _type,
    CASE WHEN _type = 'beer' THEN '#5a3a1c' ELSE '#2a2a2a' END,
    '#e8e4d4', '#14181f', _price, 0, 0, _photo_path
  ) RETURNING * INTO p;
  PERFORM public.receive_stock_with_cost(p.id, _qty, coalesce(_unit_cost, 0), NULL, NULL, 'New product opening stock');
  SELECT * INTO p FROM public.products WHERE id = p.id;
  UPDATE public.stock_receipts SET is_new_product = true WHERE product_id = p.id
    AND received_by = auth.uid() AND notes = 'New product opening stock';
  RETURN p;
END $$;

CREATE OR REPLACE FUNCTION public.register_product(
  _shop uuid, _code text, _name text, _price int, _qty int,
  _photo_path text, _size text DEFAULT NULL, _type public.product_type DEFAULT 'beer',
  _brand text DEFAULT NULL, _category text DEFAULT NULL
)
RETURNS public.products
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
BEGIN
  RETURN public.register_product_with_cost(
    _shop, _code, _name, _price, _qty, _photo_path, 0, _size, _type, _brand, _category
  );
END $$;

CREATE OR REPLACE FUNCTION public.adjust_stock(
  _product uuid, _new_stock int, _reason text DEFAULT NULL
)
RETURNS public.products
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE
  p public.products;
  b public.stock_batches;
  remaining int;
  take_qty int;
BEGIN
  IF _new_stock IS NULL OR _new_stock < 0 THEN RAISE EXCEPTION 'invalid_stock_count'; END IF;
  SELECT * INTO p FROM public.products WHERE id = _product FOR UPDATE;
  IF p.id IS NULL OR NOT public.is_shop_manager(p.shop_id) THEN RAISE EXCEPTION 'forbidden'; END IF;
  IF _new_stock > p.stock THEN
    INSERT INTO public.stock_receipts(
      shop_id, product_id, qty, is_new_product, received_by, unit_cost, notes
    ) VALUES (
      p.shop_id, p.id, _new_stock - p.stock, false, auth.uid(), p.average_cost,
      coalesce(nullif(trim(_reason), ''), 'Positive stock adjustment')
    );
    INSERT INTO public.stock_batches(
      shop_id, product_id, received_qty, remaining_qty, unit_cost, received_by, notes
    ) VALUES (
      p.shop_id, p.id, _new_stock - p.stock, _new_stock - p.stock, p.average_cost,
      auth.uid(), coalesce(nullif(trim(_reason), ''), 'Positive stock adjustment')
    );
  ELSIF _new_stock < p.stock THEN
    remaining := p.stock - _new_stock;
    FOR b IN
      SELECT * FROM public.stock_batches
      WHERE product_id = p.id AND remaining_qty > 0
      ORDER BY received_at ASC, id ASC
      FOR UPDATE
    LOOP
      EXIT WHEN remaining = 0;
      take_qty := LEAST(remaining, b.remaining_qty);
      UPDATE public.stock_batches SET remaining_qty = remaining_qty - take_qty WHERE id = b.id;
      remaining := remaining - take_qty;
    END LOOP;
    IF remaining > 0 THEN RAISE EXCEPTION 'stock_ledger_out_of_sync'; END IF;
    INSERT INTO public.stock_receipts(
      shop_id, product_id, qty, is_new_product, received_by, unit_cost, notes
    ) VALUES (
      p.shop_id, p.id, p.stock - _new_stock, false, auth.uid(), p.average_cost,
      coalesce(nullif(trim(_reason), ''), 'Negative stock adjustment')
    );
  END IF;
  UPDATE public.products
  SET stock = _new_stock,
      average_cost = coalesce((
        SELECT round(sum(remaining_qty * unit_cost)::numeric / nullif(sum(remaining_qty), 0))::int
        FROM public.stock_batches WHERE product_id = p.id AND remaining_qty > 0
      ), 0),
      updated_at = now()
  WHERE id = p.id RETURNING * INTO p;
  PERFORM public.write_audit_event(p.shop_id, 'stock_adjusted', 'product', p.id,
    jsonb_build_object('new_stock', _new_stock, 'reason', _reason));
  RETURN p;
END $$;

-- Execute only through the explicit RPCs; direct stock/cost writes remain denied.
REVOKE EXECUTE ON FUNCTION public.write_audit_event(uuid,text,text,uuid,jsonb),
  public.admin_list_businesses(), public.admin_create_business(text,text),
  public.admin_set_business_status(uuid,text,text), public.record_sale_unit(uuid,int,text,int),
  public.receive_stock_with_cost(uuid,int,int,text,text,text),
  public.add_from_catalog_with_cost(uuid,uuid,int,int,int),
  public.register_product_with_cost(uuid,text,text,int,int,text,int,text,public.product_type,text,text),
  public.adjust_stock(uuid,int,text), public.my_account() FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.my_account(), public.record_sale_unit(uuid,int,text,int),
  public.receive_stock_with_cost(uuid,int,int,text,text,text),
  public.add_from_catalog_with_cost(uuid,uuid,int,int,int),
  public.register_product_with_cost(uuid,text,text,int,int,text,int,text,public.product_type,text,text),
  public.adjust_stock(uuid,int,text) TO authenticated;
GRANT EXECUTE ON FUNCTION public.admin_list_businesses(), public.admin_create_business(text,text),
  public.admin_set_business_status(uuid,text,text) TO authenticated;

-- Keep legacy function grants and tighten their internals through the replaced bodies.
GRANT EXECUTE ON FUNCTION public.create_shop(text),
  public.add_member_by_email(uuid,text,public.shop_role), public.record_sale(uuid,int),
  public.undo_sale(uuid,uuid), public.receive_stock(uuid,int),
  public.add_from_catalog(uuid,uuid,int,int),
  public.register_product(uuid,text,text,int,int,text,text,public.product_type,text,text)
  TO authenticated;

-- Refresh the real-time publication for cost and lifecycle visibility.
ALTER PUBLICATION supabase_realtime ADD TABLE public.stock_batches;

COMMENT ON TABLE public.stock_batches IS
  'FIFO inventory cost layers; each receipt can have its own unit_cost.';
COMMENT ON COLUMN public.products.average_cost IS
  'Weighted average of remaining FIFO layers for display/reporting only.';
COMMENT ON COLUMN public.shops.status IS
  'active grants access; suspended and closed retain data but block all business access.';
