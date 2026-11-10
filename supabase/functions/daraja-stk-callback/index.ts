import { adminClient, corsHeaders, json } from "../_shared/access.ts";
import { darajaStkQuery, normalizeKenyanPhone } from "../_shared/daraja.ts";

function callbackItem(items: unknown, name: string): unknown {
  if (!Array.isArray(items)) return undefined;
  return items.find((item) =>
    item && typeof item === "object" &&
    (item as Record<string, unknown>).Name === name
  )?.Value;
}

Deno.serve(async (req) => {
  if (req.method === "OPTIONS") {
    return new Response("ok", { headers: corsHeaders });
  }
  if (req.method !== "POST") {
    return json({ ResultCode: 1, ResultDesc: "Method not allowed" }, 405);
  }

  let body: Record<string, unknown>;
  try {
    body = await req.json();
  } catch {
    return json({ ResultCode: 1, ResultDesc: "Invalid callback payload" }, 400);
  }
  const stk = body?.Body && typeof body.Body === "object"
    ? (body.Body as Record<string, unknown>).stkCallback as
      | Record<string, unknown>
      | undefined
    : undefined;
  const checkoutId = typeof stk?.CheckoutRequestID === "string"
    ? stk.CheckoutRequestID
    : "";
  if (!checkoutId) {
    return json({ ResultCode: 0, ResultDesc: "Callback accepted" });
  }

  const db = adminClient();
  const { data: payment, error } = await db.from("mpesa_subscription_payments")
    .select("id,shop_id,phone_number,amount_ksh,status")
    .eq("checkout_request_id", checkoutId)
    .maybeSingle();
  if (error) {
    console.error("Could not locate callback payment", error.message);
    return json({ ResultCode: 0, ResultDesc: "Callback accepted for retry" });
  }
  if (!payment || payment.status === "paid" || payment.status === "failed") {
    return json({ ResultCode: 0, ResultDesc: "Callback accepted" });
  }

  try {
    const query = await darajaStkQuery(checkoutId);
    if (
      String(query.CheckoutRequestID ?? "") !== checkoutId ||
      String(query.ResponseCode ?? "") !== "0"
    ) {
      console.error(
        "STK Query did not confirm checkout identity/success",
        checkoutId,
        JSON.stringify(query).slice(0, 600),
      );
      return json({
        ResultCode: 0,
        ResultDesc: "Payment remains pending verification",
      });
    }

    const queryResultCode = Number(query.ResultCode);
    const callbackResultCode = Number(stk?.ResultCode);
    if (Number.isFinite(queryResultCode) && queryResultCode !== 0) {
      await db.from("mpesa_subscription_payments")
        .update({
          status: "failed",
          result_code: queryResultCode,
          result_description: String(
            query.ResultDesc ?? stk?.ResultDesc ?? "Payment was not completed.",
          ).slice(0, 500),
          completed_at: new Date().toISOString(),
        })
        .eq("id", payment.id)
        .eq("status", "pending");
      return json({ ResultCode: 0, ResultDesc: "Callback accepted" });
    }
    if (callbackResultCode !== 0 || queryResultCode !== 0) {
      console.error(
        "STK Query has not returned a verifiable success result",
        checkoutId,
        JSON.stringify(query).slice(0, 600),
      );
      return json({
        ResultCode: 0,
        ResultDesc: "Payment remains pending verification",
      });
    }

    const metadata =
      stk?.CallbackMetadata && typeof stk.CallbackMetadata === "object"
        ? (stk.CallbackMetadata as Record<string, unknown>).Item
        : undefined;
    const amount = Number(callbackItem(metadata, "Amount"));
    const receipt = String(callbackItem(metadata, "MpesaReceiptNumber") ?? "")
      .trim();
    const phone = normalizeKenyanPhone(callbackItem(metadata, "PhoneNumber"));
    if (!Number.isSafeInteger(amount) || !receipt || !phone) {
      console.error(
        "Successful STK callback omitted required verification metadata",
        checkoutId,
      );
      return json({
        ResultCode: 0,
        ResultDesc: "Payment remains pending verification",
      });
    }

    const { error: finalizeError } = await db.rpc(
      "finalize_mpesa_subscription_payment",
      {
        p_checkout_request_id: checkoutId,
        p_mpesa_receipt: receipt,
        p_amount_ksh: amount,
        p_phone_number: phone,
        p_result_code: 0,
      },
    );
    if (finalizeError) {
      console.error(
        "Could not finalize verified M-Pesa payment",
        checkoutId,
        finalizeError.message,
      );
      return json({
        ResultCode: 0,
        ResultDesc: "Payment remains pending verification",
      });
    }
    return json({ ResultCode: 0, ResultDesc: "Callback processed" });
  } catch (error) {
    console.error(
      "Safaricom callback verification failed",
      checkoutId,
      error instanceof Error ? error.message : String(error),
    );
    return json({
      ResultCode: 0,
      ResultDesc: "Payment remains pending verification",
    });
  }
});
