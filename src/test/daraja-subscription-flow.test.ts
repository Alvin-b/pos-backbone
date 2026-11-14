import { readFileSync } from "node:fs";
import { describe, expect, it } from "vitest";
import {
  DiagnosticCategory,
  ModuleKind,
  ScriptTarget,
  flattenDiagnosticMessageText,
  transpileModule,
} from "typescript";
import { darajaTimestamp, isSafaricomStillProcessing } from "../../supabase/functions/_shared/daraja.ts";

const helper = readFileSync("supabase/functions/_shared/daraja.ts", "utf8");
const push = readFileSync("supabase/functions/daraja-stk-push/index.ts", "utf8");
const status = readFileSync("supabase/functions/daraja-stk-status/index.ts", "utf8");
const callback = readFileSync("supabase/functions/daraja-stk-callback/index.ts", "utf8");
const config = readFileSync("supabase/config.toml", "utf8");

describe("Daraja subscription payment contract", () => {
  it("reads credentials only from Edge Function runtime secrets and defaults safely to sandbox", () => {
    for (const key of [
      "MPESA_CONSUMER_KEY",
      "MPESA_CONSUMER_SECRET",
      "MPESA_PASSKEY",
    ]) {
      expect(helper).toContain(`configuredSecret("${key}"`);
    }
    expect(helper).toMatch(/const shortcode = configuredSecret\(\s*"MPESA_SHORTCODE",/);
    expect(helper).toContain(
      'configuredSecret("MPESA_ENVIRONMENT", "DARAJA_ENVIRONMENT", "DARAJA_ENV")',
    );
    expect(helper).toContain('configuredSecret("MPESA_CONSUMER_KEY", "DARAJA_CONSUMER_KEY")');
    expect(helper).toContain('configuredSecret("MPESA_PASSKEY", "DARAJA_PASSKEY")');
    expect(helper).toContain('"https://sandbox.safaricom.co.ke"');
    expect(helper).toContain('TransactionType: "CustomerPayBillOnline"');
    expect(helper).not.toContain('Deno.env.get("DARAJA_SHORTCODE")');
    expect(helper).not.toContain('Deno.env.get("DARAJA_TRANSACTION_TYPE")');
    expect(helper).toContain("now.toISOString()");
    expect(helper).toContain("darajaCallbackSignature");
    expect(helper).toContain("verifyDarajaCallbackSignature");
    expect(helper).toContain("https://sandbox.safaricom.co.ke");
    expect(helper).toContain("https://api.safaricom.co.ke");
    expect(helper).not.toMatch(
      /console\.(?:log|info)\([^\n]*(?:consumerKey|consumerSecret|passkey)/i,
    );
  });

  it("keeps the KCB merchant fields in their specified positions", () => {
    expect(helper).toContain('const KCB_BUSINESS_SHORTCODE = "522522"');
    expect(helper).toContain('shortcode !== KCB_BUSINESS_SHORTCODE');
    expect(helper).toContain('PartyB: "522522"');
    expect(helper).toContain('AccountReference: "7718913"');
    expect(helper).toContain("PartyA: args.phone");
    expect(helper).toContain("PhoneNumber: args.phone");
    expect(helper).toContain("BusinessShortCode: config.shortcode");
  });

  it("builds the STK password from the configured shortcode and passkey", () => {
    expect(helper).toContain("base64(`${config.shortcode}${config.passkey}${timestamp}`)");
  });

  it("formats the timestamp in UTC like the working Hotspot Hero implementation", () => {
    expect(darajaTimestamp(new Date("2026-11-14T12:34:56.789Z"))).toBe("20261114123456");
    expect(helper).toContain('console.info("Daraja STK Push accepted"');
  });

  it("refreshes and retries once when Daraja explicitly rejects an access token", () => {
    expect(helper).toContain("isInvalidDarajaAccessToken");
    expect(helper).toContain("invalidateDarajaAccessToken");
    expect(helper).toContain("Daraja rejected the access token; refreshing once");
    expect(helper).toContain("darajaFetchJson");
  });

  it("uses server-owned pricing and reuses an active STK attempt instead of sending duplicates", () => {
    expect(push).toContain(
      '.select("id,name,status,subscription_price_ksh,subscription_plan_days,payment_lock_active,payment_lock_amount_ksh")',
    );
    expect(push).toContain('.in("status", ["initiating", "pending"])');
    expect(push).toContain("An M-Pesa prompt for KSh");
    expect(push).toContain('parsedCallback.searchParams.set("payment_id", payment.id)');
    expect(push).toContain('parsedCallback.searchParams.set("payment_signature"');
    expect(push).toContain('Deno.env.get("MPESA_CALLBACK_URL")');
    expect(push).toContain("/functions/v1/daraja-stk-callback");
    expect(push).not.toContain("payload.amount");
    expect(push).not.toContain("payload.plan_days");
  });

  it("restricts payment verification to an active owner and does not activate from STK Query alone", () => {
    expect(status).toContain("const user = await caller(req)");
    expect(status).toContain('member.role !== "owner"');
    expect(status).toContain('member.employment_status !== "active"');
    expect(status).toContain("await darajaStkQuery(payment.checkout_request_id)");
    expect(status).toContain("The callback is still required for activation.");
    expect(status).not.toContain("finalize_mpesa_subscription_payment");
    expect(config).toContain("[functions.daraja-stk-status]\nverify_jwt = true");
  });

  it("keeps Safaricom result code 4999 pending and recovers older false failures", () => {
    expect(isSafaricomStillProcessing({ ResultCode: "4999" })).toBe(true);
    expect(isSafaricomStillProcessing({ ResponseCode: 4999 })).toBe(true);
    expect(
      isSafaricomStillProcessing({ ResultDesc: "The transaction is still under processing" }),
    ).toBe(true);
    expect(isSafaricomStillProcessing({ ResponseCode: "0", ResultCode: "0" })).toBe(false);
    expect(status).toContain('payment.status === "failed" && Number(payment.result_code) === 4999');
    expect(callback).toContain("isSafaricomStillProcessing(query)");
    expect(callback).toContain("Number(payment.result_code) !== 4999");
    expect(status).toContain('status: "pending"');
    expect(status).toContain("Safaricom is still processing this request.");
  });

  it("correlates the callback with the payment row and verifies with Safaricom before finalizing", () => {
    expect(callback).toContain('callbackParams.get("payment_id")');
    expect(callback).toContain(
      "verifyDarajaCallbackSignature(candidatePaymentId, paymentSignature)",
    );
    expect(callback).toContain("storedCheckoutId !== checkoutId");
    expect(callback).toContain("await darajaStkQuery(checkoutId)");
    expect(callback).toContain('callbackItem(metadata, "Amount")');
    expect(callback).toContain('callbackItem(metadata, "MpesaReceiptNumber")');
    expect(callback).toContain('callbackItem(metadata, "PhoneNumber")');
    expect(callback).toContain("finalize_mpesa_subscription_payment");
    expect(config).toContain("[functions.daraja-stk-callback]\nverify_jwt = false");
  });

  it("transpiles every updated Daraja handler and helper without syntax errors", () => {
    const syntaxErrors = [helper, push, status, callback].flatMap((source) =>
      (
        transpileModule(source, {
          compilerOptions: { module: ModuleKind.ESNext, target: ScriptTarget.ES2022 },
          reportDiagnostics: true,
        }).diagnostics ?? []
      )
        .filter((diagnostic) => diagnostic.category === DiagnosticCategory.Error)
        .map((diagnostic) => flattenDiagnosticMessageText(diagnostic.messageText, "\n")),
    );
    expect(syntaxErrors).toEqual([]);
  });
});
