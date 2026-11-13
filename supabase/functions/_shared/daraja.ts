export type DarajaEnvironment = "sandbox" | "production";

export function darajaConfig() {
  const environment = (Deno.env.get("DARAJA_ENV") ?? "sandbox").toLowerCase() as DarajaEnvironment;
  if (environment !== "sandbox" && environment !== "production") {
    throw new Error("DARAJA_ENV must be sandbox or production");
  }
  const consumerKey = Deno.env.get("DARAJA_CONSUMER_KEY") ?? "";
  const consumerSecret = Deno.env.get("DARAJA_CONSUMER_SECRET") ?? "";
  const shortcode = Deno.env.get("DARAJA_SHORTCODE") ?? "";
  const passkey = Deno.env.get("DARAJA_PASSKEY") ?? "";
  const transactionType = Deno.env.get("DARAJA_TRANSACTION_TYPE") ?? "";
  if (!consumerKey || !consumerSecret || !shortcode || !passkey) {
    throw new Error(
      "Daraja is not configured. Set DARAJA_CONSUMER_KEY, DARAJA_CONSUMER_SECRET, DARAJA_SHORTCODE and DARAJA_PASSKEY.",
    );
  }
  if (!["CustomerPayBillOnline", "CustomerBuyGoodsOnline"].includes(transactionType)) {
    throw new Error(
      "Set DARAJA_TRANSACTION_TYPE to CustomerPayBillOnline for PayBill or CustomerBuyGoodsOnline for Buy Goods Till.",
    );
  }
  return {
    environment,
    consumerKey,
    consumerSecret,
    shortcode,
    passkey,
    transactionType,
    baseUrl:
      environment === "production"
        ? "https://api.safaricom.co.ke"
        : "https://sandbox.safaricom.co.ke",
  };
}

export function normalizeKenyanPhone(value: unknown): string | null {
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

export function isSafaricomStillProcessing(result: Record<string, unknown>): boolean {
  const codeIsProcessing = [result.ResultCode, result.ResponseCode].some(
    (code) => Number(code) === 4999,
  );
  const description = String(result.ResultDesc ?? result.ResponseDescription ?? "");
  return codeIsProcessing || /transaction is still under processing/i.test(description);
}

export function darajaTimestamp(now = new Date()): string {
  const parts = new Intl.DateTimeFormat("en-GB", {
    timeZone: "Africa/Nairobi",
    year: "numeric",
    month: "2-digit",
    day: "2-digit",
    hour: "2-digit",
    minute: "2-digit",
    second: "2-digit",
    hourCycle: "h23",
  }).formatToParts(now);
  const part = (type: Intl.DateTimeFormatPartTypes) =>
    parts.find((entry) => entry.type === type)?.value ?? "";
  return `${part("year")}${part("month")}${part("day")}${part("hour")}${part("minute")}${part("second")}`;
}

function base64(value: string): string {
  return btoa(String.fromCharCode(...new TextEncoder().encode(value)));
}

export async function darajaCallbackSignature(paymentId: string): Promise<string> {
  const secret =
    Deno.env.get("DARAJA_CALLBACK_SECRET") || Deno.env.get("SUPABASE_SERVICE_ROLE_KEY");
  if (!secret) throw new Error("A server-side callback signing secret is not configured.");
  const key = await crypto.subtle.importKey(
    "raw",
    new TextEncoder().encode(secret),
    { name: "HMAC", hash: "SHA-256" },
    false,
    ["sign"],
  );
  const signature = await crypto.subtle.sign("HMAC", key, new TextEncoder().encode(paymentId));
  return Array.from(new Uint8Array(signature))
    .map((byte) => byte.toString(16).padStart(2, "0"))
    .join("");
}

export async function verifyDarajaCallbackSignature(
  paymentId: string,
  signature: string,
): Promise<boolean> {
  if (!/^[a-f0-9]{64}$/i.test(signature)) return false;
  const expected = await darajaCallbackSignature(paymentId);
  let mismatch = 0;
  for (let index = 0; index < expected.length; index++) {
    mismatch |= expected.charCodeAt(index) ^ signature.toLowerCase().charCodeAt(index);
  }
  return mismatch === 0;
}

let cachedAccessToken: string | null = null;
let accessTokenExpiresAt = 0;
let accessTokenRequest: Promise<string> | null = null;

export async function darajaAccessToken(): Promise<string> {
  if (cachedAccessToken && Date.now() < accessTokenExpiresAt - 30_000) {
    return cachedAccessToken;
  }
  if (accessTokenRequest) return accessTokenRequest;

  accessTokenRequest = (async () => {
    const config = darajaConfig();
    const response = await fetch(
      `${config.baseUrl}/oauth/v1/generate?grant_type=client_credentials`,
      {
        headers: {
          Authorization: `Basic ${base64(`${config.consumerKey}:${config.consumerSecret}`)}`,
        },
        signal: AbortSignal.timeout(15_000),
      },
    );
    const payload = await response.json().catch(() => ({}));
    if (!response.ok || typeof payload.access_token !== "string") {
      console.error("Daraja OAuth failed", response.status, JSON.stringify(payload).slice(0, 500));
      throw new Error(
        "Could not authenticate with Daraja. Check the Daraja credentials and environment.",
      );
    }
    const expiresIn = Number(payload.expires_in);
    cachedAccessToken = payload.access_token;
    accessTokenExpiresAt =
      Date.now() + (Number.isFinite(expiresIn) && expiresIn > 0 ? expiresIn : 3600) * 1000;
    return payload.access_token;
  })();
  try {
    return await accessTokenRequest;
  } finally {
    accessTokenRequest = null;
  }
}

function isInvalidDarajaAccessToken(response: Response, payload: Record<string, unknown>): boolean {
  if (response.status === 401) return true;
  return [payload.errorMessage, payload.error_description, payload.message, payload.error].some(
    (value) => typeof value === "string" && /invalid[\s_-]*access[\s_-]*token/i.test(value),
  );
}

function invalidateDarajaAccessToken(rejectedToken: string) {
  if (cachedAccessToken !== rejectedToken) return;
  cachedAccessToken = null;
  accessTokenExpiresAt = 0;
}

async function darajaFetchJson(url: string, init: RequestInit) {
  let token = await darajaAccessToken();
  for (let attempt = 0; attempt < 2; attempt++) {
    const headers = new Headers(init.headers);
    headers.set("Authorization", `Bearer ${token}`);
    const response = await fetch(url, { ...init, headers });
    const rawPayload = await response.json().catch(() => ({}));
    const payload =
      rawPayload && typeof rawPayload === "object" && !Array.isArray(rawPayload)
        ? (rawPayload as Record<string, unknown>)
        : {};

    if (attempt === 0 && isInvalidDarajaAccessToken(response, payload)) {
      console.warn("Daraja rejected the access token; refreshing once");
      invalidateDarajaAccessToken(token);
      token = await darajaAccessToken();
      continue;
    }

    return { response, payload };
  }

  throw new Error("Daraja access token refresh did not complete.");
}

export async function darajaStkPush(args: {
  phone: string;
  amount: number;
  accountReference: string;
  description: string;
  callbackUrl: string;
}) {
  const config = darajaConfig();
  const timestamp = darajaTimestamp();
  const password = base64(`${config.shortcode}${config.passkey}${timestamp}`);
  const { response, payload } = await darajaFetchJson(
    `${config.baseUrl}/mpesa/stkpush/v1/processrequest`,
    {
      method: "POST",
      headers: {
        "Content-Type": "application/json",
      },
      body: JSON.stringify({
        BusinessShortCode: config.shortcode,
        Password: password,
        Timestamp: timestamp,
        TransactionType: config.transactionType,
        Amount: args.amount,
        PartyA: args.phone,
        PartyB: config.shortcode,
        PhoneNumber: args.phone,
        CallBackURL: args.callbackUrl,
        AccountReference: args.accountReference.slice(0, 12),
        TransactionDesc: args.description.slice(0, 13),
      }),
      signal: AbortSignal.timeout(20_000),
    },
  );
  if (!response.ok || String(payload.ResponseCode ?? "") !== "0" || !payload.CheckoutRequestID) {
    console.error(
      "Daraja STK Push rejected",
      response.status,
      JSON.stringify(payload).slice(0, 800),
    );
    return {
      success: false as const,
      description: String(
        payload.errorMessage ??
          payload.ResponseDescription ??
          "Safaricom did not accept the STK Push request.",
      ),
    };
  }
  return {
    success: true as const,
    checkoutRequestId: String(payload.CheckoutRequestID),
    merchantRequestId: String(payload.MerchantRequestID ?? ""),
    customerMessage: String(
      payload.CustomerMessage ?? "STK Push sent. Enter your M-Pesa PIN on your phone.",
    ),
  };
}

export async function darajaStkQuery(checkoutRequestId: string) {
  const config = darajaConfig();
  const timestamp = darajaTimestamp();
  const password = base64(`${config.shortcode}${config.passkey}${timestamp}`);
  const { response, payload } = await darajaFetchJson(
    `${config.baseUrl}/mpesa/stkpushquery/v1/query`,
    {
      method: "POST",
      headers: {
        "Content-Type": "application/json",
      },
      body: JSON.stringify({
        BusinessShortCode: config.shortcode,
        Password: password,
        Timestamp: timestamp,
        CheckoutRequestID: checkoutRequestId,
      }),
      signal: AbortSignal.timeout(20_000),
    },
  );
  if (!response.ok) {
    console.error(
      "Daraja STK Query failed",
      response.status,
      JSON.stringify(payload).slice(0, 800),
    );
    throw new Error("Could not verify the M-Pesa payment with Safaricom.");
  }
  return payload as Record<string, unknown>;
}
