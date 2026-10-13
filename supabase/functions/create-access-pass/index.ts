import { adminClient, caller, corsHeaders, createPasskey, json, sha256 } from "../_shared/access.ts";

Deno.serve(async (req) => {
  if (req.method === "OPTIONS") return new Response("ok", { headers: corsHeaders });
  if (req.method !== "POST") return json({ error: "method_not_allowed" }, 405);

  const user = await caller(req);
  if (!user) return json({ error: "not_authenticated" }, 401);

  const body = await req.json().catch(() => ({}));
  const shopId = String(body.shop_id ?? "").trim();
  const role = String(body.role ?? "cashier").trim();
  if (!shopId || !["owner", "manager", "inventory_clerk", "cashier"].includes(role)) {
    return json({ error: "invalid_pass_request" }, 400);
  }

  const db = adminClient();
  const [{ data: platform }, { data: membership }] = await Promise.all([
    db.from("platform_admins").select("user_id").eq("user_id", user.id).maybeSingle(),
    db.from("shop_members").select("role,employment_status").eq("shop_id", shopId).eq("user_id", user.id).eq("employment_status", "active").maybeSingle(),
  ]);
  const isPlatformAdmin = Boolean(platform);
  const isManager = membership?.role === "owner" || membership?.role === "manager";
  if (!isPlatformAdmin && !isManager) return json({ error: "forbidden" }, 403);
  if (!isPlatformAdmin && role === "owner") return json({ error: "owner_pass_platform_only" }, 403);

  const { data: shop } = await db.from("shops").select("id,name,status,business_type,business_size,feature_flags").eq("id", shopId).maybeSingle();
  if (!shop) return json({ error: "business_not_found" }, 404);
  if (shop.status !== "active") return json({ error: "business_not_active" }, 409);

  const passkey = createPasskey();
  const passHash = await sha256(passkey);
  const { error } = await db.from("access_passes").insert({
    shop_id: shopId,
    role,
    pass_hash: passHash,
    created_by: user.id,
  });
  if (error) return json({ error: "could_not_create_pass", detail: error.message }, 500);

  return json({ business_id: shop.id, business_name: shop.name, role, passkey, business_type: shop.business_type, business_size: shop.business_size, feature_flags: shop.feature_flags, expires_in_hours: 24 });
});
