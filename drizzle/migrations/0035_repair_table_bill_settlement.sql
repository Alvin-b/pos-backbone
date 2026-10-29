-- Repair older deployments where the table-bill settlement migrations were
-- not applied even though the Android client already calls this RPC.
CREATE TABLE IF NOT EXISTS public.table_bill_settlements (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  shop_id uuid NOT NULL REFERENCES public.shops(id) ON DELETE CASCADE,
  table_id uuid NOT NULL REFERENCES public.dining_tables(id) ON DELETE RESTRICT,
  client_operation_id uuid NOT NULL,
  amount bigint NOT NULL CHECK (amount > 0),
  payment_method text NOT NULL CHECK (payment_method IN ('cash', 'mpesa', 'card', 'other')),
  settled_by uuid NOT NULL,
  settled_at timestamptz NOT NULL DEFAULT now(),
  UNIQUE (shop_id, client_operation_id)
);

ALTER TABLE public.table_orders
  ADD COLUMN IF NOT EXISTS settlement_id uuid;

DO $$
BEGIN
  IF NOT EXISTS (
    SELECT 1 FROM pg_constraint
    WHERE conname = 'table_orders_settlement_id_fkey'
      AND conrelid = 'public.table_orders'::regclass
  ) THEN
    ALTER TABLE public.table_orders
      ADD CONSTRAINT table_orders_settlement_id_fkey
      FOREIGN KEY (settlement_id)
      REFERENCES public.table_bill_settlements(id)
      ON DELETE RESTRICT;
  END IF;
END $$;

CREATE INDEX IF NOT EXISTS table_orders_open_bill_idx
  ON public.table_orders(shop_id, table_id, settlement_id, served_at);

ALTER TABLE public.table_bill_settlements ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON public.table_bill_settlements FROM anon, authenticated;
GRANT SELECT ON public.table_bill_settlements TO authenticated;
DROP POLICY IF EXISTS "members read table bill settlements" ON public.table_bill_settlements;
CREATE POLICY "members read table bill settlements"
  ON public.table_bill_settlements
  FOR SELECT TO authenticated
  USING (public.is_shop_member(shop_id));

CREATE OR REPLACE FUNCTION public.settle_table_bill(
  _shop uuid,
  _table uuid,
  _operation_id uuid,
  _payment_method text
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = pg_catalog, public, pg_temp
AS $$
DECLARE
  settlement public.table_bill_settlements;
  bill_total bigint;
  method text := lower(trim(coalesce(_payment_method, '')));
BEGIN
  IF _shop IS NOT NULL AND _operation_id IS NOT NULL THEN
    PERFORM pg_advisory_xact_lock(
      hashtextextended(_shop::text || ':' || _operation_id::text, 0)
    );
  END IF;

  IF NOT public.has_shop_role(_shop, ARRAY['owner','manager','cashier']::public.shop_role[]) THEN
    RAISE EXCEPTION 'forbidden';
  END IF;
  IF _operation_id IS NULL THEN RAISE EXCEPTION 'invalid_operation_id'; END IF;
  IF method NOT IN ('cash', 'mpesa', 'card', 'other') THEN
    RAISE EXCEPTION 'invalid_payment_method';
  END IF;

  SELECT * INTO settlement
  FROM public.table_bill_settlements
  WHERE shop_id = _shop AND client_operation_id = _operation_id
  FOR UPDATE;
  IF FOUND THEN
    IF settlement.table_id <> _table OR settlement.payment_method <> method THEN
      RAISE EXCEPTION 'operation_id_reused';
    END IF;
    RETURN jsonb_build_object(
      'settlement_id', settlement.id,
      'table_id', settlement.table_id,
      'amount', settlement.amount,
      'payment_method', settlement.payment_method,
      'settled_at', settlement.settled_at
    );
  END IF;

  PERFORM 1 FROM public.dining_tables
  WHERE id = _table AND shop_id = _shop
  FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'table_not_found'; END IF;

  SELECT coalesce(sum(total), 0) INTO bill_total
  FROM public.table_orders
  WHERE shop_id = _shop AND table_id = _table AND settlement_id IS NULL;
  IF bill_total <= 0 THEN RAISE EXCEPTION 'no_open_table_bill'; END IF;

  INSERT INTO public.table_bill_settlements(
    shop_id, table_id, client_operation_id, amount, payment_method, settled_by
  ) VALUES (_shop, _table, _operation_id, bill_total, method, auth.uid())
  RETURNING * INTO settlement;

  UPDATE public.table_orders
  SET settlement_id = settlement.id
  WHERE shop_id = _shop AND table_id = _table AND settlement_id IS NULL;

  PERFORM public.write_audit_event(
    _shop, 'table_bill_settled', 'dining_table', _table,
    jsonb_build_object('settlement_id', settlement.id, 'amount', bill_total,
      'payment_method', method, 'operation_id', _operation_id)
  );

  RETURN jsonb_build_object(
    'settlement_id', settlement.id,
    'table_id', settlement.table_id,
    'amount', settlement.amount,
    'payment_method', settlement.payment_method,
    'settled_at', settlement.settled_at
  );
END $$;

REVOKE ALL ON FUNCTION public.settle_table_bill(uuid, uuid, uuid, text)
  FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.settle_table_bill(uuid, uuid, uuid, text)
  TO authenticated;
NOTIFY pgrst, 'reload schema';
