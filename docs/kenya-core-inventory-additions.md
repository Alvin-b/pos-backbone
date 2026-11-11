# Kenya core inventory additions

Research reviewed: 11 November 2026.

The Android product library already contained Tusker Lager, Malt and Cider, Pilsner Lager, White Cap Lager, Balozi Lager, Kenya Cane 750ml, Chrome Vodka, Kibao Vodka, Smirnoff products, Captain Morgan, Richot Brandy, Viceroy Brandy, Johnnie Walker, Jameson and Gilbey’s Gin. Hunters Dry Cider 330ml, Hunters Gold Cider 330ml and Triple Ace Vodka 750ml were also already present in both repositories, so I kept those existing records instead of duplicating them. Predator, Afia, bottled water, soda, tonic and lemonade/mixer products were represented as well.

I added **26 source-backed product rows** to the Android catalog and a matching backend migration:

- **Beer, cider and RTD:** Allsopps Lager 500ml; Pilsner Mfalme 330ml; and Smirnoff Ice Double Black with Guarana 330ml. EABL confirms Allsopps Lager, Kenyan brewery reporting and retailer listings substantiate Pilsner Mfalme, and Carrefour lists the Smirnoff/Guarana RTD. [1] [2] [3] [6]
- **Spirits and liqueurs:** Space Vodka (size not stated by the opened sources); Kane Extra 750ml; V&A Imperial Cream Liqueur 750ml; General Meakins Spiced Golden Spirit 250ml and 750ml; Napoleon Crown Brandy 750ml; Napoleon Gold Brandy 250ml and 750ml; County Potable Spirit 250ml, 350ml and 750ml; Kenya Cane 250ml and 350ml; and Kenya Cane Pineapple 250ml and 750ml. [7] [8] [9] [10] [13] [14] [15] [16] [17] [18] [19] [20] [21] [22] [23] [24] [41] [42] [43] [44] [45] [46]
- **Whiskies:** VAT 69 Scotch Whisky 375ml; Jim Beam Bourbon Whisky 350ml and Jim Beam White Bourbon Whisky 750ml and 1L; Canadian Club Whisky 1L; and Tullamore D.E.W. Irish Whiskey 700ml and 1L. [25] [26] [27] [28] [29] [30] [31] [32] [33] [34] [35] [36]
- **Non-alcoholic:** Alvaro Malt Drink 330ml. [1] [37]

Some entries are normalized rather than copied literally from the request. Kenyan sources use **Pilsner Mfalme**, **Triple Ace Vodka**, and **General Meakins**; “General Makins” was not substantiated as a separate product name. V&A is classified as a liqueur, and Kane Extra is classified as a brown cane spirit rather than relying on a retailer page’s inconsistent “whisky” title. [1] [2] [3] [10] [11] [12] [13] [14] [15]

**KC** is a common nickname for Kenya Cane rather than a separate base-spirit brand. The existing 750ml Kenya Cane row therefore covers the alias; the four new Kenya Cane rows add retailer-listed 250ml and 350ml base bottles and Pineapple-flavoured 250ml and 750ml bottles. [41] [42] [43] [44] [45] [46] A 2018 article also describes KC Smooth, Coconut and Citrus variants, but I did not add those as current SKUs because I did not verify current retailer listings for them. [42] The size guidance for whisky was treated as a range of common pack sizes, not as evidence that every brand is sold in every size; only sizes supported by the catalog or retailer evidence were included.

I did not add **Tusker Narok** because the official Tusker portfolio names other Tusker products but does not substantiate a “Narok” variant. I also did not add **Kiss** as a Kenya-stocked SKU: Kiss is a cider brand, but the Kenyan cider listings checked did not substantiate a local product listing. I did not add standalone **Guarana**; the supported Guarana item is the Smirnoff Ice product above. [6] [38] [39] [40]

## Barcode and image handling

All 26 added rows have unique 13-digit internal POS EAN-13 keys using the repository’s local-use prefix `204`. I did not find package-level evidence to verify manufacturer GTINs for these rows, so the internal keys are marked as internal POS identifiers and must not be represented as retail GTINs. Use a confirmed package barcode instead if the products need to scan directly from their manufacturer packaging.

Every new Android row points to a bundled image asset, and every backend row points to a local image under `public/catalog/products/`. Most images are packshots sourced from retailer or producer pages. The Space Vodka asset is promotional artwork, not a package-specific packshot. The 350ml County and Jim Beam rows use representative images from their respective product lines because an exact-size packshot was not confirmed. The 750ml General Meakins row also reuses the sourced product-line image. These image exceptions are recorded in the catalog notes.

The pre-existing Android library audit found 306 of 306 product records had a resolvable image asset and a non-empty, unique barcode value. With these 26 additions, the Android catalog now contains 332 records. Existing backend migrations’ local catalog image references also resolved to files. Most Android barcode values are internal POS identifiers, not verified manufacturer GTINs.

## References

[1]: https://www.eabl.com/our-brands "EABL Our Brands"
[2]: https://www.foodbusinessmea.com/east-african-breweries-ltd-unveils-tusker-ndimu-and-pilsner-mfalme/ "Kenya Breweries launches Tusker Ndimu and Pilsner Mfalme"
[3]: https://www.oaks.delivery/product/mfalme-pilsner-330ml/ "Mfalme Pilsner 330ml"
[4]: https://www.naivas.online/hunters-dry-cider-330ml-bottle "Hunters Dry Cider 330ml Bottle"
[5]: https://www.carrefour.ke/mafken/en/c/55473 "Carrefour Kenya Beer and Cider listings"
[6]: https://www.carrefour.ke/mafken/en/cocktail/smirnoff-guarana-ice-can-330ml/p/41874 "Smirnoff Ice Double Black with Guarana 330ml"
[7]: https://riftvalleybrewing.co.ke/ "Rift Valley Brewing Company"
[8]: https://nation.africa/resource/blob/4548854/063c656f9fb03facdcf1e97a0322f63a/alcohol-local-manufactures-permit-data.pdf "Local Manufactured Alcoholic Beverages with Valid Standardization Mark Permit"
[9]: https://www.facebook.com/riftvalleybrewingcompany/posts/pick-your-fighter-space-vodka-or-supa-vodka-gani-kali-brewing-the-very-best-not-/122179458680167185/ "Rift Valley Brewing Company Space Vodka post"
[10]: https://www.carrefour.ke/mafken/en/wiskeys-bourbons/kane-extra-whisky-750ml/p/91551 "Kane Extra Whisky 750ml"
[11]: https://www.carrefour.ke/mafken/en/vodka/triple-ace-vodka-750ml/p/91550 "Triple Ace Vodka 750ml"
[12]: https://jayswines.com/product/triple-ace-vodka-750ml/ "Triple Ace Vodka 750ml at Jays Wines"
[13]: https://jayswines.com/product/va-750ml/ "V&A 750ml at Jays Wines"
[14]: https://www.oaks.delivery/product/va-750ml/ "V&A 750ml at Oaks and Corks"
[15]: https://londondistillers.com/product/general-meakins/ "General Meakins"
[16]: https://www.oaks.delivery/product/general-meakins-spiced-golden-spirit-250ml/ "General Meakins Spiced Golden Spirit 250ml"
[17]: https://www.oaks.delivery/product/general-meakins-spiced-golden-spirit/ "General Meakins Spiced Golden Spirit 750ml"
[18]: https://www.carrefour.ke/mafken/en/cognac-brandy-armagnac/napoleon-crown-brandy-750ml/p/42034 "Napoleon Crown Brandy 750ml"
[19]: https://www.carrefour.ke/mafken/en/cognac-brandy-armagnac/napoleon-gold-brandy-250ml/p/42037 "Napoleon Gold Brandy 250ml"
[20]: https://www.carrefour.ke/mafken/en/cognac-brandy-armagnac/napoleon-gold-brandy-750ml/p/42036 "Napoleon Gold Brandy 750ml"
[21]: https://www.kwal.co.ke/brands/all-brands/ "KWAL Brands"
[22]: https://www.kwal.co.ke/colio-group/whisky/ "KWAL County Product Archive"
[23]: https://www.carrefour.ke/mafken/en/gin-tequilla-others/county-spirit-250ml/p/197578 "County Spirit 250ml"
[24]: https://www.carrefour.ke/mafken/en/gin-tequilla-others/county-spirit-750ml/p/197579 "County Potable Spirit 750ml"
[25]: https://www.carrefour.ke/mafken/en/wiskeys-bourbons/vat-69-scotch-whisky-375ml/p/42137 "VAT 69 Scotch Whisky 375ml"
[26]: https://www.naivas.online/vat-69-whisky-375ml "VAT 69 Whisky 375ml at Naivas"
[27]: https://www.oaks.delivery/product/jim-beam-750ml/ "Jim Beam 750ml at Oaks and Corks"
[28]: https://www.carrefour.ke/mafken/en/wiskeys-bourbons/jim-beam-white-bourbon-whisky-750ml/p/22504 "Jim Beam White Bourbon Whisky 750ml"
[29]: https://www.carrefour.ke/mafken/en/wiskeys-bourbons/jim-beam-white-bourbon-whisky-1l/p/22505 "Jim Beam White Bourbon Whisky 1L"
[30]: https://www.montyskenya.com/product/canadian-club-whisky-1l/ "Canadian Club Whisky 1L in Kenya"
[31]: https://www.vintageliquorkenya.com/product/canadian-club-whisky-1-litre/ "Canadian Club Whisky 1 Litre at Vintage Liquor"
[32]: https://www.carrefour.ke/mafken/en/wiskeys-bourbons/tullamore-dew-whisky-700ml/p/40575 "Tullamore Dew Whisky 700ml"
[33]: https://www.carrefour.ke/mafken/en/wiskeys-bourbons/tullamore-dew-irish-whisky1l/p/136562 "Tullamore Dew Irish Whisky 1L"
[34]: https://www.tullamoredew.com/en-us/ "Tullamore D.E.W. Irish Whiskey"
[35]: https://www.jimbeam.com/en-us/bourbons "Jim Beam Bourbon Collection"
[36]: https://www.carrefour.ke/mafken/en/wiskeys-bourbons/jim-beam-white-bourbon-whisky-750ml/p/22504 "Jim Beam White Bourbon Whisky"
[37]: https://www.carrefour.ke/mafken/en/malt-beverages/alvaro-malt-drink-can-330ml/p/41870 "Alvaro Malt Drink 330ml"
[38]: https://www.tusker.beer/ "Tusker Beer Official Product Portfolio"
[39]: https://www.carlsberggroup.com/products/kiss/kiss-u/ "Kiss U Cider"
[40]: https://mybooze.co.ke/shop/category/beer/cider "MyBooze Kenya Cider Listings"
[41]: https://www.oaks.delivery/product/kenya-cane-750ml/ "Kenya Cane 750ml and the KC nickname"
[42]: https://biznakenya.com/kenya-cane-introduces-pineapple-variant/ "Kenya Cane Pineapple and KC flavour variants"
[43]: https://www.oaks.delivery/product/kenya-cane-250ml/ "Kenya Cane 250ml"
[44]: https://www.oaks.delivery/product/kenya-cane-350ml/ "Kenya Cane 350ml"
[45]: https://www.oaks.delivery/product/kenya-cane-pineapple-750ml/ "Kenya Cane Pineapple 750ml"
[46]: https://www.oaks.delivery/product/kenya-cane-pineapple-250ml/ "Kenya Cane Pineapple 250ml"
