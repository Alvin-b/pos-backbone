-- Align waiter/cashier table creation with the POS role model while keeping deletion
-- restricted to managers and preserving settled table history through soft deletion.
ALTER TABLE public.dining_tables
  ADD COLUMN IF NOT EXISTS archived boolean NOT NULL DEFAULT false;

DROP FUNCTION IF EXISTS public.create_dining_table(uuid, text);
CREATE FUNCTION public.create_dining_table(_shop uuid, _name text)
RETURNS public.dining_tables
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  t public.dining_tables;
BEGIN
  IF NOT public.has_shop_role(
    _shop,
    ARRAY['owner', 'manager', 'cashier']::public.shop_role[]
  ) THEN
    RAISE EXCEPTION 'forbidden';
  END IF;
  IF length(trim(coalesce(_name, ''))) NOT BETWEEN 1 AND 40 THEN
    RAISE EXCEPTION 'invalid_table_name';
  END IF;

  INSERT INTO public.dining_tables(shop_id, name)
  VALUES (_shop, trim(_name))
  ON CONFLICT (shop_id, name) DO NOTHING
  RETURNING * INTO t;

  IF NOT FOUND THEN
    SELECT * INTO t
    FROM public.dining_tables
    WHERE shop_id = _shop AND name = trim(_name)
    FOR UPDATE;
    IF t.id IS NULL THEN RAISE EXCEPTION 'table_not_found'; END IF;
    IF t.archived THEN
      UPDATE public.dining_tables SET archived = false WHERE id = t.id
      RETURNING * INTO t;
      PERFORM public.write_audit_event(
        _shop, 'restore', 'dining_table', t.id,
        jsonb_build_object('name', t.name)
      );
    END IF;
  ELSE
    PERFORM public.write_audit_event(
      _shop, 'create', 'dining_table', t.id,
      jsonb_build_object('name', t.name)
    );
  END IF;
  RETURN t;
END;
$$;

REVOKE ALL ON FUNCTION public.create_dining_table(uuid, text)
  FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.create_dining_table(uuid, text) TO authenticated;

DROP FUNCTION IF EXISTS public.delete_dining_table(uuid, uuid);
CREATE FUNCTION public.delete_dining_table(_shop uuid, _table uuid)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  table_name text;
BEGIN
  IF NOT public.is_shop_manager(_shop) THEN RAISE EXCEPTION 'forbidden'; END IF;

  SELECT name INTO table_name
  FROM public.dining_tables
  WHERE id = _table AND shop_id = _shop AND archived = false
  FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'table_not_found'; END IF;

  IF EXISTS (
    SELECT 1 FROM public.table_orders
    WHERE shop_id = _shop AND table_id = _table AND settlement_id IS NULL
  ) THEN
    RAISE EXCEPTION 'table_has_open_bill';
  END IF;

  UPDATE public.dining_tables
  SET archived = true
  WHERE id = _table AND shop_id = _shop;
  PERFORM public.write_audit_event(
    _shop, 'delete', 'dining_table', _table,
    jsonb_build_object('name', table_name)
  );
END;
$$;

REVOKE ALL ON FUNCTION public.delete_dining_table(uuid, uuid)
  FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.delete_dining_table(uuid, uuid) TO authenticated;

NOTIFY pgrst, 'reload schema';
