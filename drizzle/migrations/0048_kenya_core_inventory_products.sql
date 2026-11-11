-- Kenya-market beverage products requested for the core POS catalog.
-- All barcodes in this migration use restricted internal-use EAN-13 prefix 204.
-- These are unique internal POS scan keys, not verified manufacturer GTINs.
-- Sourced image assets are local under public/catalog/products/; entries without an exact-size photo use a representative image from the same product line.
INSERT INTO public.catalog_items(code,barcode,name,brand,size,category,product_type,body_color,label_color,label_text_color,suggested_price,image_url) VALUES
('KE-CORE-001','2040000000011','Allsopps Lager 500ml','Allsopps','500ml','Beer','beer','#174b36','#e4d16b','#ffffff','0','/catalog/products/allsopps_lager.webp'),
('KE-CORE-002','2040000000028','Pilsner Mfalme 330ml','Mfalme','330ml','Beer','beer','#174b36','#e4d16b','#ffffff','0','/catalog/products/mfalme_pilsner.webp'),
('KE-CORE-003','2040000000035','Smirnoff Ice Double Black with Guarana 330ml','Smirnoff Ice','330ml','RTD beverage','beer','#174b36','#e4d16b','#ffffff','0','/catalog/products/smirnoff_guarana.webp'),
('KE-CORE-004','2040000000042','Space Vodka','Space','','Spirits','spirit','#174b36','#e4d16b','#ffffff','0','/catalog/products/space_vodka.webp'),
('KE-CORE-005','2040000000059','Kane Extra 750ml','Kane Extra','750ml','Spirits','spirit','#174b36','#e4d16b','#ffffff','0','/catalog/products/kane_extra.webp'),
('KE-CORE-006','2040000000066','V&A Imperial Cream Liqueur 750ml','V&A','750ml','Liqueur','spirit','#174b36','#e4d16b','#ffffff','0','/catalog/products/va_liqueur.webp'),
('KE-CORE-007','2040000000073','General Meakins Spiced Golden Spirit 250ml','General Meakins','250ml','Spirits','spirit','#174b36','#e4d16b','#ffffff','0','/catalog/products/general_meakins.webp'),
('KE-CORE-008','2040000000080','General Meakins Spiced Golden Spirit 750ml','General Meakins','750ml','Spirits','spirit','#174b36','#e4d16b','#ffffff','0','/catalog/products/general_meakins.webp'),
('KE-CORE-009','2040000000097','Napoleon Crown Brandy 750ml','Napoleon','750ml','Spirits','spirit','#174b36','#e4d16b','#ffffff','0','/catalog/products/napoleon_crown_750.webp'),
('KE-CORE-010','2040000000103','Napoleon Gold Brandy 250ml','Napoleon','250ml','Spirits','spirit','#174b36','#e4d16b','#ffffff','0','/catalog/products/napoleon_gold_250.webp'),
('KE-CORE-011','2040000000110','Napoleon Gold Brandy 750ml','Napoleon','750ml','Spirits','spirit','#174b36','#e4d16b','#ffffff','0','/catalog/products/napoleon_gold_750.webp'),
('KE-CORE-012','2040000000127','County Potable Spirit 250ml','County','250ml','Spirits','spirit','#174b36','#e4d16b','#ffffff','0','/catalog/products/county_250.webp'),
('KE-CORE-013','2040000000134','County Potable Spirit 350ml','County','350ml','Spirits','spirit','#174b36','#e4d16b','#ffffff','0','/catalog/products/county_750.webp'),
('KE-CORE-014','2040000000141','County Potable Spirit 750ml','County','750ml','Spirits','spirit','#174b36','#e4d16b','#ffffff','0','/catalog/products/county_750.webp'),
('KE-CORE-015','2040000000158','VAT 69 Scotch Whisky 375ml','VAT 69','375ml','Whisky','spirit','#174b36','#e4d16b','#ffffff','0','/catalog/products/vat69_375.webp'),
('KE-CORE-016','2040000000165','Jim Beam Bourbon Whisky 350ml','Jim Beam','350ml','Whisky','spirit','#174b36','#e4d16b','#ffffff','0','/catalog/products/jim_beam_750.webp'),
('KE-CORE-017','2040000000172','Jim Beam White Bourbon Whisky 750ml','Jim Beam','750ml','Whisky','spirit','#174b36','#e4d16b','#ffffff','0','/catalog/products/jim_beam_750.webp'),
('KE-CORE-018','2040000000189','Jim Beam White Bourbon Whisky 1L','Jim Beam','1L','Whisky','spirit','#174b36','#e4d16b','#ffffff','0','/catalog/products/jim_beam_1l.webp'),
('KE-CORE-019','2040000000196','Canadian Club Whisky 1L','Canadian Club','1L','Whisky','spirit','#174b36','#e4d16b','#ffffff','0','/catalog/products/canadian_club_1l.webp'),
('KE-CORE-020','2040000000202','Tullamore D.E.W. Irish Whiskey 700ml','Tullamore Dew','700ml','Whisky','spirit','#174b36','#e4d16b','#ffffff','0','/catalog/products/tullamore_700.webp'),
('KE-CORE-021','2040000000219','Tullamore D.E.W. Irish Whiskey 1L','Tullamore Dew','1L','Whisky','spirit','#174b36','#e4d16b','#ffffff','0','/catalog/products/tullamore_1l.webp'),
('KE-CORE-022','2040000000226','Alvaro Malt Drink 330ml','Alvaro','330ml','Non-alcoholic','beer','#174b36','#e4d16b','#ffffff','0','/catalog/products/alvaro_330.webp'),
('KE-CORE-023','2040000000233','Kenya Cane 250ml','Kenya Cane','250ml','Spirits','spirit','#174b36','#e4d16b','#ffffff','0','/catalog/products/kenya_cane_250.webp'),
('KE-CORE-024','2040000000240','Kenya Cane 350ml','Kenya Cane','350ml','Spirits','spirit','#174b36','#e4d16b','#ffffff','0','/catalog/products/kenya_cane_350.webp'),
('KE-CORE-025','2040000000257','Kenya Cane Pineapple 750ml','Kenya Cane','750ml','Spirits','spirit','#174b36','#e4d16b','#ffffff','0','/catalog/products/kenya_cane_pineapple_750.webp'),
('KE-CORE-026','2040000000264','Kenya Cane Pineapple 250ml','Kenya Cane','250ml','Spirits','spirit','#174b36','#e4d16b','#ffffff','0','/catalog/products/kenya_cane_pineapple_250.webp')
ON CONFLICT (code) DO NOTHING;
