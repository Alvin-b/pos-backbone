import { adminClient, bearer, caller, corsHeaders, json, sha256 } from "../_shared/access.ts";

Deno.serve(async (req) => {
  if (req.method === "OPTIONS") return new Response("ok", { headers: corsHeaders });
  if (req.method !== "POST") return json({ error: "method_not_allowed" }, 405);
  const user = await caller(req);
  if (!user) return json({ error: "not_authenticated" }, 401);
  const body = await req.json().catch(() => ({}));
  const token = String(body.token ?? "").trim();
  const shopId = String(body.shop_id ?? "").trim();
  const role = String(body.role ?? "cashier").trim();
  const invalidFields: string[] = [];
  if (!token) invalidFields.push("token");
  if (!shopId) invalidFields.push("shop_id");
  if (!["owner", "manager", "inventory_clerk", "cashier"].includes(role)) invalidFields.push("role");
  if (invalidFields.length) {
    return json({
      error: "invalid_qr_approval",
      message: `Invalid enrollment approval request: ${invalidFields.join(", ")}.`,
      invalid_fields: invalidFields,
    }, 400);
  }
  const db = adminClient();
  const [{ data: platform }, { data: membership }] = await Promise.all([
    db.from("platform_admins").select("user_id").eq("user_id", user.id).maybeSingle(),
    db
      .from("shop_members")
      .select("role,employment_status")
      .eq("shop_id", shopId)
      .eq("user_id", user.id)
      .maybeSingle(),
  ]);
  if (platform) {
    if (role !== "owner") return json({ error: "superadmin_owner_enrollment_only" }, 403);
  } else {
    if (!membership || membership.role !== "owner" || membership.employment_status !== "active") {
      return json({ error: "forbidden" }, 403);
    }
    if (role !== "cashier") return json({ error: "only_waiter_role_supported" }, 400);
  }
  const { data: shop } = await db.from("shops").select("id,status").eq("id", shopId).maybeSingle();
  if (!shop || shop.status !== "active") return json({ error: "business_not_active" }, 409);
  const { data: challenge } = await db
    .from("access_challenges")
    .select("id,status,expires_at")
    .eq("token_hash", await sha256(token))
    .maybeSingle();
  if (
    !challenge ||
    challenge.status !== "pending" ||
    new Date(challenge.expires_at).getTime() <= Date.now()
  )
    return json({ error: "qr_expired_or_used" }, 401);
  const { data: claimed, error } = await db
    .from("access_challenges")
    .update({
      status: "approved",
      shop_id: shopId,
      role,
      approved_at: new Date().toISOString(),
      approved_by: user.id,
    })
    .eq("id", challenge.id)
    .eq("status", "pending")
    .select("id")
    .maybeSingle();
  if (error) return json({ error: "could_not_approve_qr" }, 500);
  if (!claimed) return json({ error: "qr_expired_or_used" }, 409);
  return json({ approved: true });
});
