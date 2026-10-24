import { createClient } from "https://esm.sh/@supabase/supabase-js@2.57.0";
import { adminClient, corsHeaders, json, sha256, syntheticEmail } from "../_shared/access.ts";

function newCredential() {
  const bytes = crypto.getRandomValues(new Uint8Array(32));
  return Array.from(bytes, (value) => value.toString(16).padStart(2, "0")).join("");
}

function recoveryError(reason: string) {
  if (reason === "passkey_expired_or_used") return json({ error: reason }, 401);
  if (reason === "business_not_active") return json({ error: reason }, 409);
  if (reason === "employee_inactive") return json({ error: reason }, 403);
  if (reason === "employee_recovery_in_progress") return json({ error: reason }, 409);
  if (reason === "employee_not_found") return json({ error: "employee_identity_not_found" }, 404);
  return json({ error: "could_not_redeem_employee_recovery" }, 500);
}

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

  // Recovery codes are not identities/passwords. Claim atomically, rotate the
  // password on the existing Auth user, then return a fresh session.
  const { data: recovery, error: recoveryErrorResult } = await db.rpc(
    "redeem_employee_recovery_pass_atomic",
    { _pass_hash: hash },
  );
  if (!recoveryErrorResult && recovery) {
    const claim = recovery as {
      user_id: string;
      business_id: string;
      business_name: string;
      role: string;
      claim_token: string;
    };
    const { data: identityResult, error: identityError } = await db.auth.admin.getUserById(claim.user_id);
    const identity = identityResult?.user;
    if (identityError || !identity?.email) return json({ error: "employee_identity_not_found" }, 404);

    const rotatedPassword = newCredential();
    const { error: rotateError } = await db.auth.admin.updateUserById(claim.user_id, {
      password: rotatedPassword,
    });
    if (rotateError) return json({ error: "could_not_rotate_employee_credential" }, 500);

    const anonKey = Deno.env.get("SUPABASE_ANON_KEY");
    if (!anonKey) return json({ error: "could_not_create_employee_session" }, 500);
    const sessionClient = createClient(Deno.env.get("SUPABASE_URL")!, anonKey, {
      auth: { autoRefreshToken: false, persistSession: false, detectSessionInUrl: false },
    });
    const { data: signedIn, error: signInError } = await sessionClient.auth.signInWithPassword({
      email: identity.email,
      password: rotatedPassword,
    });
    if (signInError || !signedIn.session) return json({ error: "could_not_create_employee_session" }, 500);

    const { error: completeError } = await db.rpc("complete_employee_recovery_pass", {
      _pass_hash: hash,
      _claim_token: claim.claim_token,
    });
    if (completeError) return json({ error: "could_not_finalize_employee_recovery" }, 409);

    return json({
      status: "redeemed",
      email: identity.email,
      user_id: claim.user_id,
      access_token: signedIn.session.access_token,
      refresh_token: signedIn.session.refresh_token,
      business_id: claim.business_id,
      business_name: claim.business_name,
      role: claim.role,
    });
  }
  const recoveryReason = String((recoveryErrorResult as { message?: string } | null)?.message ?? "").trim();
  if (recoveryReason && recoveryReason !== "employee_recovery_pass_not_found") {
    return recoveryError(recoveryReason);
  }

  const { data: pass } = await db.from("access_passes")
    .select("id,shop_id,role,expires_at,redeemed_at,revoked_at,shops!inner(name,status)")
    .eq("pass_hash", hash)
    .maybeSingle();
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
  const { error: redeemError } = await db.rpc("redeem_access_pass_atomic", { _pass_hash: hash, _user: userId });
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
