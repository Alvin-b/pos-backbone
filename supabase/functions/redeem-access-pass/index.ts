import { adminClient, corsHeaders, json, sha256, syntheticEmail } from "../_shared/access.ts";

Deno.serve(async (req) => {
  if (req.method === "OPTIONS") return new Response("ok", { headers: corsHeaders });
  if (req.method !== "POST") return json({ error: "method_not_allowed" }, 405);
  const body = await req.json().catch(() => ({}));
  // Access-pass hashes are case-insensitive; normalize the Auth password too so
  // a lower-case manual entry cannot create a credential different from its QR.
  const passkey = String(body.passkey ?? "").trim().toUpperCase();
  if (!passkey) return json({ error: "passkey_required" }, 400);
  const db = adminClient();
  const hash = await sha256(passkey);

  const { data: pass } = await db.from("access_passes").select("id,shop_id,role,expires_at,redeemed_at,revoked_at,shops!inner(name,status)").eq("pass_hash", hash).maybeSingle();
  if (!pass) return json({ error: "passkey_not_found" }, 404);
  if (pass.redeemed_at || pass.revoked_at || new Date(pass.expires_at).getTime() <= Date.now()) return json({ error: "passkey_expired_or_used" }, 401);
  const shop = Array.isArray(pass.shops) ? pass.shops[0] : pass.shops;
  if (!shop || shop.status !== "active") return json({ error: "business_not_active" }, 409);

  const email = syntheticEmail(hash);
  const { data: created, error: createError } = await db.auth.admin.createUser({ email, password: passkey, email_confirm: true, user_metadata: { counterpos_access: true, business_id: pass.shop_id, role: pass.role } });
  if (createError && !createError.message.toLowerCase().includes("already registered")) return json({ error: "could_not_create_identity" }, 500);
  let userId = created.user?.id;
  if (!userId) {
    const { data: existing } = await db.auth.admin.listUsers({ page: 1, perPage: 1000 });
    userId = existing.users.find((u) => u.email === email)?.id;
  }
  if (!userId) return json({ error: "identity_not_created" }, 500);

  // The server-side RPC enforces one-time use and attaches the membership atomically.
  const { data: redeemed, error: redeemError } = await db.rpc("redeem_access_pass_atomic", { _pass_hash: hash, _user: userId });
  if (redeemError) {
    const reason = String((redeemError as { message?: string }).message ?? "").trim();
    if (reason === "passkey_expired_or_used") return json({ error: "passkey_expired_or_used" }, 401);
    if (reason === "business_not_active") return json({ error: "business_not_active" }, 409);
    if (reason === "employee_inactive") return json({ error: "employee_inactive" }, 403);
    return json({ error: "could_not_redeem_passkey", detail: reason || undefined }, 500);
  }

  return json({
    status: "redeemed",
    email,
    password: passkey,
    business_id: pass.shop_id,
    business_name: shop.name,
    role: pass.role,
  });
});
