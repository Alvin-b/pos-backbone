import { readFileSync } from "node:fs";
import { describe, expect, it } from "vitest";

const migration = readFileSync(
  "drizzle/migrations/0030_employee_profiles_and_recovery.sql",
  "utf8",
);
const recoveryFunction = readFileSync(
  "supabase/functions/create-employee-recovery-pass/index.ts",
  "utf8",
);
const redemptionFunction = readFileSync("supabase/functions/redeem-access-pass/index.ts", "utf8");
const config = readFileSync("supabase/config.toml", "utf8");
const recoveryBranch =
  redemptionFunction.split("if (!pass) {")[1]?.split("\n  }\n  if (pass.redeemed_at")[0] ?? "";

describe("employee profile and recovery security contract", () => {
  it("keeps staff display names scoped to the business membership", () => {
    expect(migration).toContain("ALTER TABLE public.shop_members");
    expect(migration).toContain("ADD COLUMN IF NOT EXISTS display_name text");
    expect(migration).toContain("FUNCTION public.set_employee_display_name");
    expect(migration).toContain("public.is_shop_manager(_shop)");
    expect(migration).toContain("target_role = 'owner'");
    expect(migration).toContain("'employee_display_name_changed'");
  });

  it("stores only hashed, tenant-bound recovery codes and restricts issuance to active owners", () => {
    expect(migration).toContain("CREATE TABLE IF NOT EXISTS public.employee_recovery_passes");
    expect(migration).toContain("pass_hash text NOT NULL UNIQUE CHECK (length(pass_hash) = 64)");
    expect(migration).toContain(
      "REVOKE ALL ON public.employee_recovery_passes FROM PUBLIC, anon, authenticated",
    );
    expect(migration).toContain("role = 'owner' AND employment_status = 'active'");
    expect(migration).toContain("'employee_recovery_issued'");
    expect(migration).toContain("AFTER UPDATE OF employment_status OR DELETE ON public.shop_members");
    expect(migration).toContain("SET revoked_at = now()");
    expect(recoveryFunction).toContain("issue_employee_recovery_pass");
    expect(recoveryFunction).toContain("_actor: user.id");
    expect(config).toContain("[functions.create-employee-recovery-pass]\nverify_jwt = true");
  });

  it("claims once with a lease, rotates the existing identity, and returns a session rather than a reusable code password", () => {
    expect(migration).toContain("FOR UPDATE");
    expect(migration).toContain("'employee_recovery_in_progress'");
    expect(migration).toContain("claim_expires_at = now() + interval '3 minutes'");
    expect(migration).toContain("FUNCTION public.complete_employee_recovery_pass");
    expect(migration).toContain("'employee_recovery_completed'");
    expect(redemptionFunction).toMatch(/updateUserById\(claim\.user_id,\s*\{\s*password:\s*rotatedPassword/);
    expect(redemptionFunction).toContain("signInWithPassword({");
    expect(redemptionFunction).toContain("email: identity.email");
    expect(redemptionFunction).toContain("_claim_token: claim.claim_token");
    expect(redemptionFunction).toContain("access_token: signedIn.session.access_token");
    expect(recoveryBranch).not.toMatch(/password:\s*passkey/);
  });
});
