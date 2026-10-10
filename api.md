# Counter POS – Mobile API Guide

This backend powers the Counter POS mobile app: shops, staff, a shared master
beverage catalog, shop inventory, selling (with undo), receiving stock, and
daily totals. There is no web interface — the mobile app talks to the backend
directly using the official Supabase client SDK (works with React Native /
Expo, Flutter, Swift and Kotlin).

## 1. Connection settings

| Setting | Value |
|---|---|
| Project URL | `https://pvcqfoycrqtnirbwtccm.supabase.co` |
| Publishable (anon) key | `sb_publishable_1XttQd7gvzcsbZ__NnULGw_xMClc8GZ` |
| Currency | KES, whole shillings (integers) |
| Business day timezone | Africa/Nairobi |

The publishable key is safe to ship inside the app. All data is protected by
row-level security: a user only ever sees shops they belong to.

### React Native / Expo

```bash
npm i @supabase/supabase-js @react-native-async-storage/async-storage react-native-url-polyfill
```

```ts
import 'react-native-url-polyfill/auto';
import AsyncStorage from '@react-native-async-storage/async-storage';
import { createClient } from '@supabase/supabase-js';

export const supabase = createClient(
  'https://pvcqfoycrqtnirbwtccm.supabase.co',
  'sb_publishable_1XttQd7gvzcsbZ__NnULGw_xMClc8GZ',
  { auth: { storage: AsyncStorage, autoRefreshToken: true, persistSession: true, detectSessionInUrl: false } },
);
```

### Flutter

```dart
await Supabase.initialize(
  url: 'https://pvcqfoycrqtnirbwtccm.supabase.co',
  anonKey: 'sb_publishable_1XttQd7gvzcsbZ__NnULGw_xMClc8GZ',
);
final supabase = Supabase.instance.client;
```

Examples below use the JS SDK; every SDK has the same `from()`, `rpc()`,
`storage` and `auth` methods.

## 2. Authentication (email + password)

```ts
await supabase.auth.signUp({ email, password });           // sends a confirmation email
await supabase.auth.signInWithPassword({ email, password });
await supabase.auth.signOut();
const { data: { user } } = await supabase.auth.getUser();
```

Email confirmation is on: after `signUp`, `session` is `null` until the user
clicks the link in their email.

## 3. Data model

| Table | Purpose | App can |
|---|---|---|
| `shops` | A shop/counter. `id, name, currency, low_stock_threshold` | read; owners update `name`, `low_stock_threshold` |
| `shop_members` | Who works in a shop. `shop_id, user_id, role ('owner'\|'cashier')` | read; owners delete cashiers |
| `catalog_items` | Shared master library (78 Kenyan beverages). `id, code, barcode, name, brand, size, category, product_type, suggested_price, image_url, body_color, label_color, label_text_color` | read |
| `products` | A shop's own stocked items. `id, shop_id, code, barcode, name, brand, size, category, product_type, price, stock, photo_url, photo_path, archived, colours` | read; owners update `name, brand, size, category, price, photo_url, photo_path, archived, barcode` |
| `sales` | Sales ledger. `id, shop_id, product_id, product_name, qty, unit_price, total, sold_by, created_at, undone_at` | read |
| `stock_receipts` | Stock-in ledger. `id, shop_id, product_id, qty, is_new_product, received_by, created_at` | read |

`product_type` is `'beer'` (bottle shape) or `'spirit'` (spirit bottle shape).
When a product has no photo, draw the placeholder bottle with `body_color`,
`label_color` and `label_text_color` like the prototype.

Stock and sales are **never** written directly — use the functions below.

## 4. Functions (RPC)

Call with `supabase.rpc(name, args)`. Errors come back in `error.message`
using the codes listed.

| Function | Args | Returns | Errors |
|---|---|---|---|
| `create_shop` | `_name` | new shop (caller becomes owner) | `not_authenticated` |
| `add_member_by_email` | `_shop, _email, _role?` (`'cashier'` default) | – | `forbidden`, `user_not_found` (they must sign up first) |
| `find_product` | `_shop, _query` (barcode, code or name text) | list of products, exact code/barcode first | – |
| `record_sale` | `_product, _qty` (default 1) | sale row | `invalid_quantity`, `product_not_found`, `out_of_stock` |
| `undo_sale` | `_shop, _sale?` (omit = most recent sale) | undone sale; stock restored | `forbidden`, `nothing_to_undo` |
| `receive_stock` | `_product, _qty` | updated product | `invalid_quantity`, `product_not_found` |
| `add_from_catalog` | `_shop, _catalog, _qty?, _price?` | product (merged if already stocked) | `forbidden`, `catalog_item_not_found`, `invalid_input` |
| `register_product` | `_shop, _code, _name, _price, _qty, _photo_path, _size?, _type?, _brand?, _category?` | new product | `code_required`, `name_required`, `price_required`, `invalid_quantity`, `photo_required`, `code_exists` |
| `daily_summary` | `_shop, _day?` (`YYYY-MM-DD`, default today Nairobi) | `{ day, total, items_sold, sale_count, undone_count }` | `forbidden` |

## 5. Typical flows

### First launch
```ts
const { data: memberships } = await supabase
  .from('shop_members').select('role, shops(*)');
if (!memberships?.length) {
  const { data: shop } = await supabase.rpc('create_shop', { _name: 'My Counter' });
}
```

### Scan tab – scan, then sell
```ts
const { data: matches } = await supabase.rpc('find_product', { _shop: shopId, _query: scannedCode });
// 0 = "No stocked product found", 1 = show it, >1 = let the cashier choose
const { data: sale, error } = await supabase.rpc('record_sale', { _product: matches[0].id, _qty: qty });
if (error?.message.includes('out_of_stock')) showError('Out of stock. Check the shelf and tell a manager.');

// Undo (toast button)
await supabase.rpc('undo_sale', { _shop: shopId });
```

### Stock tab – shelf list
```ts
const { data: products } = await supabase
  .from('products').select('*')
  .eq('shop_id', shopId).eq('archived', false).order('name');
// low stock: stock <= shop.low_stock_threshold (default 5); out: stock = 0
```

### Receive stock – known barcode
```ts
const [p] = (await supabase.rpc('find_product', { _shop: shopId, _query: code })).data ?? [];
if (p && (p.code === code || p.barcode === code)) {
  await supabase.rpc('receive_stock', { _product: p.id, _qty: 6 });
}
```

### Receive stock – add from master library
```ts
const { data: library } = await supabase
  .from('catalog_items').select('*')
  .ilike('name', `%${search}%`)          // optional
  .eq('category', 'Juice')                // optional
  .order('name');
await supabase.rpc('add_from_catalog', { _shop: shopId, _catalog: item.id, _qty: 12, _price: 90 });
```

### Receive stock – register a brand-new barcode (photo required)
```ts
const path = `${shopId}/${crypto.randomUUID()}.jpg`;    // folder MUST be the shop id
await supabase.storage.from('product-photos')
  .upload(path, fileBlobOrArrayBuffer, { contentType: 'image/jpeg' });
await supabase.rpc('register_product', {
  _shop: shopId, _code: code, _name: 'Kibao Vodka', _price: 900, _qty: 12,
  _photo_path: path, _size: '750ml', _type: 'spirit',
});
```

### Showing photos
- Catalog items and products added from the catalog have a public `photo_url` / `image_url` — display it directly.
- Photos taken in the app are stored privately; `photo_path` is set. Get a temporary link:
```ts
const { data } = await supabase.storage.from('product-photos').createSignedUrl(p.photo_path, 3600);
```
- Replace a photo (owner): upload a new file, then `update({ photo_path })` on the product.

### Today tab
```ts
const { data: summary } = await supabase.rpc('daily_summary', { _shop: shopId });
const { data: recent } = await supabase.from('sales').select('*')
  .eq('shop_id', shopId).order('created_at', { ascending: false }).limit(50);
// undone sales have undone_at set — show them struck through
```

### Owner actions
```ts
await supabase.from('products').update({ price: 260 }).eq('id', productId);
await supabase.from('products').update({ archived: true }).eq('id', productId);
await supabase.rpc('add_member_by_email', { _shop: shopId, _email: 'cashier@shop.ke' });
await supabase.from('shop_members').delete().eq('shop_id', shopId).eq('user_id', cashierId);
```

## 6. Live updates (optional)

Stock and sales changes stream in real time, so two phones at one counter stay in sync:

```ts
const channel = supabase.channel(`shop-${shopId}`)
  .on('postgres_changes', { event: '*', schema: 'public', table: 'products', filter: `shop_id=eq.${shopId}` }, refreshShelf)
  .on('postgres_changes', { event: 'INSERT', schema: 'public', table: 'sales', filter: `shop_id=eq.${shopId}` }, refreshToday)
  .subscribe();
// on screen unmount:
supabase.removeChannel(channel);
```

## 7. Roles

| Action | Owner | Cashier |
|---|---|---|
| Sell, undo, scan, view shelf & today | yes | yes |
| Receive stock, add from library, register new product | yes | yes |
| Edit price / name / photo, archive products | yes | no |
| Add / remove cashiers, rename shop | yes | no |

## 8. Type generation (optional)

TypeScript types for every table and function live in
`src/integrations/supabase/types.ts` in this project — copy that file into the
mobile app and use `createClient<Database>(...)` for full autocomplete.
