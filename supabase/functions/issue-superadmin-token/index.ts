import { adminClient, caller, corsHeaders, createPasskey, json, sha256 } from "../_shared/access.ts";

const TOKEN_EMAIL = "superadmin-token@access.counterpos.invalid";
const TOKEN_TTL_SECONDS = 600;
const USERS_PER_PAGE = 1000;

type AdminClient = ReturnType<typeof adminClient>;

async function findTokenIdentity(db: AdminClient): Promise<string | null> {
  for (let page = 1; ; page += 1) {
    const { data, error } = await db.auth.admin.listUsers({ page, perPage: USERS_PER_PAGE });
    if (error) throw new Error("token_identity_lookup_failed");

    const tokenUser = data.users.find(
      (candidate) => candidate.email?.toLowerCase() === TOKEN_EMAIL,
    );
    if (tokenUser) return tokenUser.id;
    if (data.users.length < USERS_PER_PAGE) return null;
  }
}

Deno.serve(async (req) => {
  if (req.method === "OPTIONS") return new Response("ok", { headers: corsHeaders });
  if (req.method !== "POST") return json({ error: "method_not_allowed" }, 405);

  try {
    const auth = req.headers.get("Authorization") ?? "";
    const raw = auth.replace(/^Bearer\s+/i, "");
    if (!raw) return json({ error: "not_signed_in", message: "Missing Authorization: Bearer <user access token>." }, 401);
    if (raw.startsWith("sb_") || raw.split(".").length !== 3) {
      console.error("Non-user token sent", raw.slice(0, 6));
      return json({ error: "not_signed_in", message: "Send the signed-in user's access token, not the publishable key." }, 401);
    }
    const user = await caller(req);
    if (!user) {
      console.error("User token rejected (expired or from another project)");
      return json({ error: "session_expired", message: "Sign in again and retry." }, 401);
    }

    const db = adminClient();
    const { data: platformAdmin, error: adminCheckError } = await db
      .from("platform_admins")
      .select("user_id")
      .eq("user_id", user.id)
      .maybeSingle();

    if (adminCheckError) {
      console.error("Superadmin allowlist lookup failed", adminCheckError.code);
      return json({ error: "platform_admin_check_failed" }, 500);
    }
    if (!platformAdmin) return json({ error: "platform_admin_required" }, 403);

    const token = `CPSA1|${createPasskey()}-${createPasskey()}`;
    const tokenHash = await sha256(token);
    const issuedAt = new Date();
    const expiresAt = new Date(issuedAt.getTime() + TOKEN_TTL_SECONDS * 1000);

    let tokenUserId = await findTokenIdentity(db);
    if (!tokenUserId) {
      const { data, error } = await db.auth.admin.createUser({
        email: TOKEN_EMAIL,
        password: token,
        email_confirm: true,
        user_metadata: { purpose: "rotating_superadmin_login" },
      });
      if (error || !data.user) {
        console.error("Could not create Superadmin token identity", error?.code);
        return json({ error: "could_not_create_token_identity" }, 500);
      }
      tokenUserId = data.user.id;
    } else {
      const { error } = await db.auth.admin.updateUserById(tokenUserId, { password: token });
      if (error) {
        console.error("Could not rotate Superadmin token identity", error.code);
        return json({ error: "could_not_rotate_token_identity" }, 500);
      }
    }

    // Repair a partially completed earlier issuance: the Auth identity may exist
    // even if its platform_admins row was not written on the previous attempt.
    const { error: identityGrantError } = await db.from("platform_admins").upsert(
      { user_id: tokenUserId, created_by: user.id },
      { onConflict: "user_id", ignoreDuplicates: true },
    );
    if (identityGrantError) {
      console.error("Could not register Superadmin token identity", identityGrantError.code);
      return json({ error: "could_not_register_token_identity" }, 500);
    }

    const { error: tokenStoreError } = await db.from("platform_admin_tokens").upsert(
      {
        singleton: true,
        token_hash: tokenHash,
        auth_user_id: tokenUserId,
        issued_at: issuedAt.toISOString(),
        expires_at: expiresAt.toISOString(),
        issued_by: user.id,
        last_redeemed_at: null,
      },
      { onConflict: "singleton" },
    );
    if (tokenStoreError) {
      console.error("Could not store Superadmin token", tokenStoreError.code);
      return json({ error: "could_not_store_superadmin_token_check_migration_0012" }, 500);
    }

    return json({
      token,
      expires_at: expiresAt.toISOString(),
      expires_in_seconds: TOKEN_TTL_SECONDS,
    });
  } catch (error) {
    console.error("Superadmin token issuance failed", error);
    return json({ error: "superadmin_token_issuance_failed" }, 500);
  }
});
