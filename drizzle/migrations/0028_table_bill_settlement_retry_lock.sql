-- Serialize duplicate settlement operation IDs before the existing bill settlement
-- implementation checks its ledger. This lets concurrent retries return the first
-- successful result instead of racing and reporting an empty open bill.
ALTER FUNCTION public.settle_table_bill(uuid, uuid, uuid, text)
  RENAME TO settle_table_bill_unlocked;

REVOKE ALL ON FUNCTION public.settle_table_bill_unlocked(uuid, uuid, uuid, text)
  FROM PUBLIC, anon, authenticated;

CREATE OR REPLACE FUNCTION public.settle_table_bill(
  _shop uuid,
  _table uuid,
  _operation_id uuid,
  _payment_method text
)
RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = pg_catalog, public, pg_temp
AS $$
BEGIN
  IF _shop IS NOT NULL AND _operation_id IS NOT NULL THEN
    PERFORM pg_advisory_xact_lock(
      hashtextextended(_shop::text || ':' || _operation_id::text, 0)
    );
  END IF;

  RETURN public.settle_table_bill_unlocked(
    _shop, _table, _operation_id, _payment_method
  );
END $$;

REVOKE ALL ON FUNCTION public.settle_table_bill(uuid, uuid, uuid, text)
  FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION public.settle_table_bill(uuid, uuid, uuid, text)
  TO authenticated;
NOTIFY pgrst, 'reload schema';
