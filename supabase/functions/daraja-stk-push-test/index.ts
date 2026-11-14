const corsHeaders = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers": "authorization, x-client-info, apikey, content-type",
  "Access-Control-Allow-Methods": "POST, OPTIONS",
};

type Payload = Record<string, unknown>;

function json(body: Payload, status = 200) {
  return new Response(JSON.stringify(body), {
    status,
    headers: { ...corsHeaders, "Content-Type": "application/json" },
  });
}

function required(name: string): string {
  const value = Deno.env.get(name)?.trim();
  if (!value) throw new Error(`missing_config_${name}`);
  return value;
}

function normalizePhone(value: unknown): string | null {
  const digits = String(value ?? "").replace(/\D/g, "");
  const normalized =
    digits.startsWith("254") && digits.length === 12
      ? digits
      : digits.startsWith("0") && digits.length === 10
        ? `254${digits.slice(1)}`
        : (digits.startsWith("7") || digits.startsWith("1")) && digits.length === 9
          ? `254${digits}`
          : "";
  return /^254[17]\d{8}$/.test(normalized) ? normalized : null;
}

function timestamp(): string {
  const parts = new Intl.DateTimeFormat("en-GB", {
    timeZone: "Africa/Nairobi",
    year: "numeric",
    month: "2-digit",
    day: "2-digit",
    hour: "2-digit",
    minute: "2-digit",
    second: "2-digit",
    hourCycle: "h23",
  }).formatToParts(new Date());
  const part = (type: string) => parts.find((entry) => entry.type === type)?.value ?? "";
  return `${part("year")}${part("month")}${part("day")}${part("hour")}${part("minute")}${part("second")}`;
}

function basicAuth(value: string): string {
  return `Basic ${btoa(value)}`;
}

function messageFor(error: unknown): string {
  const code = error instanceof Error ? error.message : String(error);
  const messages: Record<string, string> = {
    test_mode_disabled:
      "The isolated Daraja test function is disabled. Set DARAJA_TEST_ENABLED=true.",
    invalid_phone: "Enter a valid Kenyan M-Pesa number, for example 0712345678.",
    invalid_amount: "Amount must be a whole number between KES 1 and KES 250,000.",
    daraja_oauth_failed: "Daraja OAuth failed. Check the consumer credentials and environment.",
    daraja_stk_rejected: "Daraja rejected the STK Push request.",
  };
  if (code.startsWith("missing_config_"))
    return `Missing backend secret: ${code.slice("missing_config_".length)}.`;
  return messages[code] ?? "The Daraja test request could not be completed.";
}

Deno.serve(async (req) => {
  if (req.method === "OPTIONS") return new Response("ok", { headers: corsHeaders });
  if (req.method !== "POST") return json({ success: false, error: "method_not_allowed" }, 405);
  if (Deno.env.get("DARAJA_TEST_ENABLED") !== "true")
    return json({ success: false, error: "test_mode_disabled" }, 403);

  try {
    const payload = (await req.json()) as Payload;
    const phone = normalizePhone(payload.phone_number ?? payload.phone);
    const amount = Number(payload.amount);
    if (!phone) throw new Error("invalid_phone");
    if (!Number.isSafeInteger(amount) || amount < 1 || amount > 250_000)
      throw new Error("invalid_amount");

    const environment = (Deno.env.get("DARAJA_ENV") ?? "sandbox").toLowerCase();
    if (environment !== "sandbox" && environment !== "production")
      throw new Error("invalid_daraja_environment");
    const baseUrl =
      environment === "production"
        ? "https://api.safaricom.co.ke"
        : "https://sandbox.safaricom.co.ke";
    const consumerKey = required("DARAJA_CONSUMER_KEY");
    const consumerSecret = required("DARAJA_CONSUMER_SECRET");
    const shortcode = required("DARAJA_SHORTCODE");
    const passkey = required("DARAJA_PASSKEY");
    const timestampValue = timestamp();
    const password = btoa(`${shortcode}${passkey}${timestampValue}`);

    const oauth = await fetch(`${baseUrl}/oauth/v1/generate?grant_type=client_credentials`, {
      headers: { Authorization: basicAuth(`${consumerKey}:${consumerSecret}`) },
      signal: AbortSignal.timeout(15_000),
    });
    const oauthBody = (await oauth.json().catch(() => ({}))) as Payload;
    if (!oauth.ok || typeof oauthBody.access_token !== "string")
      throw new Error("daraja_oauth_failed");

    const callbackUrl =
      Deno.env.get("DARAJA_TEST_CALLBACK_URL")?.trim() ||
      `${required("SUPABASE_URL")}/functions/v1/daraja-stk-callback`;
    const stk = await fetch(`${baseUrl}/mpesa/stkpush/v1/processrequest`, {
      method: "POST",
      headers: {
        Authorization: `Bearer ${oauthBody.access_token}`,
        "Content-Type": "application/json",
      },
      body: JSON.stringify({
        BusinessShortCode: shortcode,
        Password: password,
        Timestamp: timestampValue,
        TransactionType: Deno.env.get("DARAJA_TRANSACTION_TYPE") || "CustomerPayBillOnline",
        Amount: amount,
        PartyA: phone,
        PartyB: shortcode,
        PhoneNumber: phone,
        CallBackURL: callbackUrl,
        AccountReference:
          String(payload.reference ?? "POS-TEST")
            .replace(/[^a-zA-Z0-9]/g, "")
            .slice(0, 12) || "POSTEST",
        TransactionDesc: "Counter POS test".slice(0, 13),
      }),
      signal: AbortSignal.timeout(20_000),
    });
    const response = (await stk.json().catch(() => ({}))) as Payload;
    if (!stk.ok || String(response.ResponseCode ?? "") !== "0" || !response.CheckoutRequestID) {
      console.error(
        "Daraja isolated test rejected",
        stk.status,
        JSON.stringify(response).slice(0, 600),
      );
      return json(
        { success: false, error: "daraja_stk_rejected", http_status: stk.status, response },
        stk.status >= 400 ? stk.status : 502,
      );
    }
    return json({
      success: true,
      environment,
      checkout_request_id: response.CheckoutRequestID,
      merchant_request_id: response.MerchantRequestID ?? null,
      customer_message:
        response.CustomerMessage ?? "STK Push sent. Enter your M-Pesa PIN on the phone.",
    });
  } catch (error) {
    console.error(
      "Isolated Daraja test failed",
      error instanceof Error ? error.message : String(error),
    );
    return json({ success: false, error: messageFor(error) }, 400);
  }
});
