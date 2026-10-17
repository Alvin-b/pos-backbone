-- Verified Kenya product overrides sourced from Open Food Facts product records.
-- These are the only records in this migration whose barcode and image were both
-- directly observed in a Kenya-tagged product-level source.
UPDATE public.catalog_items
SET barcode = '6161101604031',
    image_url = 'https://images.openfoodfacts.org/images/products/616/110/160/4031/front_fr.3.400.jpg'
WHERE code = '6001000000110';

UPDATE public.catalog_items
SET barcode = '6164000012013',
    image_url = 'https://images.openfoodfacts.org/images/products/616/400/001/2013/front_fr.3.400.jpg'
WHERE code = 'LIB-AFIAAFIAFRUITDRINKAPPLE500ML500ML';

INSERT INTO public.catalog_items
  (code, barcode, name, brand, size, category, product_type, body_color, label_color, label_text_color, suggested_price, image_url)
SELECT
  'OFF-6164001199195', '6164001199195', 'Safari Energy Drink', 'Safari', '', 'Energy drinks',
  'beer'::public.product_type, '#174b36', '#e4d16b', '#ffffff', 0,
  'https://images.openfoodfacts.org/images/products/616/400/119/9195/front_fr.3.400.jpg'
WHERE NOT EXISTS (
  SELECT 1 FROM public.catalog_items WHERE code = 'OFF-6164001199195'
);
