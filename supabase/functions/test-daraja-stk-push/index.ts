import { adminClient, caller, corsHeaders, json } from "../_shared/access.ts";

const SANDBOX_BASE_URL = "https://sandbox.safaricom.co.ke";
const PRODUCTION_BASE_URL = "https://api.safaricom.co.ke";
const TOKEN_SAFETY_WINDOW_MS = 60_000;

let cachedToken: { value: string; expiresAt: number } | null = null;

function requiredEnv(name: string): string {
  const value = Deno.env.get(name)?.trim();
  if (!value) throw new Error(`missing_config_${name}`);
  return value;
}

function toMsisdn(value: unknown): string {
  const digits = String(value ?? "").replace(/\D/g, "");
  const normalized = digits.startsWith("0") ? `254${digits.slice(1)}` : digits;
  if (!/^2547\d{8}$/.test(normalized)) throw new Error("invalid_phone");
  return normalized;
}

function timestampInNairobi(date = new Date()): string {
  const parts = new Intl.DateTimeFormat("en-GB", {
    timeZone: "Africa/Nairobi",
    year: "numeric",
    month: "2-digit",
    day: "2-digit",
    hour: "2-digit",
    minute: "2-digit",
    second: "2-digit",
    hourCycle: "h23",
  }).formatToParts(date);
  const value = (type: string) => parts.find((part) => part.type === type)?.value ?? "";
  return `${value("year")}${value("month")}${value("day")}${value("hour")}${value("minute")}${value("second")}`;
}

function base64(value: string): string {
  return btoa(value);
}

async function getAccessToken(
  baseUrl: string,
  consumerKey: string,
  consumerSecret: string,
): Promise<string> {
  if (cachedToken && cachedToken.expiresAt > Date.now() + TOKEN_SAFETY_WINDOW_MS)
    return cachedToken.value;

  const basic = base64(`${consumerKey}:${consumerSecret}`);
  const response = await fetch(`${baseUrl}/oauth/v1/generate?grant_type=client_credentials`, {
    headers: { Authorization: `Basic ${basic}`, Accept: "application/json" },
  });
  const body = await response.text();
  let data: Record<string, unknown> = {};
  try {
    data = JSON.parse(body);
  } catch {
    /* preserve a stable error below */
  }
  if (!response.ok || typeof data.access_token !== "string") {
    console.error(
      "Daraja OAuth failed",
      response.status,
      data.error_description ?? data.error ?? "unknown",
    );
    throw new Error("daraja_oauth_failed");
  }
  const lifetimeSeconds = Number(data.expires_in) || 3599;
  cachedToken = {
    value: data.access_token,
    expiresAt: Date.now() + Math.max(60, lifetimeSeconds - 60) * 1000,
  };
  return cachedToken.value;
}

function publicError(error: unknown): { code: string; message: string } {
  const code = error instanceof Error ? error.message : "daraja_request_failed";
  const messages: Record<string, string> = {
    missing_config_DARAJA_CONSUMER_KEY: "Daraja consumer key is not configured in server secrets.",
    missing_config_DARAJA_CONSUMER_SECRET:
      "Daraja consumer secret is not configured in server secrets.",
    missing_config_DARAJA_SHORTCODE:
      "Daraja business shortcode is not configured in server secrets.",
    missing_config_DARAJA_PASSKEY: "Daraja passkey is not configured in server secrets.",
    invalid_phone: "Use a valid Kenyan M-Pesa number, for example 0712345678 or 254712345678.",
    invalid_amount: "Amount must be a whole number between KES 1 and KES 250,000.",
    invalid_reference: "Reference must contain 1–12 letters or numbers.",
    daraja_oauth_failed:
      "Daraja rejected the OAuth request. Check the environment and consumer credentials.",
    daraja_stk_rejected:
      "Daraja rejected the STK Push request. Inspect the response details below.",
    not_signed_in: "Sign in as a platform administrator first.",
    platform_admin_required: "Only a platform administrator can run the Daraja credential test.",
  };
  return { code, message: messages[code] ?? "The Daraja test could not be completed." };
}

Deno.serve(async (req) => {
  if (req.method === "OPTIONS") return new Response("ok", { headers: corsHeaders });
  if (req.method !== "POST") return json({ error: "method_not_allowed" }, 405);

  try {
    const user = await caller(req);
    if (!user) return json({ error: "not_signed_in", message: "Sign in first." }, 401);

    const db = adminClient();
    const { data: platformAdmin, error: adminCheckError } = await db
      .from("platform_admins")
      .select("user_id")
      .eq("user_id", user.id)
      .maybeSingle();
    if (adminCheckError) return json({ error: "platform_admin_check_failed" }, 500);
    if (!platformAdmin) return json({ error: "platform_admin_required" }, 403);

    const payload = await req.json().catch(() => ({}));
    const phone = toMsisdn(payload.phone);
    const amount = Number(payload.amount);
    if (!Number.isInteger(amount) || amount < 1 || amount > 250_000)
      throw new Error("invalid_amount");
    const reference = String(payload.reference ?? "CounterPOS").trim();
    if (!/^[A-Za-z0-9]{1,12}$/.test(reference)) throw new Error("invalid_reference");

    const environment = (Deno.env.get("DARAJA_ENVIRONMENT") ?? "sandbox").trim().toLowerCase();
    const baseUrl = environment === "production" ? PRODUCTION_BASE_URL : SANDBOX_BASE_URL;
    if (environment !== "sandbox" && environment !== "production")
      throw new Error("invalid_daraja_environment");
    const shortcode = requiredEnv("DARAJA_SHORTCODE");
    const passkey = requiredEnv("DARAJA_PASSKEY");
    const transactionType =
      payload.transactionType === "CustomerBuyGoodsOnline"
        ? "CustomerBuyGoodsOnline"
        : "CustomerPayBillOnline";
    const partyB = (Deno.env.get("DARAJA_PARTY_B") ?? shortcode).trim();
    const callbackUrl = (
      Deno.env.get("DARAJA_CALLBACK_URL") ??
      `${Deno.env.get("SUPABASE_URL")}/functions/v1/daraja-stk-callback`
    ).trim();
    if (!callbackUrl.startsWith("https://")) throw new Error("invalid_callback_url");

    const timestamp = timestampInNairobi();
    const password = base64(`${shortcode}${passkey}${timestamp}`);
    const accessToken = await getAccessToken(
      baseUrl,
      requiredEnv("DARAJA_CONSUMER_KEY"),
      requiredEnv("DARAJA_CONSUMER_SECRET"),
    );
    const response = await fetch(`${baseUrl}/mpesa/stkpush/v1/processrequest`, {
      method: "POST",
      headers: {
        Authorization: `Bearer ${accessToken}`,
        "Content-Type": "application/json",
        Accept: "application/json",
      },
      body: JSON.stringify({
        BusinessShortCode: Number(shortcode),
        Password: password,
        Timestamp: timestamp,
        TransactionType: transactionType,
        Amount: amount,
        PartyA: phone,
        PartyB: partyB,
        PhoneNumber: phone,
        CallBackURL: callbackUrl,
        AccountReference: reference,
        TransactionDesc: "Counter POS test",
      }),
    });
    const raw = await response.text();
    let data: Record<string, unknown> = {};
    try {
      data = JSON.parse(raw);
    } catch {
      data = { raw: raw.slice(0, 500) };
    }
    const accepted = response.ok && String(data.ResponseCode ?? "") === "0";
    if (!accepted) {
      console.error(
        "Daraja STK request rejected",
        response.status,
        data.ResponseCode ?? data.errorCode ?? data.errorMessage ?? "unknown",
      );
      return json(
        {
          ok: false,
          error: "daraja_stk_rejected",
          message: "Daraja rejected the STK Push request.",
          httpStatus: response.status,
          environment,
          response: data,
        },
        response.status >= 400 ? response.status : 502,
      );
    }
    return json({
      ok: true,
      environment,
      message: data.CustomerMessage ?? "STK Push accepted by Daraja.",
      merchantRequestId: data.MerchantRequestID ?? null,
      checkoutRequestId: data.CheckoutRequestID ?? null,
      responseCode: data.ResponseCode ?? null,
      responseDescription: data.ResponseDescription ?? null,
    });
  } catch (error) {
    const safe = publicError(error);
    console.error("Daraja STK test failed", safe.code);
    return json(
      { ok: false, error: safe.code, message: safe.message },
      safe.code === "not_signed_in" ? 401 : 400,
    );
  }
});
