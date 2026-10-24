-- Owner/manager table management. A table can only be removed when it has no
-- open bill lines; historical settled lines remain protected by FK history.
ALTER TABLE public.dining_tables
  ADD COLUMN IF NOT EXISTS archived boolean NOT NULL DEFAULT false;

CREATE OR REPLACE FUNCTION public.delete_dining_table(_shop uuid, _table uuid)
RETURNS void
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE table_name text;
BEGIN
  IF NOT public.is_shop_manager(_shop) THEN RAISE EXCEPTION 'forbidden'; END IF;
  SELECT name INTO table_name
  FROM public.dining_tables
  WHERE id = _table AND shop_id = _shop
  FOR UPDATE;
  IF table_name IS NULL THEN RAISE EXCEPTION 'table_not_found'; END IF;
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
END $$;

GRANT EXECUTE ON FUNCTION public.delete_dining_table(uuid, uuid) TO authenticated;
NOTIFY pgrst, 'reload schema';
