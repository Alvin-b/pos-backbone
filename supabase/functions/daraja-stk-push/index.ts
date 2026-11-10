import { adminClient, caller, corsHeaders, json } from "../_shared/access.ts";
import { darajaStkPush, normalizeKenyanPhone } from "../_shared/daraja.ts";

Deno.serve(async (req) => {
  if (req.method === "OPTIONS") {
    return new Response("ok", { headers: corsHeaders });
  }
  if (req.method !== "POST") {
    return json({ success: false, error: "method_not_allowed" }, 405);
  }

  const user = await caller(req);
  if (!user) return json({ success: false, error: "unauthorized" }, 401);

  let payload: Record<string, unknown>;
  try {
    payload = await req.json();
  } catch {
    return json({ success: false, error: "invalid_json" }, 400);
  }

  const shopId = typeof payload.shop_id === "string" ? payload.shop_id : "";
  const phone = normalizeKenyanPhone(payload.phone_number);
  if (
    !/^[0-9a-f]{8}-[0-9a-f]{4}-[1-8][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/i
      .test(shopId)
  ) {
    return json({ success: false, error: "invalid_shop_id" }, 400);
  }
  if (!phone) {
    return json({
      success: false,
      error: "Enter a valid Kenyan M-Pesa number.",
    }, 400);
  }

  const db = adminClient();
  const { data: member, error: membershipError } = await db
    .from("shop_members")
    .select("role,employment_status")
    .eq("shop_id", shopId)
    .eq("user_id", user.id)
    .maybeSingle();
  if (membershipError) {
    console.error(
      "Could not verify subscription payer membership",
      membershipError.message,
    );
    return json({
      success: false,
      error: "Could not verify business access. Please retry.",
    }, 500);
  }
  if (
    !member || member.role !== "owner" || member.employment_status !== "active"
  ) {
    return json({
      success: false,
      error:
        "Only the active business owner can initiate a subscription payment.",
    }, 403);
  }

  const { data: shop, error: shopError } = await db
    .from("shops")
    .select("id,name,status,subscription_price_ksh,subscription_plan_days")
    .eq("id", shopId)
    .maybeSingle();
  if (shopError || !shop) {
    console.error(
      "Could not load subscription price",
      shopError?.message ?? "business_not_found",
    );
    return json({
      success: false,
      error: "Could not load this business subscription. Please retry.",
    }, 404);
  }
  if (shop.status === "closed") {
    return json(
      { success: false, error: "This business account is closed." },
      403,
    );
  }

  const amount = Number(shop.subscription_price_ksh);
  const planDays = Number(shop.subscription_plan_days);
  if (
    !Number.isSafeInteger(amount) || amount < 1 || amount > 250_000 ||
    !Number.isSafeInteger(planDays) || planDays < 1 || planDays > 365
  ) {
    console.error(
      "Invalid server subscription pricing",
      shopId,
      amount,
      planDays,
    );
    return json({
      success: false,
      error: "Subscription pricing is not configured for this business.",
    }, 500);
  }

  const { data: payment, error: insertError } = await db
    .from("mpesa_subscription_payments")
    .insert({
      shop_id: shopId,
      initiated_by: user.id,
      phone_number: phone,
      amount_ksh: amount,
      plan_days: planDays,
      status: "initiating",
    })
    .select("id")
    .single();
  if (insertError || !payment) {
    console.error(
      "Could not create M-Pesa payment record",
      insertError?.message ?? "missing_row",
    );
    return json({
      success: false,
      error: "Could not start a payment attempt. Please retry.",
    }, 500);
  }

  const supabaseUrl = Deno.env.get("SUPABASE_URL") ?? "";
  const callbackUrl = Deno.env.get("DARAJA_CALLBACK_URL") ||
    `${supabaseUrl.replace(/\/$/, "")}/functions/v1/daraja-stk-callback`;
  if (!callbackUrl.startsWith("https://")) {
    await db.from("mpesa_subscription_payments").update({
      status: "failed",
      result_description: "HTTPS callback URL required.",
    }).eq("id", payment.id);
    return json({
      success: false,
      error:
        "Set a publicly reachable HTTPS DARAJA_CALLBACK_URL before accepting payments.",
    });
  }

  try {
    const result = await darajaStkPush({
      phone,
      amount,
      accountReference: `CP${shopId.replaceAll("-", "").slice(0, 10)}`,
      description: "POS Subscription",
      callbackUrl,
    });
    if (!result.success) {
      await db.from("mpesa_subscription_payments")
        .update({
          status: "failed",
          result_description: result.description.slice(0, 500),
        })
        .eq("id", payment.id);
      return json({ success: false, error: result.description });
    }

    const { error: updateError } = await db.from("mpesa_subscription_payments")
      .update({
        status: "pending",
        checkout_request_id: result.checkoutRequestId,
        merchant_request_id: result.merchantRequestId,
      })
      .eq("id", payment.id);
    if (updateError) {
      console.error(
        "Daraja accepted the STK prompt but payment tracking failed",
        updateError.message,
      );
      return json({
        success: false,
        error:
          "M-Pesa prompt was sent, but tracking failed. Contact support before retrying.",
      });
    }
    return json({
      success: true,
      checkout_request_id: result.checkoutRequestId,
      merchant_request_id: result.merchantRequestId,
      customer_message: result.customerMessage,
    });
  } catch (error) {
    const message = error instanceof Error
      ? error.message
      : "Daraja request failed.";
    await db.from("mpesa_subscription_payments")
      .update({ status: "failed", result_description: message.slice(0, 500) })
      .eq("id", payment.id);
    console.error("M-Pesa STK Push could not be initiated", message);
    return json({ success: false, error: message });
  }
});
