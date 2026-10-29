import { adminClient, corsHeaders, json, sha256, syntheticEmail } from "../_shared/access.ts";

const CLAIM_RECOVERY_MS = 4 * 60 * 1000;

Deno.serve(async (req) => {
  if (req.method === "OPTIONS") return new Response("ok", { headers: corsHeaders });
  if (req.method !== "POST") return json({ error: "method_not_allowed" }, 405);

  const body = await req.json().catch(() => ({}));
  const token = String(body.token ?? "").trim();
  if (!token) return json({ error: "token_required" }, 400);

  const db = adminClient();
  const hash = await sha256(token);
  const { data: challenge, error: readError } = await db
    .from("access_challenges")
    // A pending challenge has no shop yet; an inner join would hide a valid QR.
    .select("id,status,shop_id,role,device_key_hash,expires_at,processing_at,shops(name,status)")
    .eq("token_hash", hash)
    .maybeSingle();
  if (readError) return json({ error: "could_not_read_qr" }, 500);
  if (!challenge) return json({ error: "qr_not_found" }, 404);

  const now = Date.now();
  const expired = new Date(challenge.expires_at).getTime() <= now;
  if (expired && ["pending", "approved"].includes(challenge.status)) {
    await db
      .from("access_challenges")
      .update({ status: "expired", processing_at: null })
      .eq("id", challenge.id)
      .eq("status", challenge.status);
    return json({ status: "expired" }, 401);
  }
  if (challenge.status === "pending") return json({ status: "pending" });

  if (challenge.status === "processing") {
    const claimedAt = challenge.processing_at ? new Date(challenge.processing_at).getTime() : 0;
    if (claimedAt > now - CLAIM_RECOVERY_MS) return json({ status: "pending" });
    if (expired) {
      await db
        .from("access_challenges")
        .update({ status: "expired", processing_at: null })
        .eq("id", challenge.id)
        .eq("status", "processing");
      return json({ status: "expired" }, 401);
    }

    // Recover a crashed processor after a bounded lease. The conditional update
    // ensures only one poller can reclaim the stale processing state.
    let recovery = db
      .from("access_challenges")
      .update({ status: "approved", processing_at: null })
      .eq("id", challenge.id)
      .eq("status", "processing");
    recovery = claimedAt > 0
      ? recovery.lte("processing_at", new Date(now - CLAIM_RECOVERY_MS).toISOString())
      : recovery.is("processing_at", null);
    const { data: recovered, error: recoverError } = await recovery.select("id").maybeSingle();
    if (recoverError) return json({ error: "could_not_recover_qr" }, 500);
    if (!recovered) return json({ status: "pending" });
  }

  if (challenge.status !== "approved" && challenge.status !== "processing") {
    return json({ error: "qr_expired_or_used" }, 401);
  }
  if (!challenge.shop_id || !challenge.role) return json({ error: "invalid_approved_qr" }, 409);
  const shop = Array.isArray(challenge.shops) ? challenge.shops[0] : challenge.shops;
  if (!shop || shop.status !== "active") return json({ error: "business_not_active" }, 409);

  // Claim only an approved, unexpired row; concurrent pollers cannot both
  // create identities or return the one-time credentials.
  const claimTime = new Date().toISOString();
  const { data: claim, error: claimError } = await db
    .from("access_challenges")
    .update({ status: "processing", processing_at: claimTime })
    .eq("id", challenge.id)
    .eq("status", "approved")
    .gt("expires_at", claimTime)
    .select("id")
    .maybeSingle();
  if (claimError) return json({ error: "could_not_claim_qr" }, 500);
  if (!claim) return json({ status: "pending" });

  const releaseClaim = async () => {
    await db
      .from("access_challenges")
      .update({ status: "approved", processing_at: null })
      .eq("id", challenge.id)
      .eq("status", "processing")
      .eq("processing_at", claimTime);
  };

  const deviceKeyHash = String(challenge.device_key_hash ?? "").trim();
  let userId: string | undefined;
  let email = "";
  if (deviceKeyHash) {
    const { data: identity, error: identityError } = await db
      .from("access_device_identities")
      .select("user_id")
      .eq("device_key_hash", deviceKeyHash)
      .eq("shop_id", challenge.shop_id)
      .eq("role", challenge.role)
      .maybeSingle();
    if (identityError) {
      await releaseClaim();
      return json({ error: "could_not_find_identity" }, 500);
    }
    if (identity?.user_id) {
      const { data: existingUser, error: existingUserError } = await db.auth.admin.getUserById(identity.user_id);
      if (existingUserError || !existingUser.user) {
        await releaseClaim();
        return json({ error: "could_not_find_identity" }, 500);
      }
      userId = existingUser.user.id;
      email = existingUser.user.email ?? syntheticEmail(hash);
      const { error: rotateError } = await db.auth.admin.updateUserById(userId, {
        password: token,
        user_metadata: {
          ...(existingUser.user.user_metadata ?? {}),
          counterpos_access: true,
          business_id: challenge.shop_id,
          role: challenge.role,
        },
      });
      if (rotateError) {
        await releaseClaim();
        return json({ error: "could_not_rotate_identity" }, 500);
      }
    }
  }
  if (!userId) {
    email = syntheticEmail(hash);
    const { data: created, error: createError } = await db.auth.admin.createUser({
      email,
      password: token,
      email_confirm: true,
      user_metadata: { counterpos_access: true, business_id: challenge.shop_id, role: challenge.role },
    });
    if (createError && !createError.message.toLowerCase().includes("already registered")) {
      await releaseClaim();
      return json({ error: "could_not_create_identity" }, 500);
    }
    userId = created.user?.id;
    if (!userId) {
      const { data: existing, error: listError } = await db.auth.admin.listUsers({ page: 1, perPage: 1000 });
      if (listError) {
        await releaseClaim();
        return json({ error: "could_not_find_identity" }, 500);
      }
      userId = existing.users.find((user) => user.email === email)?.id;
    }
  }
  if (!userId) {
    await releaseClaim();
    return json({ error: "identity_not_created" }, 500);
  }

  const { data: existingMember, error: memberLookupError } = await db
    .from("shop_members")
    .select("employment_status")
    .eq("shop_id", challenge.shop_id)
    .eq("user_id", userId)
    .maybeSingle();
  if (memberLookupError) {
    await releaseClaim();
    return json({ error: "could_not_attach_member" }, 500);
  }
  if (existingMember && existingMember.employment_status !== "active") {
    await releaseClaim();
    return json({ error: "employee_inactive" }, 403);
  }

  // Never reactivate an existing suspended/terminated membership on a retry.
  const { error: memberError } = await db.from("shop_members").upsert(
    { shop_id: challenge.shop_id, user_id: userId, role: challenge.role, employment_status: "active" },
    { onConflict: "shop_id,user_id", ignoreDuplicates: true },
  );
  if (memberError) {
    await releaseClaim();
    return json({ error: "could_not_attach_member" }, 500);
  }

  const { data: activeMember, error: activeMemberError } = await db
    .from("shop_members")
    .select("employment_status")
    .eq("shop_id", challenge.shop_id)
    .eq("user_id", userId)
    .maybeSingle();
  if (activeMemberError) {
    await releaseClaim();
    return json({ error: "could_not_verify_member" }, 500);
  }
  if (!activeMember || activeMember.employment_status !== "active") {
    await releaseClaim();
    return json({ error: "employee_inactive" }, 403);
  }

  if (deviceKeyHash) {
    const { error: identityWriteError } = await db.from("access_device_identities").upsert({
      device_key_hash: deviceKeyHash,
      shop_id: challenge.shop_id,
      user_id: userId,
      role: challenge.role,
      updated_at: new Date().toISOString(),
    }, { onConflict: "device_key_hash" });
    if (identityWriteError) {
      await releaseClaim();
      return json({ error: "could_not_save_identity" }, 500);
    }
  }

  const { data: consumed, error: consumeError } = await db
    .from("access_challenges")
    .update({ status: "consumed", processing_at: null, consumed_at: new Date().toISOString(), consumed_by: userId })
    .eq("id", challenge.id)
    .eq("status", "processing")
    .eq("processing_at", claimTime)
    .select("id")
    .maybeSingle();
  if (consumeError) {
    await releaseClaim();
    return json({ error: "could_not_consume_qr" }, 500);
  }
  if (!consumed) return json({ error: "qr_claim_lost" }, 409);

  return json({ status: "approved", email, password: token, business_id: challenge.shop_id, business_name: shop.name, role: challenge.role });
});
