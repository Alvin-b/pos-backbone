# Daraja STK Push test flow

The control-center home page now includes a **Daraja STK Push** test panel. It is available only after signing in with a user listed in `public.platform_admins`.

The browser sends only the test phone number, amount, reference, and transaction type. The Daraja consumer key, consumer secret, shortcode, passkey, environment, and callback URL are read only by the Supabase Edge Function.

## Configure Supabase secrets

Set these as Supabase Edge Function secrets. Never put them in `.env`, Android resources, the browser bundle, GitHub, or chat.

```text
DARAJA_ENVIRONMENT=sandbox
DARAJA_CONSUMER_KEY=...
DARAJA_CONSUMER_SECRET=...
DARAJA_SHORTCODE=...
DARAJA_PASSKEY=...
DARAJA_PARTY_B=...
DARAJA_CALLBACK_URL=https://pvcqfoycrqtnirbwtccm.supabase.co/functions/v1/daraja-stk-callback
```

`DARAJA_PARTY_B` is optional and defaults to `DARAJA_SHORTCODE`. Use `CustomerPayBillOnline` for a Paybill and `CustomerBuyGoodsOnline` for a Till. For production testing, change `DARAJA_ENVIRONMENT` to `production` only after the sandbox flow has been verified and the production callback URL, shortcode, passkey, and credentials are ready.

## Deploy

Deploy both new functions after applying the current repository changes:

```bash
supabase functions deploy test-daraja-stk-push --no-verify-jwt
supabase functions deploy daraja-stk-callback --no-verify-jwt
```

The functions deliberately use custom authentication inside `test-daraja-stk-push`: the caller must present a valid Supabase user access token and must be in `public.platform_admins`. The callback has JWT verification disabled because Safaricom calls it directly.

## Interpret the result

A successful STK Push response means Daraja accepted the request and returned a `CheckoutRequestID`; it does **not** mean that the customer has paid. During this test phase, the callback acknowledges Safaricom and logs only the merchant request ID, checkout request ID, result code, and result description. The next production step is to persist the callback against a sale/order and make the sale idempotently paid only when `ResultCode` is `0`.

The panel displays the structured response when Daraja rejects a request. Common causes are incorrect sandbox credentials, a mismatched shortcode/passkey pair, an invalid phone number, a callback URL that Safaricom cannot reach, or using a Paybill/Till transaction type with the wrong `PartyB`.
