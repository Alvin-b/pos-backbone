# Kenya beverage catalog research

Research date: 2026-10-17.

This repository now distinguishes three types of product identifiers:

1. **Verified external barcodes**: GTIN/EAN values directly exposed by a product-level source and paired with a product image. These are recorded in `data/kenya_verified_products.json`.
2. **Retailer identifiers**: Naivas SKUs and Carrefour product IDs. These identify a retailer listing, not a retail GTIN, so they are not copied into the barcode field.
3. **Internal POS scan keys**: generated values used to keep the catalog operational when a package-level GTIN was not publicly available. They are not manufacturer barcodes.

## Coverage researched

The research covered beer, cider and RTD alcohol; whisky and bourbon; vodka, gin, rum, tequila and brandy; wine, sparkling wine and liqueurs; soft drinks; energy and sports drinks; water, juice and iced tea; and mixers, malt drinks and kombucha.

Naivas Online exposes a broad spirits catalogue and category counts, including 271 spirit products on the inspected page, with categories for whisky, gin, brandy, liqueur, rum, tequila and vodka. Carrefour Kenya exposes alcohol, wine, spirits, beer and cider listings and reports more than 50,000 total grocery items across the site. These retailer pages establish Kenya-market listing coverage, but the crawlable product text generally exposes retailer SKUs or Carrefour product IDs instead of GTINs.

The catalog also includes Kenya retailer-listed juice and soda variants requested for the POS: Minute Maid Tropical, Mango and Delight Tropical; Del Monte apple, pineapple-mango, pineapple-orange, lemonade, energy and mango variants; Coca-Cola/Coke and Coke Zero; Fanta Passion, Blackcurrant and Orange; Pepsi; Mountain Dew; 7-Up; Mirinda Pineapple; and Pep Mixed Fruit. Their retailer source pages are stored in the app catalog records, and each has an image asset plus an internal POS scan key when a package-level GTIN was not exposed.

## Sources

- Naivas spirits category: https://www.naivas.online/spirits
- Naivas beer/cider category: https://www.naivas.online/beer/cider-cocktails
- Naivas beverage category: https://www.naivas.online/beverage
- Naivas cold beverage listings: https://www.naivas.online/cold-beverage
- Carrefour Kenya alcohol category: https://www.carrefour.ke/mafken/en/c/FKEN21000000
- Carrefour Kenya soft drinks category: https://www.carrefour.ke/mafken/en/c/FKEN1500000
- Carrefour Kenya iced tea category: https://www.carrefour.ke/mafken/en/c/FKEN1560100
- Carrefour Kenya energy drinks category: https://www.carrefour.ke/mafken/en/c/FKEN1550203
- Carrefour Kenya Del Monte listings: https://www.carrefour.ke/mafken/en/c/61405
- GS1 Kenya barcode verification service: https://www.gs1kenya.org/search/barcodes
- Open Food Facts API/data documentation: https://world.openfoodfacts.org/data
- Chrome Vodka record: https://world.openfoodfacts.org/product/6161101604031/chrome-vodka
- Afia Fruit Drinks record: https://world.openfoodfacts.org/product/6164000012013/afia-fruit-drinks
- Safari Energy Drink record: https://world.openfoodfacts.org/product/6164001199195/safari-energy-drink

## Important limitation

No public source inspected supports the claim that this is an exhaustive list of every liquor or beverage sold in Kenya. Stock, pack variants and availability change by retailer, branch and date. Product-level GTIN verification requires a barcode lookup or package-level evidence. The system therefore preserves the broad retailer-derived catalog while marking only the three records above as externally verified barcode/image matches.
