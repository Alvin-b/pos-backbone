import { adminClient, corsHeaders, json } from "../_shared/access.ts";
import {
  darajaStkQuery,
  isSafaricomStillProcessing,
  normalizeKenyanPhone,
  verifyDarajaCallbackSignature,
} from "../_shared/daraja.ts";

function callbackItem(items: unknown, name: string): unknown {
  if (!Array.isArray(items)) return undefined;
  return items.find(
    (item) => item && typeof item === "object" && (item as Record<string, unknown>).Name === name,
  )?.Value;
}

function sleep(ms: number) {
  return new Promise((resolve) => setTimeout(resolve, ms));
}

async function findByCheckout(db: ReturnType<typeof adminClient>, checkoutId: string) {
  return await db
    .from("mpesa_subscription_payments")
    .select("id,shop_id,phone_number,amount_ksh,status,result_code,checkout_request_id")
    .eq("checkout_request_id", checkoutId)
    .maybeSingle();
}

Deno.serve(async (req) => {
  if (req.method === "OPTIONS") return new Response("ok", { headers: corsHeaders });
  if (req.method !== "POST") return json({ ResultCode: 1, ResultDesc: "Method not allowed" }, 405);

  let body: Record<string, unknown>;
  try {
    body = await req.json();
  } catch {
    return json({ ResultCode: 1, ResultDesc: "Invalid callback payload" }, 400);
  }
  const stk =
    body?.Body && typeof body.Body === "object"
      ? ((body.Body as Record<string, unknown>).stkCallback as Record<string, unknown> | undefined)
      : undefined;
  const checkoutId = typeof stk?.CheckoutRequestID === "string" ? stk.CheckoutRequestID.trim() : "";
  if (!checkoutId) return json({ ResultCode: 0, ResultDesc: "Callback accepted" });

  const db = adminClient();
  const callbackParams = new URL(req.url).searchParams;
  const candidatePaymentId = callbackParams.get("payment_id")?.trim() ?? "";
  const paymentSignature = callbackParams.get("payment_signature") ?? "";
  let paymentId = "";
  if (candidatePaymentId && paymentSignature) {
    try {
      if (await verifyDarajaCallbackSignature(candidatePaymentId, paymentSignature)) {
        paymentId = candidatePaymentId;
      } else {
        console.error("Rejected invalid payment callback signature");
      }
    } catch (error) {
      console.error(
        "Could not verify payment callback signature",
        error instanceof Error ? error.message : String(error),
      );
    }
  }
  const merchantRequestId =
    typeof stk?.MerchantRequestID === "string" ? stk.MerchantRequestID : null;
  let payment: Record<string, unknown> | null = null;

  // The initiation request includes its payment row ID in the callback URL.
  // This closes the race where Safaricom calls back before the push response
  // has been persisted with its CheckoutRequestID.
  if (paymentId) {
    const { data: byId, error: idError } = await db
      .from("mpesa_subscription_payments")
      .select("id,shop_id,phone_number,amount_ksh,status,result_code,checkout_request_id")
      .eq("id", paymentId)
      .maybeSingle();
    if (idError) {
      console.error("Could not locate callback payment by ID", idError.message);
      return json({ ResultCode: 0, ResultDesc: "Callback accepted for retry" });
    }
    if (byId) {
      const storedCheckoutId =
        typeof byId.checkout_request_id === "string" ? byId.checkout_request_id : "";
      if (storedCheckoutId && storedCheckoutId !== checkoutId) {
        console.error("Callback checkout ID did not match its payment ID", paymentId);
        return json({ ResultCode: 0, ResultDesc: "Callback accepted" });
      }
      if (!storedCheckoutId && (byId.status === "initiating" || byId.status === "pending")) {
        let link = db
          .from("mpesa_subscription_payments")
          .update({
            checkout_request_id: checkoutId,
            merchant_request_id: merchantRequestId,
            status: "pending",
          })
          .eq("id", paymentId)
          .eq("status", byId.status);
        if (byId.status === "pending") link = link.is("checkout_request_id", null);
        const { error: linkError } = await link;
        if (linkError)
          console.error("Could not link callback to its payment row", linkError.message);
      }
      const { data: linked, error: linkedError } = await db
        .from("mpesa_subscription_payments")
        .select("id,shop_id,phone_number,amount_ksh,status,result_code,checkout_request_id")
        .eq("id", paymentId)
        .maybeSingle();
      if (linkedError) {
        console.error("Could not reload callback payment", linkedError.message);
        return json({ ResultCode: 0, ResultDesc: "Callback accepted for retry" });
      }
      payment = linked;
    }
  }

  if (!payment) {
    let lookup = await findByCheckout(db, checkoutId);
    for (let attempt = 0; !lookup.data && !lookup.error && attempt < 8; attempt++) {
      await sleep(250);
      lookup = await findByCheckout(db, checkoutId);
    }
    if (lookup.error) {
      console.error("Could not locate callback payment", lookup.error.message);
      return json({ ResultCode: 0, ResultDesc: "Callback accepted for retry" });
    }
    payment = lookup.data;
  }
  if (
    !payment ||
    payment.checkout_request_id !== checkoutId ||
    payment.status === "paid" ||
    (payment.status === "failed" && Number(payment.result_code) !== 4999)
  ) {
    return json({ ResultCode: 0, ResultDesc: "Callback accepted" });
  }

  if (payment.status === "failed" && Number(payment.result_code) === 4999) {
    const { error: recoveryError } = await db
      .from("mpesa_subscription_payments")
      .update({
        status: "pending",
        completed_at: null,
        result_description: "Safaricom is still processing this request.",
      })
      .eq("id", payment.id)
      .eq("status", "failed")
      .eq("result_code", 4999);
    if (recoveryError) {
      console.error(
        "Could not recover callback for a previously misclassified payment",
        recoveryError.message,
      );
    }
    payment = { ...payment, status: "pending" };
  }

  try {
    const query = await darajaStkQuery(checkoutId);
    if (String(query.CheckoutRequestID ?? "") !== checkoutId) {
      console.error(
        "STK Query checkout ID did not match the callback",
        checkoutId,
        JSON.stringify(query).slice(0, 600),
      );
      return json({ ResultCode: 0, ResultDesc: "Payment remains pending verification" });
    }

    if (isSafaricomStillProcessing(query)) {
      console.info("Safaricom is still processing callback checkout", checkoutId);
      return json({ ResultCode: 0, ResultDesc: "Payment remains pending verification" });
    }
    if (String(query.ResponseCode ?? "") !== "0") {
      console.info("STK Query has not returned a final result for checkout", checkoutId);
      return json({ ResultCode: 0, ResultDesc: "Payment remains pending verification" });
    }

    const queryResultCode = Number(query.ResultCode);
    const callbackResultCode = Number(stk?.ResultCode);
    if (Number.isFinite(queryResultCode) && queryResultCode !== 0) {
      await db
        .from("mpesa_subscription_payments")
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
      return json({ ResultCode: 0, ResultDesc: "Payment remains pending verification" });
    }

    const metadata =
      stk?.CallbackMetadata && typeof stk.CallbackMetadata === "object"
        ? (stk.CallbackMetadata as Record<string, unknown>).Item
        : undefined;
    const amount = Number(callbackItem(metadata, "Amount"));
    const receipt = String(callbackItem(metadata, "MpesaReceiptNumber") ?? "").trim();
    const phone = normalizeKenyanPhone(callbackItem(metadata, "PhoneNumber"));
    if (!Number.isSafeInteger(amount) || !receipt || !phone) {
      console.error("Successful STK callback omitted required verification metadata", checkoutId);
      return json({ ResultCode: 0, ResultDesc: "Payment remains pending verification" });
    }

    const { error: finalizeError } = await db.rpc("finalize_mpesa_subscription_payment", {
      p_checkout_request_id: checkoutId,
      p_mpesa_receipt: receipt,
      p_amount_ksh: amount,
      p_phone_number: phone,
      p_result_code: 0,
    });
    if (finalizeError) {
      console.error(
        "Could not finalize verified M-Pesa payment",
        checkoutId,
        finalizeError.message,
      );
      return json({ ResultCode: 0, ResultDesc: "Payment remains pending verification" });
    }
    return json({ ResultCode: 0, ResultDesc: "Callback processed" });
  } catch (error) {
    console.error(
      "Safaricom callback verification failed",
      checkoutId,
      error instanceof Error ? error.message : String(error),
    );
    return json({ ResultCode: 0, ResultDesc: "Payment remains pending verification" });
  }
});
