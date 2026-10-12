import { adminClient, corsHeaders, json, sha256, syntheticEmail } from "../_shared/access.ts";

Deno.serve(async (req) => {
  if (req.method === "OPTIONS") return new Response("ok", { headers: corsHeaders });
  if (req.method !== "POST") return json({ error: "method_not_allowed" }, 405);

  const body = await req.json().catch(() => ({}));
  const passkey = String(body.passkey ?? "").trim();
  if (!passkey) return json({ error: "passkey_required" }, 400);

  const db = adminClient();
  const passHash = await sha256(passkey);
  const { data: pass, error: lookupError } = await db
    .from("access_passes")
    .select("id,shop_id,role,expires_at,redeemed_at,revoked_at,shops!inner(id,name,status)")
    .eq("pass_hash", passHash)
    .maybeSingle();
  if (lookupError || !pass) return json({ error: "invalid_passkey" }, 401);
  if (pass.redeemed_at || pass.revoked_at || new Date(pass.expires_at).getTime() <= Date.now()) {
    return json({ error: "passkey_expired_or_used" }, 401);
  }
  const shop = Array.isArray(pass.shops) ? pass.shops[0] : pass.shops;
  if (!shop || shop.status !== "active") return json({ error: "business_not_active" }, 409);

  const email = syntheticEmail(passHash);
  const { data: created, error: createError } = await db.auth.admin.createUser({
    email,
    password: passkey,
    email_confirm: true,
    user_metadata: { counterpos_access: true, business_id: pass.shop_id, role: pass.role },
  });
  if (createError && !createError.message.toLowerCase().includes("already registered")) {
    return json({ error: "could_not_create_identity", detail: createError.message }, 500);
  }
  let userId = created.user?.id;
  if (!userId) {
    const { data: existing } = await db.auth.admin.listUsers({ page: 1, perPage: 1000 });
    userId = existing.users.find((u) => u.email === email)?.id;
  }
  if (!userId) return json({ error: "identity_not_created" }, 500);

  const { error: memberError } = await db.from("shop_members").upsert(
    { shop_id: pass.shop_id, user_id: userId, role: pass.role },
    { onConflict: "shop_id,user_id" },
  );
  if (memberError) return json({ error: "could_not_attach_member", detail: memberError.message }, 500);
  const { error: consumeError } = await db.from("access_passes").update({ redeemed_at: new Date().toISOString(), redeemed_by: userId }).eq("id", pass.id).is("redeemed_at", null);
  if (consumeError) return json({ error: "could_not_consume_pass" }, 500);

  return json({ email, password: passkey, business_id: pass.shop_id, business_name: shop.name, role: pass.role });
});
