export type DarajaEnvironment = "sandbox" | "production";

export function darajaConfig() {
  const environment = (Deno.env.get("DARAJA_ENV") ?? "sandbox")
    .toLowerCase() as DarajaEnvironment;
  if (environment !== "sandbox" && environment !== "production") {
    throw new Error("DARAJA_ENV must be sandbox or production");
  }
  const consumerKey = Deno.env.get("DARAJA_CONSUMER_KEY") ?? "";
  const consumerSecret = Deno.env.get("DARAJA_CONSUMER_SECRET") ?? "";
  const shortcode = Deno.env.get("DARAJA_SHORTCODE") ?? "";
  const passkey = Deno.env.get("DARAJA_PASSKEY") ?? "";
  if (!consumerKey || !consumerSecret || !shortcode || !passkey) {
    throw new Error(
      "Daraja is not configured. Set DARAJA_CONSUMER_KEY, DARAJA_CONSUMER_SECRET, DARAJA_SHORTCODE and DARAJA_PASSKEY.",
    );
  }
  return {
    environment,
    consumerKey,
    consumerSecret,
    shortcode,
    passkey,
    transactionType: Deno.env.get("DARAJA_TRANSACTION_TYPE") ||
      "CustomerPayBillOnline",
    baseUrl: environment === "production"
      ? "https://api.safaricom.co.ke"
      : "https://sandbox.safaricom.co.ke",
  };
}

export function normalizeKenyanPhone(value: unknown): string | null {
  const digits = String(value ?? "").replace(/\D/g, "");
  const normalized = digits.startsWith("254") && digits.length === 12
    ? digits
    : digits.startsWith("0") && digits.length === 10
    ? `254${digits.slice(1)}`
    : (digits.startsWith("7") || digits.startsWith("1")) && digits.length === 9
    ? `254${digits}`
    : "";
  return /^254[17]\d{8}$/.test(normalized) ? normalized : null;
}

export function darajaTimestamp(now = new Date()): string {
  return now.toISOString().replace(/[-:TZ.]/g, "").slice(0, 14);
}

function base64(value: string): string {
  return btoa(String.fromCharCode(...new TextEncoder().encode(value)));
}

export async function darajaAccessToken(): Promise<string> {
  const config = darajaConfig();
  const response = await fetch(
    `${config.baseUrl}/oauth/v1/generate?grant_type=client_credentials`,
    {
      headers: {
        Authorization: `Basic ${
          base64(`${config.consumerKey}:${config.consumerSecret}`)
        }`,
      },
      signal: AbortSignal.timeout(15_000),
    },
  );
  const payload = await response.json().catch(() => ({}));
  if (!response.ok || typeof payload.access_token !== "string") {
    console.error(
      "Daraja OAuth failed",
      response.status,
      JSON.stringify(payload).slice(0, 500),
    );
    throw new Error(
      "Could not authenticate with Daraja. Check the Daraja credentials and environment.",
    );
  }
  return payload.access_token;
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
  const token = await darajaAccessToken();
  const response = await fetch(
    `${config.baseUrl}/mpesa/stkpush/v1/processrequest`,
    {
      method: "POST",
      headers: {
        Authorization: `Bearer ${token}`,
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
  const payload = await response.json().catch(() => ({}));
  if (
    !response.ok || String(payload.ResponseCode ?? "") !== "0" ||
    !payload.CheckoutRequestID
  ) {
    console.error(
      "Daraja STK Push rejected",
      response.status,
      JSON.stringify(payload).slice(0, 800),
    );
    return {
      success: false as const,
      description: String(
        payload.errorMessage ?? payload.ResponseDescription ??
          "Safaricom did not accept the STK Push request.",
      ),
    };
  }
  return {
    success: true as const,
    checkoutRequestId: String(payload.CheckoutRequestID),
    merchantRequestId: String(payload.MerchantRequestID ?? ""),
    customerMessage: String(
      payload.CustomerMessage ??
        "STK Push sent. Enter your M-Pesa PIN on your phone.",
    ),
  };
}

export async function darajaStkQuery(checkoutRequestId: string) {
  const config = darajaConfig();
  const timestamp = darajaTimestamp();
  const password = base64(`${config.shortcode}${config.passkey}${timestamp}`);
  const token = await darajaAccessToken();
  const response = await fetch(
    `${config.baseUrl}/mpesa/stkpushquery/v1/query`,
    {
      method: "POST",
      headers: {
        Authorization: `Bearer ${token}`,
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
  const payload = await response.json().catch(() => ({}));
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
