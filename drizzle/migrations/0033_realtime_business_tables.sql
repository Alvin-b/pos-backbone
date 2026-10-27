-- Publish tenant-owned POS tables so connected clients can invalidate their local snapshot.
-- Writes remain authenticated RPC transactions; Realtime is notification only.
DO $$
DECLARE
  table_name text;
BEGIN
  FOREACH table_name IN ARRAY ARRAY[
    'products',
    'sales',
    'stock_batches',
    'stock_receipts',
    'dining_tables',
    'table_orders',
    'service_counters',
    'counter_stock_balances',
    'counter_stock_movements',
    'table_bill_settlements'
  ] LOOP
    IF to_regclass('public.' || table_name) IS NOT NULL
       AND NOT EXISTS (
         SELECT 1
         FROM pg_publication_rel pr
         JOIN pg_publication p ON p.oid = pr.prpubid
         JOIN pg_class c ON c.oid = pr.prrelid
         JOIN pg_namespace n ON n.oid = c.relnamespace
         WHERE p.pubname = 'supabase_realtime'
           AND n.nspname = 'public'
           AND c.relname = table_name
       ) THEN
      EXECUTE format('ALTER PUBLICATION supabase_realtime ADD TABLE public.%I', table_name);
    END IF;
  END LOOP;
END $$;
