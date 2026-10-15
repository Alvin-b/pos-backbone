import { createClient } from "https://esm.sh/@supabase/supabase-js@2.57.0";
import { adminClient, corsHeaders, json, sha256 } from "../_shared/access.ts";

Deno.serve(async (req) => {
  if (req.method === "OPTIONS") return new Response("ok", { headers: corsHeaders });
  if (req.method !== "POST") return json({ error: "method_not_allowed" }, 405);

  let body: { token?: string };
  try {
    body = await req.json();
  } catch {
    return json({ error: "invalid_json" }, 400);
  }
  const token = body.token?.trim() ?? "";
  if (!/^CPSA1\|[A-Z2-9-]+$/i.test(token)) return json({ error: "invalid_superadmin_token" }, 401);

  const db = adminClient();
  const { data: row, error } = await db.from("platform_admin_tokens")
    .select("token_hash,auth_user_id,expires_at")
    .eq("singleton", true)
    .maybeSingle();
  if (error || !row || new Date(row.expires_at).getTime() <= Date.now() || (await sha256(token)) !== row.token_hash) {
    return json({ error: "superadmin_token_expired_or_invalid" }, 401);
  }

  const { data: platformAdmin } = await db.from("platform_admins").select("user_id").eq("user_id", row.auth_user_id).maybeSingle();
  if (!platformAdmin) return json({ error: "platform_admin_required" }, 403);

  const anonKey = Deno.env.get("SUPABASE_ANON_KEY") ?? Deno.env.get("SUPABASE_PUBLISHABLE_KEY");
  if (!anonKey) return json({ error: "supabase_anon_key_not_configured" }, 500);
  const auth = createClient(Deno.env.get("SUPABASE_URL")!, anonKey, { auth: { autoRefreshToken: false, persistSession: false } });
  const { data: session, error: signInError } = await auth.auth.signInWithPassword({
    email: "superadmin-token@access.counterpos.invalid",
    password: token,
  });
  if (signInError || !session.session) return json({ error: "superadmin_token_sign_in_failed" }, 401);

  await db.from("platform_admin_tokens").update({ last_redeemed_at: new Date().toISOString() }).eq("singleton", true).eq("token_hash", row.token_hash);
  return json({
    access_token: session.session.access_token,
    refresh_token: session.session.refresh_token,
    expires_in: session.session.expires_in,
    token_type: session.session.token_type,
    user: { id: session.user?.id ?? row.auth_user_id, email: session.user?.email ?? "superadmin-token@access.counterpos.invalid" },
  });
});
