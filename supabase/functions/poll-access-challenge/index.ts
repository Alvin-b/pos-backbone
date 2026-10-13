import { adminClient, corsHeaders, json, sha256, syntheticEmail } from "../_shared/access.ts";

Deno.serve(async (req) => {
  if (req.method === "OPTIONS") return new Response("ok", { headers: corsHeaders });
  if (req.method !== "POST") return json({ error: "method_not_allowed" }, 405);
  const body = await req.json().catch(() => ({}));
  const token = String(body.token ?? "").trim();
  if (!token) return json({ error: "token_required" }, 400);
  const db = adminClient();
  const hash = await sha256(token);
  const { data: challenge } = await db.from("access_challenges").select("id,status,shop_id,role,expires_at,consumed_at,shops!inner(name,status)").eq("token_hash", hash).maybeSingle();
  if (!challenge) return json({ error: "qr_not_found" }, 404);
  if (new Date(challenge.expires_at).getTime() <= Date.now() && challenge.status === "pending") {
    await db.from("access_challenges").update({ status: "expired" }).eq("id", challenge.id);
    return json({ status: "expired" }, 401);
  }
  if (challenge.status === "pending") return json({ status: "pending" });
  if (challenge.status !== "approved" || !challenge.shop_id || !challenge.role) return json({ error: "qr_expired_or_used" }, 401);
  const shop = Array.isArray(challenge.shops) ? challenge.shops[0] : challenge.shops;
  if (!shop || shop.status !== "active") return json({ error: "business_not_active" }, 409);
  const email = syntheticEmail(hash);
  const { data: created, error: createError } = await db.auth.admin.createUser({ email, password: token, email_confirm: true, user_metadata: { counterpos_access: true, business_id: challenge.shop_id, role: challenge.role } });
  if (createError && !createError.message.toLowerCase().includes("already registered")) return json({ error: "could_not_create_identity" }, 500);
  let userId = created.user?.id;
  if (!userId) {
    const { data: existing } = await db.auth.admin.listUsers({ page: 1, perPage: 1000 });
    userId = existing.users.find((u) => u.email === email)?.id;
  }
  if (!userId) return json({ error: "identity_not_created" }, 500);
  const { error: memberError } = await db.from("shop_members").upsert({ shop_id: challenge.shop_id, user_id: userId, role: challenge.role, employment_status: "active" }, { onConflict: "shop_id,user_id" });
  if (memberError) return json({ error: "could_not_attach_member" }, 500);
  const { error: consumeError } = await db.from("access_challenges").update({ status: "consumed", consumed_at: new Date().toISOString(), consumed_by: userId }).eq("id", challenge.id).eq("status", "approved");
  if (consumeError) return json({ error: "could_not_consume_qr" }, 500);
  return json({ status: "approved", email, password: token, business_id: challenge.shop_id, business_name: shop.name, role: challenge.role });
});
