-- The Android-era table_orders schema used total_ksh, while the current backend
-- uses total. Expose total as a generated alias where only total_ksh exists so the
-- server-confirmed settlement RPC can safely sum the bill on either schema.
DO $$
DECLARE
  has_total boolean;
  has_total_ksh boolean;
BEGIN
  IF to_regclass('public.table_orders') IS NULL THEN
    RAISE EXCEPTION 'public.table_orders is required before applying total compatibility';
  END IF;

  SELECT EXISTS (
    SELECT 1 FROM information_schema.columns
    WHERE table_schema = 'public' AND table_name = 'table_orders' AND column_name = 'total'
  ) INTO has_total;
  SELECT EXISTS (
    SELECT 1 FROM information_schema.columns
    WHERE table_schema = 'public' AND table_name = 'table_orders' AND column_name = 'total_ksh'
  ) INTO has_total_ksh;

  IF has_total_ksh AND NOT has_total THEN
    ALTER TABLE public.table_orders
      ADD COLUMN total bigint GENERATED ALWAYS AS (total_ksh) STORED;
  ELSIF NOT has_total THEN
    RAISE EXCEPTION 'table_orders must expose total or total_ksh';
  END IF;
END;
$$;

NOTIFY pgrst, 'reload schema';
