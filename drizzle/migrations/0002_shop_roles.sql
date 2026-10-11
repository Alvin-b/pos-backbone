-- Commit new workspace roles before later migrations reference the enum values.
ALTER TYPE public.shop_role ADD VALUE IF NOT EXISTS 'manager';
ALTER TYPE public.shop_role ADD VALUE IF NOT EXISTS 'inventory_clerk';
