import { readFileSync } from 'node:fs';
import { describe, expect, it, vi } from 'vitest';
import { ModuleKind, ScriptTarget, transpileModule } from 'typescript';

type EdgeHandler = (request: Request) => Promise<Response>;
type MockDbOptions = {
  rows?: Record<string, unknown>;
  createUser?: ReturnType<typeof vi.fn>;
  rpc?: ReturnType<typeof vi.fn>;
};

function makeDb(options: MockDbOptions = {}) {
  const inserts: Array<{ table: string; row: unknown }> = [];
  const updates: Array<{ table: string; row: unknown }> = [];
  const from = (table: string) => {
    let updatePayload: unknown = null;
    const chain: Record<string, unknown> = {};
    chain.select = () => chain;
    chain.eq = () => chain;
    chain.update = (row: unknown) => {
      updatePayload = row;
      updates.push({ table, row });
      return chain;
    };
    chain.insert = async (row: unknown) => {
      inserts.push({ table, row });
      return { error: null };
    };
    chain.maybeSingle = async () => ({
      data: updatePayload !== null && table === 'access_challenges'
        ? { id: 'challenge-1' }
        : options.rows?.[table] ?? null,
      error: null,
    });
    return chain;
  };
  return {
    from,
    inserts,
    updates,
    auth: { admin: { createUser: options.createUser ?? vi.fn(), listUsers: vi.fn() } },
    rpc: options.rpc ?? vi.fn(),
  };
}

function edgeHandler(file: string, bindings: Record<string, unknown>): EdgeHandler {
  const source = readFileSync(file, 'utf8');
  const javascript = transpileModule(source, {
    compilerOptions: { module: ModuleKind.ESNext, target: ScriptTarget.ES2022 },
  }).outputText.replace(/^import .*;\s*$/gm, '');
  let handler: EdgeHandler | undefined;
  const deno = { serve: (registered: EdgeHandler) => { handler = registered; } };
  const names = [...Object.keys(bindings), 'Deno'];
  const values = [...Object.values(bindings), deno];
  new Function(...names, javascript)(...values);
  if (!handler) throw new Error(`Edge function did not register a handler: ${file}`);
  return handler;
}

function responseJson(body: unknown, status = 200) {
  return new Response(JSON.stringify(body), { status, headers: { 'Content-Type': 'application/json' } });
}

function request(body: Record<string, unknown>) {
  return new Request('https://counterpos.test/function', {
    method: 'POST',
    headers: { 'Content-Type': 'application/json', Authorization: 'Bearer owner-token' },
    body: JSON.stringify(body),
  });
}

const corsHeaders = {};
const json = responseJson;
const caller = vi.fn(async () => ({ id: 'owner-1' }));
const sha256 = vi.fn(async () => 'pass-hash');
const createPasskey = vi.fn(() => 'ABCD-EFGH-JKLM-NPQR-STUV');
const syntheticEmail = vi.fn(() => 'cp-test@access.counterpos.invalid');

function bindings(adminClient: () => unknown) {
  return { adminClient, caller, corsHeaders, json, sha256, createPasskey, syntheticEmail };
}

const passFunction = 'supabase/functions/create-access-pass/index.ts';
const approveFunction = 'supabase/functions/approve-access-challenge/index.ts';
const redeemFunction = 'supabase/functions/redeem-access-pass/index.ts';

describe('owner Waiter enrollment', () => {
  it('issues a one-time cashier/Waiter passkey for an active owner', async () => {
    const db = makeDb({ rows: {
      platform_admins: null,
      shop_members: { role: 'owner', employment_status: 'active' },
      shops: { id: 'shop-1', name: 'Test Bar', status: 'active' },
    } });
    const handler = edgeHandler(passFunction, bindings(() => db));
    const response = await handler(request({ shop_id: 'shop-1', role: 'cashier' }));
    const body = await response.json();

    expect(response.status).toBe(200);
    expect(body).toMatchObject({ business_id: 'shop-1', role: 'cashier', passkey: 'ABCD-EFGH-JKLM-NPQR-STUV' });
    expect(db.inserts).toHaveLength(1);
    expect(db.inserts[0]).toMatchObject({ table: 'access_passes', row: { shop_id: 'shop-1', role: 'cashier', pass_hash: 'pass-hash' } });
  });

  it('rejects unsupported roles before creating an employee passkey', async () => {
    const db = makeDb({ rows: {
      platform_admins: null,
      shop_members: { role: 'owner', employment_status: 'active' },
    } });
    const handler = edgeHandler(passFunction, bindings(() => db));
    const response = await handler(request({ shop_id: 'shop-1', role: 'manager' }));

    expect(response.status).toBe(400);
    expect(await response.json()).toMatchObject({ error: 'only_waiter_role_supported' });
    expect(db.inserts).toHaveLength(0);
  });

  it('lets an active owner approve a waiter phone QR challenge', async () => {
    const db = makeDb({ rows: {
      platform_admins: null,
      shop_members: { role: 'owner', employment_status: 'active' },
      shops: { id: 'shop-1', status: 'active' },
      access_challenges: { id: 'challenge-1', status: 'pending', expires_at: new Date(Date.now() + 600_000).toISOString() },
    } });
    const handler = edgeHandler(approveFunction, bindings(() => db));
    const response = await handler(request({ token: 'CPR1|valid-test-token', shop_id: 'shop-1', role: 'cashier' }));

    expect(response.status).toBe(200);
    expect(await response.json()).toEqual({ approved: true });
    expect(db.updates).toContainEqual({ table: 'access_challenges', row: expect.objectContaining({ status: 'approved', shop_id: 'shop-1', role: 'cashier' }) });
  });

  it('does not allow a non-owner employee to approve a waiter phone QR', async () => {
    const db = makeDb({ rows: {
      platform_admins: null,
      shop_members: { role: 'cashier', employment_status: 'active' },
    } });
    const handler = edgeHandler(approveFunction, bindings(() => db));
    const response = await handler(request({ token: 'CPR1|valid-test-token', shop_id: 'shop-1', role: 'cashier' }));

    expect(response.status).toBe(403);
    expect(await response.json()).toMatchObject({ error: 'forbidden' });
    expect(db.updates).toHaveLength(0);
  });

  it('redeems lower-case manual passkey entry with the canonical password', async () => {
    const createUser = vi.fn(async () => ({ data: { user: { id: 'waiter-1' } }, error: null }));
    const rpc = vi.fn(async () => ({ data: { business_id: 'shop-1' }, error: null }));
    const db = makeDb({
      rows: { access_passes: {
        id: 'pass-1', shop_id: 'shop-1', role: 'cashier',
        expires_at: new Date(Date.now() + 600_000).toISOString(),
        redeemed_at: null, revoked_at: null, shops: { name: 'Test Bar', status: 'active' },
      } },
      createUser,
      rpc,
    });
    const handler = edgeHandler(redeemFunction, bindings(() => db));
    const response = await handler(request({ passkey: 'abcd-efgh-jklm-npqr-stuv' }));

    expect(response.status).toBe(200);
    expect(createUser).toHaveBeenCalledWith(expect.objectContaining({ password: 'ABCD-EFGH-JKLM-NPQR-STUV' }));
    expect(await response.json()).toMatchObject({ status: 'redeemed', role: 'cashier', password: 'ABCD-EFGH-JKLM-NPQR-STUV' });
    expect(rpc).toHaveBeenCalledWith('redeem_access_pass_atomic', { _pass_hash: 'pass-hash', _user: 'waiter-1' });
  });
});
