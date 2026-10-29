import { adminClient, corsHeaders, json, sha256, createPasskey } from "../_shared/access.ts";

Deno.serve(async (req) => {
  if (req.method === "OPTIONS") return new Response("ok", { headers: corsHeaders });
  if (req.method !== "POST") return json({ error: "method_not_allowed" }, 405);
  const body = await req.json().catch(() => ({}));
  const deviceId = String(body.device_id ?? "").trim();
  if (deviceId.length > 200) return json({ error: "invalid_device_id" }, 400);
  const token = `CPR1|${createPasskey()}-${createPasskey()}`;
  const db = adminClient();
  const row: Record<string, string> = { token_hash: await sha256(token) };
  if (deviceId) row.device_key_hash = await sha256(`counterpos-device:${deviceId}`);
  const { error } = await db.from("access_challenges").insert(row);
  if (error) return json({ error: "could_not_create_qr_challenge" }, 500);
  return json({ token, expires_in_seconds: 600 });
});
