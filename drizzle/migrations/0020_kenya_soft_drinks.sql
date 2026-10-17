-- Kenya retailer-listed soft drinks and juices: Minute Maid, Del Monte, and soda variants.
-- Barcodes are unique internal POS scan keys because the public retailer pages expose
-- retailer listings/SKUs rather than package-level GTINs. Sources are recorded in
-- docs/kenya-beverage-catalog-research.md and the product source URLs in the app catalog.
INSERT INTO public.catalog_items(code,barcode,name,brand,size,category,product_type,body_color,label_color,label_text_color,suggested_price,image_url) VALUES
('KE-DRINK-0001','2030000000012','Minute Maid Tropical Juice 1L','Minute Maid','1L','Juice','beer','#174b36','#e4d16b','#ffffff',0,'/catalog/generated/KE-DRINK-0001.svg'),
('KE-DRINK-0002','2030000000029','Minute Maid Mango Juice 1L','Minute Maid','1L','Juice','beer','#174b36','#e4d16b','#ffffff',0,'/catalog/generated/KE-DRINK-0002.svg'),
('KE-DRINK-0003','2030000000036','Minute Maid Delight Tropical Juice 1L','Minute Maid','1L','Juice','beer','#174b36','#e4d16b','#ffffff',0,'/catalog/generated/KE-DRINK-0003.svg'),
('KE-DRINK-0004','2030000000043','Del Monte 100 Percent Pure Apple Juice 1L','Del Monte','1L','Juice','beer','#174b36','#e4d16b','#ffffff',0,'/catalog/generated/KE-DRINK-0004.svg'),
('KE-DRINK-0005','2030000000050','Del Monte Juice Blend Pineapple & Mango 1L','Del Monte','1L','Juice','beer','#174b36','#e4d16b','#ffffff',0,'/catalog/generated/KE-DRINK-0005.svg'),
('KE-DRINK-0006','2030000000067','Del Monte Pineapple Orange Juice 250ml','Del Monte','250ml','Juice','beer','#174b36','#e4d16b','#ffffff',0,'/catalog/generated/KE-DRINK-0006.svg'),
('KE-DRINK-0007','2030000000074','Del Monte Lemonade Drink 250ml','Del Monte','250ml','Soft drinks','beer','#174b36','#e4d16b','#ffffff',0,'/catalog/generated/KE-DRINK-0007.svg'),
('KE-DRINK-0008','2030000000081','Del Monte Energy Drink 250ml','Del Monte','250ml','Energy drinks','beer','#174b36','#e4d16b','#ffffff',0,'/catalog/generated/KE-DRINK-0008.svg'),
('KE-DRINK-0009','2030000000098','Del Monte Mango Juice 250ml','Del Monte','250ml','Juice','beer','#174b36','#e4d16b','#ffffff',0,'/catalog/generated/KE-DRINK-0009.svg'),
('KE-DRINK-0010','2030000000104','Coca-Cola Coke Can 330ml','Coca-Cola','330ml','Soft drinks','beer','#174b36','#e4d16b','#ffffff',0,'/catalog/generated/KE-DRINK-0010.svg'),
('KE-DRINK-0011','2030000000111','Coke Soda PET 500ml','Coca-Cola','500ml','Soft drinks','beer','#174b36','#e4d16b','#ffffff',0,'/catalog/generated/KE-DRINK-0011.svg'),
('KE-DRINK-0012','2030000000128','Coca-Cola Coke PET Bottle 2L','Coca-Cola','2L','Soft drinks','beer','#174b36','#e4d16b','#ffffff',0,'/catalog/generated/KE-DRINK-0012.svg'),
('KE-DRINK-0013','2030000000135','Coca-Cola Coke Zero Can 330ml','Coca-Cola','330ml','Soft drinks','beer','#174b36','#e4d16b','#ffffff',0,'/catalog/generated/KE-DRINK-0013.svg'),
('KE-DRINK-0014','2030000000142','Fanta Passion PET Bottle 2L','Fanta','2L','Soft drinks','beer','#174b36','#e4d16b','#ffffff',0,'/catalog/generated/KE-DRINK-0014.svg'),
('KE-DRINK-0015','2030000000159','Fanta Blackcurrant PET Bottle 2L','Fanta','2L','Soft drinks','beer','#174b36','#e4d16b','#ffffff',0,'/catalog/generated/KE-DRINK-0015.svg'),
('KE-DRINK-0016','2030000000166','Fanta Orange PET Bottle 2L','Fanta','2L','Soft drinks','beer','#174b36','#e4d16b','#ffffff',0,'/catalog/generated/KE-DRINK-0016.svg'),
('KE-DRINK-0017','2030000000173','Pepsi Cola 2L','Pepsi','2L','Soft drinks','beer','#174b36','#e4d16b','#ffffff',0,'/catalog/generated/KE-DRINK-0017.svg'),
('KE-DRINK-0018','2030000000180','Pepsi Cola 500ml','Pepsi','500ml','Soft drinks','beer','#174b36','#e4d16b','#ffffff',0,'/catalog/generated/KE-DRINK-0018.svg'),
('KE-DRINK-0019','2030000000197','Mountain Dew 2L','Mountain Dew','2L','Soft drinks','beer','#174b36','#e4d16b','#ffffff',0,'/catalog/generated/KE-DRINK-0019.svg'),
('KE-DRINK-0020','2030000000203','7-Up Lemon & Lime Drink 2L','7-Up','2L','Soft drinks','beer','#174b36','#e4d16b','#ffffff',0,'/catalog/generated/KE-DRINK-0020.svg'),
('KE-DRINK-0021','2030000000210','Mirinda Pineapple Drink 2L','Mirinda','2L','Soft drinks','beer','#174b36','#e4d16b','#ffffff',0,'/catalog/generated/KE-DRINK-0021.svg'),
('KE-DRINK-0022','2030000000227','Pep Mixed Fruit Drink 2L','Pep','2L','Soft drinks','beer','#174b36','#e4d16b','#ffffff',0,'/catalog/generated/KE-DRINK-0022.svg');
