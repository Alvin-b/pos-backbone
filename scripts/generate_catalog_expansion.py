from pathlib import Path
from html import escape

OUT_SQL = Path('drizzle/migrations/0017_catalog_expansion.sql')
IMG_DIR = Path('public/catalog/generated')
COUNT = 1001

families = [
    ('Beer', 'beer', ['Tusker', 'White Cap', 'Pilsner', 'Balozi', 'Heineken', 'Corona', 'Savanna', 'Carlsberg'], ['330ml', '500ml', '650ml']),
    ('Cider', 'beer', ['Tusker Cider', 'Hunters', 'Savanna', 'Somersby', 'Manyatta'], ['330ml', '500ml']),
    ('Whisky', 'spirit', ['Johnnie Walker', 'Jameson', 'Grant\'s', 'Chivas Regal', 'Jack Daniel\'s', 'Glenfiddich', 'Ballantine\'s'], ['200ml', '375ml', '700ml', '750ml', '1L']),
    ('Vodka', 'spirit', ['Smirnoff', 'Absolut', 'Chrome', 'Ketel One', 'Belvedere', 'Ciroc'], ['200ml', '375ml', '700ml', '750ml', '1L']),
    ('Gin', 'spirit', ['Gordon\'s', 'Gilbey\'s', 'Tanqueray', 'Bombay Sapphire', 'Kenyan Originals', 'Beefeater'], ['200ml', '375ml', '700ml', '750ml', '1L']),
    ('Rum', 'spirit', ['Captain Morgan', 'Bacardi', 'Havana Club', 'Myers\'s', 'Omen', 'Don Papa'], ['200ml', '375ml', '700ml', '750ml', '1L']),
    ('Wine', 'spirit', ['Four Cousins', 'Nederburg', 'Frontera', 'Canti', 'Drostdy Hof', 'The War Horse'], ['187ml', '375ml', '750ml', '1.5L', '3L']),
    ('Liqueur', 'spirit', ['Baileys', 'Amarula', 'Jägermeister', 'Kahlúa', 'Butlers', 'Zappa'], ['200ml', '375ml', '700ml', '750ml', '1L']),
    ('Energy Drink', 'beer', ['Monster', 'Red Bull', 'Predator', 'Power Play', 'Azam', 'Bravado', 'Carabao'], ['250ml', '300ml', '330ml', '400ml', '500ml']),
    ('Soft Drink', 'beer', ['Coca-Cola', 'Fanta', 'Sprite', 'Pepsi', 'Mirinda', 'Krest', 'Mountain Dew'], ['300ml', '330ml', '500ml', '1L', '2L']),
    ('Juice', 'beer', ['Del Monte', 'Pick N Peel', 'Afia', 'Suntop', 'Gofrut', 'Ribena'], ['250ml', '500ml', '1L', '2L']),
    ('Water', 'beer', ['Keringet', 'Aquamist', 'Highlands', 'Mayers', 'Dasani', 'Perrier'], ['330ml', '500ml', '750ml', '1L', '1.5L', '5L']),
    ('Mixer', 'beer', ['Fitch & Leedes', 'Schweppes', 'KO', 'Tonic House'], ['200ml', '300ml', '500ml', '1L']),
    ('Malt Drink', 'beer', ['Bavaria', 'Maltina', 'Brava', 'Mabrouk'], ['300ml', '330ml', '500ml']),
    ('Iced Tea', 'beer', ['Kenyan Originals', 'Origin', 'Mangajo', 'Aquamist'], ['330ml', '500ml', '1L']),
    ('Sports Drink', 'beer', ['Reload', 'You C1000', 'Lucozade', 'Veroni Active'], ['250ml', '500ml', '700ml']),
]
flavours = ['Original', 'Lemon', 'Orange', 'Apple', 'Passion', 'Berry', 'Pineapple', 'Ginger', 'Mango', 'Tropical', 'Classic', 'Reserve', 'Dry', 'Light', 'Zero Sugar', 'Premium']

# Restricted internal-use EAN-13 prefix 200; these are unique scan keys, not verified retail GTINs.
def ean13(n: int) -> str:
    body = f'200{n:09d}'
    total = sum((3 if i % 2 else 1) * int(d) for i, d in enumerate(body))
    return body + str((10 - total % 10) % 10)

def sqlq(value: str) -> str:
    return "'" + value.replace("'", "''") + "'"

def image_svg(code: str, name: str, brand: str, size: str, category: str, barcode: str) -> str:
    palette = {
        'spirit': ('#173f35', '#e4c56a'),
        'beer': ('#163d58', '#e9b949'),
    }
    bg, accent = palette['spirit' if category in {'Whisky','Vodka','Gin','Rum','Wine','Liqueur'} else 'beer']
    return f'''<svg xmlns="http://www.w3.org/2000/svg" width="600" height="760" viewBox="0 0 600 760">
<defs><linearGradient id="bg" x1="0" y1="0" x2="1" y2="1"><stop stop-color="{bg}"/><stop offset="1" stop-color="#0b1721"/></linearGradient><linearGradient id="pack" x1="0" y1="0" x2="1" y2="1"><stop stop-color="#f8f1df"/><stop offset="1" stop-color="#d3c5a1"/></linearGradient></defs>
<rect width="600" height="760" rx="36" fill="url(#bg)"/><circle cx="500" cy="90" r="150" fill="{accent}" opacity=".12"/>
<text x="42" y="70" fill="{accent}" font-family="Arial,sans-serif" font-size="22" font-weight="700">COUNTERPOS CATALOG</text>
<rect x="190" y="130" width="220" height="400" rx="42" fill="url(#pack)" stroke="{accent}" stroke-width="8"/>
<rect x="240" y="98" width="120" height="45" rx="10" fill="#b9aa82"/><rect x="208" y="280" width="184" height="125" rx="8" fill="{bg}"/>
<text x="300" y="327" text-anchor="middle" fill="{accent}" font-family="Arial,sans-serif" font-size="22" font-weight="700">{escape(brand[:20])}</text>
<text x="300" y="358" text-anchor="middle" fill="#fff" font-family="Arial,sans-serif" font-size="17">{escape(category)}</text>
<text x="300" y="382" text-anchor="middle" fill="#fff" font-family="Arial,sans-serif" font-size="15">{escape(size)}</text>
<text x="42" y="600" fill="#fff" font-family="Arial,sans-serif" font-size="22" font-weight="700">{escape(name[:36])}</text>
<text x="42" y="640" fill="#b8c8d1" font-family="Arial,sans-serif" font-size="18">Generated catalog image · demo asset</text>
<text x="42" y="700" fill="{accent}" font-family="monospace" font-size="22">{barcode}</text>
</svg>'''

rows = []
for i in range(1, COUNT + 1):
    category, ptype, brands, sizes = families[(i - 1) % len(families)]
    brand = brands[(i * 7) % len(brands)]
    size = sizes[(i * 11) % len(sizes)]
    flavour = flavours[(i * 13) % len(flavours)]
    name = f'{brand} {flavour} {category} {size}'
    code = f'GEN-{i:04d}'
    barcode = ean13(i)
    price = 50 + ((i * 37) % 3950)
    img = f'/catalog/generated/{code}.svg'
    IMG_DIR.joinpath(f'{code}.svg').write_text(image_svg(code, name, brand, size, category, barcode), encoding='utf-8')
    rows.append(f"({sqlq(code)},{sqlq(barcode)},{sqlq(name)},{sqlq(brand)},{sqlq(size)},{sqlq(category)},{sqlq(ptype)},'#174b36','#e4d16b','#ffffff',{price},{sqlq(img)})")

header = '''-- Catalog expansion: 1,001 generated demo products with unique internal scan barcodes.
-- Barcodes use the restricted internal-use EAN-13 prefix 200 and are NOT verified retail GTINs.
-- Product images are local generated catalog-card assets under public/catalog/generated/.
INSERT INTO public.catalog_items(code,barcode,name,brand,size,category,product_type,body_color,label_color,label_text_color,suggested_price,image_url) VALUES
'''
OUT_SQL.write_text(header + ',\n'.join(rows) + ';\n', encoding='utf-8')
print(f'Generated {COUNT} products, {COUNT} images, and {OUT_SQL}')
