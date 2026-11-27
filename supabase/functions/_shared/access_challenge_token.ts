const ACCESS_CHALLENGE_QR_PREFIX = "CPR1|";

export function normalizeAccessChallengeToken(value: string): string {
  const trimmed = value.trim();
  return trimmed.replace(/^CPR1\|/i, "").trim();
}

/**
 * The bare token is canonical. The full prefixed value is retained as a lookup
 * candidate so pending challenges created by older deployments still work.
 */
export function accessChallengeTokenHashInputs(value: string): string[] {
  const normalized = normalizeAccessChallengeToken(value);
  if (!normalized) return [];
  return [normalized, `${ACCESS_CHALLENGE_QR_PREFIX}${normalized}`];
}
