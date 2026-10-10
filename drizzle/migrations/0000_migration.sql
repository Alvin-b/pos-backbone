CREATE TYPE public.shop_role AS ENUM ('owner','cashier');
CREATE TYPE public.product_type AS ENUM ('beer','spirit');

CREATE TABLE public.shops (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  name text NOT NULL CHECK (length(name) BETWEEN 1 AND 120),
  currency text NOT NULL DEFAULT 'KES',
  low_stock_threshold int NOT NULL DEFAULT 5,
  created_by uuid NOT NULL,
  created_at timestamptz NOT NULL DEFAULT now()
);
CREATE TABLE public.shop_members (
  shop_id uuid NOT NULL REFERENCES public.shops(id) ON DELETE CASCADE,
  user_id uuid NOT NULL,
  role public.shop_role NOT NULL DEFAULT 'cashier',
  created_at timestamptz NOT NULL DEFAULT now(),
  PRIMARY KEY (shop_id, user_id)
);
CREATE TABLE public.catalog_items (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  code text NOT NULL UNIQUE,
  barcode text,
  name text NOT NULL,
  brand text,
  size text,
  category text,
  product_type public.product_type NOT NULL DEFAULT 'beer',
  body_color text, label_color text, label_text_color text,
  suggested_price int NOT NULL DEFAULT 0,
  image_url text,
  created_at timestamptz NOT NULL DEFAULT now()
);
CREATE TABLE public.products (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  shop_id uuid NOT NULL REFERENCES public.shops(id) ON DELETE CASCADE,
  catalog_item_id uuid REFERENCES public.catalog_items(id) ON DELETE SET NULL,
  code text NOT NULL,
  barcode text,
  name text NOT NULL,
  brand text,
  size text,
  category text,
  product_type public.product_type NOT NULL DEFAULT 'beer',
  body_color text, label_color text, label_text_color text,
  price int NOT NULL CHECK (price >= 0),
  stock int NOT NULL DEFAULT 0 CHECK (stock >= 0),
  photo_url text,
  photo_path text,
  archived boolean NOT NULL DEFAULT false,
  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now(),
  UNIQUE (shop_id, code)
);
CREATE INDEX products_shop_barcode_idx ON public.products(shop_id, barcode);
CREATE TABLE public.sales (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  shop_id uuid NOT NULL REFERENCES public.shops(id) ON DELETE CASCADE,
  product_id uuid NOT NULL REFERENCES public.products(id) ON DELETE CASCADE,
  product_name text NOT NULL,
  qty int NOT NULL CHECK (qty > 0),
  unit_price int NOT NULL,
  total int NOT NULL,
  sold_by uuid NOT NULL,
  created_at timestamptz NOT NULL DEFAULT now(),
  undone_at timestamptz,
  undone_by uuid
);
CREATE INDEX sales_shop_time_idx ON public.sales(shop_id, created_at DESC);
CREATE TABLE public.stock_receipts (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  shop_id uuid NOT NULL REFERENCES public.shops(id) ON DELETE CASCADE,
  product_id uuid NOT NULL REFERENCES public.products(id) ON DELETE CASCADE,
  qty int NOT NULL CHECK (qty > 0),
  is_new_product boolean NOT NULL DEFAULT false,
  received_by uuid NOT NULL,
  created_at timestamptz NOT NULL DEFAULT now()
);

GRANT SELECT ON public.shops, public.shop_members, public.catalog_items, public.products, public.sales, public.stock_receipts TO authenticated;
GRANT UPDATE (name, low_stock_threshold) ON public.shops TO authenticated;
GRANT UPDATE (name, brand, size, category, price, photo_url, photo_path, archived, barcode) ON public.products TO authenticated;
GRANT DELETE ON public.shop_members TO authenticated;
GRANT ALL ON public.shops, public.shop_members, public.catalog_items, public.products, public.sales, public.stock_receipts TO service_role;

ALTER TABLE public.shops ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.shop_members ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.catalog_items ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.products ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.sales ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.stock_receipts ENABLE ROW LEVEL SECURITY;

CREATE OR REPLACE FUNCTION public.is_shop_member(_shop uuid) RETURNS boolean
LANGUAGE sql STABLE SECURITY DEFINER SET search_path = public AS $$
  SELECT EXISTS (SELECT 1 FROM public.shop_members WHERE shop_id=_shop AND user_id=auth.uid())
$$;
CREATE OR REPLACE FUNCTION public.is_shop_owner(_shop uuid) RETURNS boolean
LANGUAGE sql STABLE SECURITY DEFINER SET search_path = public AS $$
  SELECT EXISTS (SELECT 1 FROM public.shop_members WHERE shop_id=_shop AND user_id=auth.uid() AND role='owner')
$$;

CREATE POLICY "members read shop" ON public.shops FOR SELECT TO authenticated USING (public.is_shop_member(id));
CREATE POLICY "owners update shop" ON public.shops FOR UPDATE TO authenticated USING (public.is_shop_owner(id)) WITH CHECK (public.is_shop_owner(id));
CREATE POLICY "members read members" ON public.shop_members FOR SELECT TO authenticated USING (public.is_shop_member(shop_id));
CREATE POLICY "owners remove cashiers" ON public.shop_members FOR DELETE TO authenticated USING (public.is_shop_owner(shop_id) AND role='cashier');
CREATE POLICY "catalog readable" ON public.catalog_items FOR SELECT TO authenticated USING (true);
CREATE POLICY "members read products" ON public.products FOR SELECT TO authenticated USING (public.is_shop_member(shop_id));
CREATE POLICY "owners edit products" ON public.products FOR UPDATE TO authenticated USING (public.is_shop_owner(shop_id)) WITH CHECK (public.is_shop_owner(shop_id));
CREATE POLICY "members read sales" ON public.sales FOR SELECT TO authenticated USING (public.is_shop_member(shop_id));
CREATE POLICY "members read receipts" ON public.stock_receipts FOR SELECT TO authenticated USING (public.is_shop_member(shop_id));

CREATE OR REPLACE FUNCTION public.create_shop(_name text) RETURNS public.shops
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE s public.shops;
BEGIN
  IF auth.uid() IS NULL THEN RAISE EXCEPTION 'not_authenticated'; END IF;
  INSERT INTO public.shops(name, created_by) VALUES (trim(_name), auth.uid()) RETURNING * INTO s;
  INSERT INTO public.shop_members(shop_id,user_id,role) VALUES (s.id, auth.uid(), 'owner');
  RETURN s;
END $$;

CREATE OR REPLACE FUNCTION public.add_member_by_email(_shop uuid, _email text, _role public.shop_role DEFAULT 'cashier')
RETURNS void LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE uid uuid;
BEGIN
  IF NOT public.is_shop_owner(_shop) THEN RAISE EXCEPTION 'forbidden'; END IF;
  SELECT id INTO uid FROM auth.users WHERE lower(email)=lower(trim(_email));
  IF uid IS NULL THEN RAISE EXCEPTION 'user_not_found'; END IF;
  INSERT INTO public.shop_members(shop_id,user_id,role) VALUES (_shop,uid,_role)
  ON CONFLICT (shop_id,user_id) DO UPDATE SET role=EXCLUDED.role;
END $$;

CREATE OR REPLACE FUNCTION public.find_product(_shop uuid, _query text) RETURNS SETOF public.products
LANGUAGE sql STABLE SECURITY INVOKER SET search_path = public AS $$
  SELECT * FROM public.products
  WHERE shop_id=_shop AND NOT archived AND (code=trim(_query) OR barcode=trim(_query)
     OR (name || ' ' || coalesce(brand,'') || ' ' || coalesce(size,'')) ILIKE '%'||trim(_query)||'%')
  ORDER BY (code=trim(_query) OR barcode=trim(_query)) DESC, name LIMIT 50
$$;

CREATE OR REPLACE FUNCTION public.record_sale(_product uuid, _qty int DEFAULT 1) RETURNS public.sales
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE p public.products; s public.sales;
BEGIN
  IF _qty IS NULL OR _qty < 1 THEN RAISE EXCEPTION 'invalid_quantity'; END IF;
  SELECT * INTO p FROM public.products WHERE id=_product FOR UPDATE;
  IF p.id IS NULL OR NOT public.is_shop_member(p.shop_id) THEN RAISE EXCEPTION 'product_not_found'; END IF;
  IF p.stock < _qty THEN RAISE EXCEPTION 'out_of_stock'; END IF;
  UPDATE public.products SET stock=stock-_qty, updated_at=now() WHERE id=p.id;
  INSERT INTO public.sales(shop_id,product_id,product_name,qty,unit_price,total,sold_by)
  VALUES (p.shop_id,p.id,p.name,_qty,p.price,_qty*p.price,auth.uid()) RETURNING * INTO s;
  RETURN s;
END $$;

CREATE OR REPLACE FUNCTION public.undo_sale(_shop uuid, _sale uuid DEFAULT NULL) RETURNS public.sales
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE s public.sales;
BEGIN
  IF NOT public.is_shop_member(_shop) THEN RAISE EXCEPTION 'forbidden'; END IF;
  IF _sale IS NULL THEN
    SELECT * INTO s FROM public.sales WHERE shop_id=_shop AND undone_at IS NULL ORDER BY created_at DESC LIMIT 1 FOR UPDATE;
  ELSE
    SELECT * INTO s FROM public.sales WHERE id=_sale AND shop_id=_shop AND undone_at IS NULL FOR UPDATE;
  END IF;
  IF s.id IS NULL THEN RAISE EXCEPTION 'nothing_to_undo'; END IF;
  UPDATE public.sales SET undone_at=now(), undone_by=auth.uid() WHERE id=s.id RETURNING * INTO s;
  UPDATE public.products SET stock=stock+s.qty, updated_at=now() WHERE id=s.product_id;
  RETURN s;
END $$;

CREATE OR REPLACE FUNCTION public.receive_stock(_product uuid, _qty int) RETURNS public.products
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE p public.products;
BEGIN
  IF _qty IS NULL OR _qty < 1 THEN RAISE EXCEPTION 'invalid_quantity'; END IF;
  SELECT * INTO p FROM public.products WHERE id=_product FOR UPDATE;
  IF p.id IS NULL OR NOT public.is_shop_member(p.shop_id) THEN RAISE EXCEPTION 'product_not_found'; END IF;
  UPDATE public.products SET stock=stock+_qty, archived=false, updated_at=now() WHERE id=p.id RETURNING * INTO p;
  INSERT INTO public.stock_receipts(shop_id,product_id,qty,received_by) VALUES (p.shop_id,p.id,_qty,auth.uid());
  RETURN p;
END $$;

CREATE OR REPLACE FUNCTION public.add_from_catalog(_shop uuid, _catalog uuid, _qty int DEFAULT 0, _price int DEFAULT NULL)
RETURNS public.products LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE c public.catalog_items; p public.products;
BEGIN
  IF NOT public.is_shop_member(_shop) THEN RAISE EXCEPTION 'forbidden'; END IF;
  IF coalesce(_qty,0) < 0 OR coalesce(_price,0) < 0 THEN RAISE EXCEPTION 'invalid_input'; END IF;
  SELECT * INTO c FROM public.catalog_items WHERE id=_catalog;
  IF c.id IS NULL THEN RAISE EXCEPTION 'catalog_item_not_found'; END IF;
  INSERT INTO public.products(shop_id,catalog_item_id,code,barcode,name,brand,size,category,product_type,body_color,label_color,label_text_color,price,stock,photo_url)
  VALUES (_shop,c.id,c.code,c.barcode,c.name,c.brand,c.size,c.category,c.product_type,c.body_color,c.label_color,c.label_text_color,coalesce(_price,c.suggested_price),coalesce(_qty,0),c.image_url)
  ON CONFLICT (shop_id,code) DO UPDATE SET stock=public.products.stock+coalesce(_qty,0),
     price=coalesce(_price,public.products.price), archived=false, updated_at=now()
  RETURNING * INTO p;
  IF coalesce(_qty,0) > 0 THEN
    INSERT INTO public.stock_receipts(shop_id,product_id,qty,received_by) VALUES (_shop,p.id,_qty,auth.uid());
  END IF;
  RETURN p;
END $$;

CREATE OR REPLACE FUNCTION public.register_product(_shop uuid, _code text, _name text, _price int, _qty int,
  _photo_path text, _size text DEFAULT NULL, _type public.product_type DEFAULT 'beer', _brand text DEFAULT NULL, _category text DEFAULT NULL)
RETURNS public.products LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE p public.products;
BEGIN
  IF NOT public.is_shop_member(_shop) THEN RAISE EXCEPTION 'forbidden'; END IF;
  IF coalesce(trim(_code),'')='' THEN RAISE EXCEPTION 'code_required'; END IF;
  IF coalesce(trim(_name),'')='' THEN RAISE EXCEPTION 'name_required'; END IF;
  IF _price IS NULL OR _price < 1 THEN RAISE EXCEPTION 'price_required'; END IF;
  IF _qty IS NULL OR _qty < 1 THEN RAISE EXCEPTION 'invalid_quantity'; END IF;
  IF coalesce(trim(_photo_path),'')='' THEN RAISE EXCEPTION 'photo_required'; END IF;
  IF EXISTS (SELECT 1 FROM public.products WHERE shop_id=_shop AND code=trim(_code)) THEN RAISE EXCEPTION 'code_exists'; END IF;
  INSERT INTO public.products(shop_id,code,barcode,name,brand,size,category,product_type,body_color,label_color,label_text_color,price,stock,photo_path)
  VALUES (_shop,trim(_code),trim(_code),trim(_name),coalesce(_brand,trim(_name)),coalesce(nullif(trim(_size),''),'-'),coalesce(_category,'Custom beverage'),_type,
    CASE WHEN _type='beer' THEN '#5a3a1c' ELSE '#2a2a2a' END,'#e8e4d4','#14181f',_price,_qty,_photo_path)
  RETURNING * INTO p;
  INSERT INTO public.stock_receipts(shop_id,product_id,qty,is_new_product,received_by) VALUES (_shop,p.id,_qty,true,auth.uid());
  RETURN p;
END $$;

CREATE OR REPLACE FUNCTION public.daily_summary(_shop uuid, _day date DEFAULT ((now() AT TIME ZONE 'Africa/Nairobi')::date))
RETURNS json LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = public AS $$
DECLARE r json;
BEGIN
  IF NOT public.is_shop_member(_shop) THEN RAISE EXCEPTION 'forbidden'; END IF;
  SELECT json_build_object(
    'day', _day,
    'total', coalesce(sum(total) FILTER (WHERE undone_at IS NULL),0),
    'items_sold', coalesce(sum(qty) FILTER (WHERE undone_at IS NULL),0),
    'sale_count', count(*) FILTER (WHERE undone_at IS NULL),
    'undone_count', count(*) FILTER (WHERE undone_at IS NOT NULL))
  INTO r FROM public.sales
  WHERE shop_id=_shop AND (created_at AT TIME ZONE 'Africa/Nairobi')::date=_day;
  RETURN r;
END $$;

REVOKE EXECUTE ON FUNCTION public.create_shop(text), public.add_member_by_email(uuid,text,public.shop_role), public.find_product(uuid,text),
  public.record_sale(uuid,int), public.undo_sale(uuid,uuid), public.receive_stock(uuid,int), public.add_from_catalog(uuid,uuid,int,int),
  public.register_product(uuid,text,text,int,int,text,text,public.product_type,text,text), public.daily_summary(uuid,date) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.create_shop(text), public.add_member_by_email(uuid,text,public.shop_role), public.find_product(uuid,text),
  public.record_sale(uuid,int), public.undo_sale(uuid,uuid), public.receive_stock(uuid,int), public.add_from_catalog(uuid,uuid,int,int),
  public.register_product(uuid,text,text,int,int,text,text,public.product_type,text,text), public.daily_summary(uuid,date) TO authenticated;

ALTER PUBLICATION supabase_realtime ADD TABLE public.products, public.sales;

CREATE POLICY "members read photos" ON storage.objects FOR SELECT TO authenticated
  USING (bucket_id='product-photos' AND public.is_shop_member(((storage.foldername(name))[1])::uuid));
CREATE POLICY "members upload photos" ON storage.objects FOR INSERT TO authenticated
  WITH CHECK (bucket_id='product-photos' AND public.is_shop_member(((storage.foldername(name))[1])::uuid));
CREATE POLICY "members update photos" ON storage.objects FOR UPDATE TO authenticated
  USING (bucket_id='product-photos' AND public.is_shop_member(((storage.foldername(name))[1])::uuid));

-- Seed: master catalog -----------------------------------------------
INSERT INTO public.catalog_items(code,barcode,name,brand,size,category,product_type,body_color,label_color,label_text_color,suggested_price) VALUES
('6001000000011','6001000000011','Tusker Lager','Tusker','500ml','Beer, cider & RTD','beer','#2f5a2a','#c0392b','#d4a62a',250),
('6001000000028','6001000000028','Tusker Malt','Tusker','500ml','Beer, cider & RTD','beer','#5a3a1c','#d4a62a','#7a1f1f',280),
('6001000000035','6001000000035','White Cap Lager','White Cap','500ml','Beer, cider & RTD','beer','#5a3a1c','#ffffff','#1d4f9c',250),
('6001000000042','6001000000042','Pilsner Lager','Pilsner','500ml','Beer, cider & RTD','beer','#5a3a1c','#1f7a3e','#ffffff',230),
('6001000000059','6001000000059','Guinness','Guinness','500ml','Beer, cider & RTD','beer','#1b1410','#111','#d4a62a',300),
('6001000000066','6001000000066','Balozi Lager','Balozi','500ml','Beer, cider & RTD','beer','#5a3a1c','#f2c230','#14181f',220),
('6001000000073','6001000000073','Johnnie Walker Black','Johnnie Walker','750ml','Spirits','spirit','#2a1a0a','#111','#d4a62a',3800),
('6001000000080','6001000000080','Jameson Irish Whiskey','Jameson','750ml','Spirits','spirit','#1f4a2a','#f5efe0','#1f4a2a',3200),
('6001000000097','6001000000097','Smirnoff Vodka','Smirnoff','750ml','Spirits','spirit','#d8e6ee','#c8102e','#ffffff',1800),
('6001000000103','6001000000103','Captain Morgan','Captain Morgan','750ml','Spirits','spirit','#5a2a12','#8b1e1e','#f2c230',1900),
('6001000000110','6001000000110','Chrome Vodka','Chrome','750ml','Spirits','spirit','#d8e6ee','#1d4f9c','#ffffff',1300),
('6001000000127','6001000000127','Kenya Cane','Kenya Cane','750ml','Spirits','spirit','#e8e4d4','#d4a62a','#14181f',1100),
('6001000000134','6001000000134','Gilbey''s Gin','Gilbey''s','750ml','Spirits','spirit','#cfe3d6','#0f5a3a','#ffffff',1500),
('6001000000141','6001000000141','Summit Lager','Summit','500ml','Beer, cider & RTD','beer','#324c2e','#efece2','#175a3f',230),
('6001000000158','6001000000158','Tusker Cider','Tusker','500ml','Beer, cider & RTD','beer','#b87e18','#f4d167','#163e2e',300),
('6001000000165','6001000000165','Tusker Lite','Tusker','500ml','Beer, cider & RTD','beer','#a7c2c8','#d4a62a','#1e4a63',280),
('6001000000172','6001000000172','Smirnoff Ice Pineapple Punch','Smirnoff','330ml','Beer, cider & RTD','beer','#9ac044','#f6ee8c','#bf2f24',250),
('6001000000189','6001000000189','Gordon''s London Dry Gin','Gordon''s','750ml','Spirits','spirit','#d7e7e0','#f4db54','#b72723',2100),
('6001000000196','6001000000196','Johnnie Walker Red Label','Johnnie Walker','700ml','Spirits','spirit','#e39a2b','#ad272c','#f7f0d9',2800);

INSERT INTO public.catalog_items(code,name,brand,size,category,product_type,body_color,label_color,label_text_color,suggested_price,image_url)
SELECT 'LIB-'||c, n, b, s, cat, CASE WHEN t='s' THEN 'spirit'::public.product_type ELSE 'beer'::public.product_type END,
  '#174b36','#e4d16b','#ffffff', p,
  CASE WHEN img LIKE '~%' THEN 'https://files.manuscdn.com/search-media/310519664012478682/5Ro9ASnpyZDY9S8E5eDSH6/'||substr(img,2) ELSE img END
FROM (VALUES
('HUNTERSHUNTERSDRYAPPLECIDERBOTTLE330ML330M','Hunter’s Dry Apple Cider Bottle 330ml','Hunter''s','330ml','Cider','b',225,'~FQebyfeLbM9UcVfKPgYoWd.webp'),
('KENYANORIGINALSKENYANORIGINALLEMONCELLOCOC','Kenyan Original Lemon Cello Cocktail 330Ml Can','Kenyan Originals','330ml','Alcoholic RTD','b',285,'~ShwBY26UPEcszNCfsRGFAo.webp'),
('KENYANORIGINALSKENYANORIGINALMUKHOMBEROCOC','Kenyan Original Mukhombero Cocktail 330Ml Can','Kenyan Originals','330ml','Alcoholic RTD','b',285,'~YMBW7QGEYPYvEEutU35ykT.webp'),
('MANYATTAMANYATTAPINEAPPLEMINTCIDERCAN330ML','Manyatta Pineapple & Mint Cider Can 330ml','Manyatta','330ml','Cider','b',280,'~uV8JPoFfKrptz88mL9zLoZ.webp'),
('SAVANNASAVANNADRYPREMIUMCIDERBOTTLE330ML33','Savanna Dry Premium Cider Bottle 330ml','Savanna','330ml','Cider','b',255,'~oJiG8ko5jjXaSvUmEtyGKQ.webp'),
('AZAMAZAMCARBONATEDENERGYDRINK300ML300ML','Azam Carbonated Energy Drink 300ml','Azam','300ml','Energy drinks','b',60,'~qzNrbLCqjjJLH6xkJ537f8.webp'),
('BRAVABRAVABRAVADOENERGYDRINK300ML300ML','Brava Bravado Energy Drink 300ml','Brava','300ml','Energy drinks','b',38,'~2MPZwDgD7BJe7mEpouii3Q.jpeg'),
('MONSTERMONSTERORIGINALENERGYDRINK500ML500M','Monster Original Energy Drink 500ml','Monster','500 ml','Energy drinks','b',234,'~6rMTHVU7fEdEJitx6QcTEN.jpeg'),
('POKKAPOKKALEMONISOTONICDRINK500ML500ML','Pokka Lemon Isotonic Drink 500Ml','Pokka','500ml','Isotonic sports drink','s',225,'https://d16zmt6hgq1jhj.cloudfront.net/product/6293/Pokka%20Lemon%20Isotonic%20Drink%20500Ml.webp'),
('POWERPLAYPOWERPLAYORIGINALENERGYDRINK400ML','Power Play Original Energy Drink 400ml','Power Play','400ml','Energy drinks','b',64,NULL),
('PREDATORPREDATORENERGYDRINK400ML400ML','Predator Energy Drink 400ml','Predator','400ml','Energy drinks','b',63,'~xA9Z3zDi7hT7ocxetNkk6N.webp'),
('REDBULLREDBULLENERGYDRINK250ML250ML','Red Bull Energy Drink, 250 Ml','Red Bull','250ml','Energy drinks','b',232,'~MRc5u3248WM24LLURBJhF4.jpg'),
('RELOADRELOADORANGEISOTONICDRINK500ML500ML','Reload Orange Isotonic Drink 500ml','Reload','500ml','Isotonic sports drink','s',154,'~QdGMkfgMB9JCPUrEtAG2rR.webp'),
('AFIAAFIAFRUITDRINKAPPLE500ML500ML','Afia Fruit Drink Apple 500ml','Afia','500ml','Juice','b',80,'~VoepB9D5k4kej9DDXeFnDf.webp'),
('AFIAAFIAFRUITDRINKMIXEDFRUIT500ML500ML','Afia Fruit Drink Mixed Fruit 500ml','Afia','500ml','Juice','b',80,'https://www.jejetu.com/wp-content/uploads/2024/06/Afia-mixed-fruit-500ml-UGX-4000.jpg'),
('DELMONTEDELMONTEJUICEBLENDMIXEDBERRY1L1L','Del Monte Juice Blend Mixed Berry 1L','Del Monte','1L','Juice','b',310,'~PSWpYHtt4gMUVDaxSnj5fi.jpg'),
('PICKNPEELPICKNPEELAPPLE1L1L','Pick ''N'' Peel Apple 1L','Pick ''N'' Peel','1L','Juice','b',340,'~JYiHjmSbfp2iBJjJ2icwXF.webp'),
('PICKNPEELPICKNPEELORANGE1L1L','Pick ''N'' Peel Orange 1L','Pick ''N'' Peel','1L','Juice','b',390,'~MsDqdCm4m7p7PBdfUxRx6F.webp'),
('PICKNPEELPICKNPEELPINEAPPLE1L1L','Pick ''N'' Peel Pineapple 1L','Pick ''N'' Peel','1L','Juice','b',340,'~BGQn7mwmfPS9mh9CizrLKW.webp'),
('PICKNPEELPICKNPEELTROPICALMIX1L1L','Pick ''N'' Peel Tropical Mix 1L','Pick ''N'' Peel','1L','Juice','b',340,'~mWDPQHtzp43VDNzt8cgyWg.webp'),
('SUNTOPSUNTOPORANGEFRUITJUICE250ML250ML','Suntop Orange Fruit Juice 250Ml','Suntop','250ml','Juice','b',60,'~RkYhJvQTxZVgYqRKBVTP5k.png'),
('FITCHLEEDESFITCHLEEDESINDIANTONICSPARKLING','Fitch Leedes Indian Tonic Sparkling Drink 200ml','Fitch & Leedes','200 ml can','Tonic water','s',148,NULL),
('SCHWEPPESINDIANTONICWATER200ML','Indian Tonic Water','Schweppes','200 ml','Tonic water','s',50,'https://storage.googleapis.com/dialadrink-production-images/products/indian-tonic-water.jpg'),
('KENYANORIGINALSKENYANORIGINALSCLASSICTONIC','Kenyan Originals Classic Tonic Can 200ml','Kenyan Originals','200 ml can','Tonic water','s',130,'~bRJoe7BoqBPj2Px62NoX33.jpg'),
('KENYANORIGINALSKENYANORIGINALSLIGHTTONICCA','Kenyan Originals Light Tonic Can 200ml','Kenyan Originals','200 ml can','Tonic water','s',130,'~uHapC6J23hE9RtCFLSs3tX.jpg'),
('KENYANORIGINALSKENYANORIGINALSROSECUCUMBER','Kenyan Originals Rose & Cucumber Tonic Can 200ml','Kenyan Originals','200 ml can','Tonic water','s',130,'~gDiM8QTT5EhCF7rU5YvkfQ.jpg'),
('KENYANORIGINALSKENYANORIGINALSTURMERICCHIL','Kenyan Originals Turmeric & Chilli Tonic Can 200ml','Kenyan Originals','200 ml can','Tonic water','s',130,'~eHSQaHki6mQ8nmyT3vkw2g.webp'),
('SCHWEPPESSCHWEPPESGINGERALE300ML','Schweppes Ginger Ale','Schweppes','300 ml','Ginger ale','s',99,'https://storage.googleapis.com/dialadrink-production-images/products/scheppes-ginger-ale.jpg'),
('SCHWEPPESSCHWEPPESSODAWATER500ML','Schweppes Soda Water','Schweppes','500 ml','Soda water','s',100,'https://storage.googleapis.com/dialadrink-production-images/products/soda-water.jpg'),
('SCHWEPPESSCHWEPPESTONICWATER330ML330MLCAN','Schweppes Tonic Water 330Ml','Schweppes','330 ml can','Tonic water','s',130,'~r5FAaQRPwzDYFLfNXnnFRf.jpg'),
('COCACOLACOCACOLADRINK500ML500ML','Coca Cola Drink 500Ml','Coca-Cola','500ml','Soft drinks','b',70,'~4effStUhFho4iZTeTaL8Ne.jpg'),
('FANTAFANTAORANGESODA500ML500ML','Fanta Orange Soda 500Ml','Fanta','500ml','Soft drinks','b',70,'~xTcpRmWqjheaS3RLyDdfBT.webp'),
('KRESTKRESTBITTERLEMONSOFTDRINK350ML350ML','Krest Bitter Lemon Soft Drink 350Ml','Krest','350ml','Soft drinks','b',50,'~bFUyN5Wyrn2ygkAA9m6zSg.webp'),
('MIRINDAMIRINDAFRUITYSOFTDRINK2L2L','Mirinda Fruity Soft Drink 2L','Mirinda','2L','Soft drinks','b',129,'~gXr5KmJeTZqE5KSJzG8hD4.webp'),
('MOUNTAINDEWMOUNTAINDEWSOFTDRINK330ML330ML','Mountain Dew Soft Drink 330ml','Mountain Dew','330ml','Soft drinks','b',50,'~7RHtCoJJcdQTTnQfgXPg4U.webp'),
('SAFARISAFARILEMONADELIMECARBONATEDSOFTDRIN','Safari Lemonade Lime Carbonated Soft Drink 300ml','Safari','300ml','Soft drinks','b',55,'~ovv8oaKUxvvB7dupYVf96d.webp'),
('SPRITESPRITESODACARBONATEDSOFTDRINK350ML35','Sprite Soda Carbonated Soft Drink 350Ml','Sprite','350ml','Soft drinks','b',50,'~BDhBp2rDCpZLAxJQ6UtYKF.jpg'),
('STONEYSTONEYTANGAWIZICARBONATEDSOFTDRINK35','Stoney Tangawizi Carbonated Soft Drink 350ml','Stoney','350ml','Soft drinks','b',49,'~yx9ydEdfhFR2nW8cKHsJkk.webp'),
('AMARULAAMARULACREAMLIQUEUR750MLLIQUEUR750M','Amarula Cream Liqueur 750Ml Liqueur','Amarula','750ml','Liqueur','s',2468,'https://soys.co.ke/PImages/SPUXU-0.jpg'),
('BAHARIBAHARIBLUERUM750ML750ML','Bahari Blue Rum 750ml','Bahari','750ml','Rum','s',3200,'https://www.havenwines.co.ke/wp-content/uploads/2022/12/download-26.jpg'),
('JOHNNIEWALKERJOHNNIEWALKERREDLABEL750MLSCO','Johnnie Walker Red Label 750Ml Scotch Whiskey','Johnnie Walker','750ml','Scotch whisky','s',2250,'https://soys.co.ke/PImages/JRLOI-1.jpg'),
('AQUAMISTAQUAMISTMINERALWATER500ML500ML','Aquamist Mineral Water 500ml','Aquamist','500ml','Water','b',60,'~CFkFXA6cCSDBZmuaX4h2vD.png'),
('DASANIDASANIMINERALWATER500ML500ML','Dasani Mineral Water 500Ml','Dasani','500ml','Water','b',35,'~ZLcp6xQaEbttH2wMt837rE.webp'),
('HIGHLANDSHIGHLANDSMINERALWATER500ML500ML','Highlands Mineral Water 500Ml','Highlands','500ml','Water','b',25,'~pqzVM5GFBLfGRXLkkSWcAk.webp'),
('KERINGETKERINGETMINERALWATER500ML500ML','Keringet Mineral Water 500ml','Keringet','500ml','Water','b',70,'https://www.montyskenya.com/wp-content/uploads/2020/05/Keringet-Still-Water.jpg.webp'),
('KERINGETKERINGETSPARKLINGMINERALWATER1L1L','Keringet Sparkling Mineral Water 1l','Keringet','1L','Water','b',98,'~5wZUgDPV8rs8HjUEwPT5D3.webp'),
('MAYERSMAYERSSPARKLINGWATER500ML500ML','Mayers Sparkling Water 500ml','Mayers','500ml','Water','b',85,'https://www.montyskenya.com/wp-content/uploads/2020/05/Mayers-Sparkling-Water.jpg.webp'),
('PERRIERPERRIERSPARKLINGWATER330ML330ML','Perrier Sparkling Water 330ml','Perrier','330ml','Water','b',280,'https://www.montyskenya.com/wp-content/uploads/2020/05/Perrier-Sparkling-Water.jpg.webp'),
('QUENCHERQUENCHERLIFEPREMIUMDRINKINGWATER50','Quencher Life Premium Drinking Water 500ml X 6','Quencher','500ml x 6','Water','b',161,'~Xz3sGsCS9ymED8Psgz2qML.webp'),
('4THSTREET4THSTREETSWEETREDWINE750ML750ML','4th Street Sweet Red Wine 750ml','4th Street','750ml','Wine','s',1300,'https://mybooze.co.ke/storage/images/products/tenant-id-2/67d0c30876ac9-1741734664-oFd32.jpg'),
('4THSTREET4THSTREETSWEETROSEWINE750ML750ML','4th Street Sweet Rose Wine 750ml','4th Street','750ml','Wine','s',1100,'https://mybooze.co.ke/storage/images/products/tenant-id-2/67d0c3088f04c-1741734664-6yIXm.jpg'),
('BARONDEVALLSBARONDEVALLSREDWINE750ML750ML','Barón de Valls Red Wine 750ml','Barón de Valls','750ml','Wine','s',1050,'~SUZ7G5NfMQocaehDrwrUDC.jpg'),
('COCKBURNSCOCKBURNS2011LATEBOTTLEDVINTAGEPO','Cockburn''s 2011 Late Bottled Vintage Port','Cockburn''s','750ml','Fortified wine','s',6450,'https://ik.imagekit.io/drinksvine/products/cockburns-late-bottle-vintage.webp'),
('COCKBURNSCOCKBURNSFINETAWNY750ML','Cockburn''s Fine Tawny','Cockburn''s','750ml','Fortified wine','s',3500,'https://ik.imagekit.io/drinksvine/products/cockburns-fine-tawny.webp'),
('LELESHWALELESHWASWEETWHITEWINE750ML750ML','Leleshwa Sweet White Wine 750ml','Leleshwa','750ml','Wine','s',1300,'https://sizzleliquors.co.ke/wp-content/uploads/2024/01/Leleshwa-Sweet-White-Wine-750ml.jpg'),
('LELESHWAMZABIBUBYLELESHWADRYWHITEWINE5L5L','Mzabibu By Leleshwa Dry White Wine 5L','Leleshwa','5L','Wine','s',4500,'https://shop.kenyanut.com/uploads/products/695265e155112_1767007713.png'),
('PIERLANTPIERLANTBRUTSPARKLINGWINE750ML750M','Pierlant Brut Sparkling Wine 750ml','Pierlant','750ml','Sparkling wine','s',1850,'~pEjGj3RsHYCjE3ssEkNxoi.png'),
('YELLOWTAILYELLOWTAILSPARKLINGCUVEE75CL','Yellow Tail Sparkling Cuvee','Yellow Tail','75cl','Sparkling wine','s',1590,'https://thewinebox.biz/wp-content/uploads/2023/04/Yellow-Tail-Bubbles-Sparkling-White.avif'),
('YELLOWTAILYELLOWTAILSPARKLINGCUVEEROSE75CL','Yellow Tail Sparkling Cuvee Rose','Yellow Tail','75cl','Sparkling wine','s',1590,'https://thewinebox.biz/wp-content/uploads/2023/04/Yellow-Tail-Bubbles-Sparkling-Rose.avif')
) AS v(c,n,b,s,cat,t,p,img);