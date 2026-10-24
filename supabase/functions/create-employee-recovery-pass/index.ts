import {
  adminClient,
  caller,
  corsHeaders,
  createPasskey,
  json,
  sha256,
} from "../_shared/access.ts";

Deno.serve(async (req) => {
  if (req.method === "OPTIONS") return new Response("ok", { headers: corsHeaders });
  if (req.method !== "POST") return json({ error: "method_not_allowed" }, 405);

  const user = await caller(req);
  if (!user) return json({ error: "not_authenticated" }, 401);

  const body = await req.json().catch(() => ({}));
  const shopId = String(body.shop_id ?? "").trim();
  const employeeUserId = String(body.user_id ?? "").trim();
  if (!shopId || !employeeUserId) return json({ error: "shop_and_user_required" }, 400);

  const passkey = createPasskey();
  const passHash = await sha256(passkey);
  const db = adminClient();
  const { data: expiresAt, error } = await db.rpc("issue_employee_recovery_pass", {
    _shop: shopId,
    _user: employeeUserId,
    _pass_hash: passHash,
    _actor: user.id,
  });
  if (error) {
    const reason = String((error as { message?: string }).message ?? "").trim();
    const status =
      reason === "forbidden"
        ? 403
        : ["employee_not_found", "employee_inactive", "business_not_active"].includes(reason)
          ? 409
          : 400;
    return json({ error: reason || "could_not_create_recovery_pass" }, status);
  }

  return json({
    business_id: shopId,
    user_id: employeeUserId,
    passkey,
    qr_payload: `CPX1.${passkey}`,
    expires_at: expiresAt,
    expires_in_minutes: 20,
  });
});
