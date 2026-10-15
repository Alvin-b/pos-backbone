import { adminClient, caller, corsHeaders, createPasskey, json, sha256 } from "../_shared/access.ts";

const TOKEN_EMAIL = "superadmin-token@access.counterpos.invalid";
const TOKEN_TTL_SECONDS = 600;

Deno.serve(async (req) => {
  if (req.method === "OPTIONS") return new Response("ok", { headers: corsHeaders });
  if (req.method !== "POST") return json({ error: "method_not_allowed" }, 405);

  const user = await caller(req);
  if (!user) return json({ error: "unauthorized" }, 401);

  const db = adminClient();
  const { data: platformAdmin } = await db.from("platform_admins").select("user_id").eq("user_id", user.id).maybeSingle();
  if (!platformAdmin) return json({ error: "platform_admin_required" }, 403);

  const token = `CPSA1|${createPasskey()}-${createPasskey()}`;
  const tokenHash = await sha256(token);
  const expiresAt = new Date(Date.now() + TOKEN_TTL_SECONDS * 1000).toISOString();

  let tokenUserId: string | null = null;
  const users = await db.auth.admin.listUsers({ page: 1, perPage: 1000 });
  if (!users.error) tokenUserId = users.data.users.find((candidate) => candidate.email === TOKEN_EMAIL)?.id ?? null;

  if (!tokenUserId) {
    const created = await db.auth.admin.createUser({ email: TOKEN_EMAIL, password: token, email_confirm: true, user_metadata: { purpose: "rotating_superadmin_login" } });
    if (created.error || !created.data.user) return json({ error: "could_not_create_token_identity" }, 500);
    tokenUserId = created.data.user.id;
    const { error: adminInsertError } = await db.from("platform_admins").insert({ user_id: tokenUserId });
    if (adminInsertError && !adminInsertError.message.toLowerCase().includes("duplicate")) return json({ error: "could_not_register_token_identity" }, 500);
  } else {
    const updated = await db.auth.admin.updateUserById(tokenUserId, { password: token });
    if (updated.error) return json({ error: "could_not_rotate_token_identity" }, 500);
  }

  const { error } = await db.from("platform_admin_tokens").upsert({
    singleton: true,
    token_hash: tokenHash,
    auth_user_id: tokenUserId,
    issued_at: new Date().toISOString(),
    expires_at: expiresAt,
    issued_by: user.id,
    last_redeemed_at: null,
  });
  if (error) return json({ error: "could_not_store_superadmin_token" }, 500);

  return json({ token, expires_at: expiresAt, expires_in_seconds: TOKEN_TTL_SECONDS });
});
