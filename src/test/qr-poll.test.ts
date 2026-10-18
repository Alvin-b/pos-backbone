import { readFileSync } from 'node:fs';
import { describe, expect, it, vi } from 'vitest';

const source = readFileSync('supabase/functions/poll-access-challenge/index.ts', 'utf8').replace(/^import .*\n/, '');

async function poll(status: string, claim = true) {
  let handler: (request: Request) => Promise<Response> = async () => new Response();
  const createUser = vi.fn();
  const results = [
    { data: { id: 'qr', status, shop_id: status === 'pending' ? null : 'shop', role: 'cashier', expires_at: new Date(Date.now() + 600000).toISOString(), shops: { name: 'Shop', status: 'active' } } },
    { data: claim ? { id: 'qr' } : null },
  ];
  const selects: string[] = [];
  const db = {
    from: () => {
      const chain: Record<string, unknown> = {};
      for (const method of ['eq', 'gt', 'in', 'update']) chain[method] = () => chain;
      chain.select = (columns: string) => { selects.push(columns); return chain; };
      chain.maybeSingle = async () => results.shift();
      return chain;
    },
    auth: { admin: { createUser } },
  };
  new Function('adminClient', 'corsHeaders', 'json', 'sha256', 'syntheticEmail', 'Deno', source)(
    () => db, {}, (body: unknown, code = 200) => new Response(JSON.stringify(body), { status: code }),
    async () => 'hash', () => 'identity', { serve: (fn: typeof handler) => { handler = fn; } },
  );
  const response = await handler(new Request('https://example.test', { method: 'POST', body: JSON.stringify({ token: 'CPR1|test' }) }));
  return { response, body: await response.json(), createUser, selects };
}

describe('QR polling', () => {
  it('returns pending for a valid QR without a business', async () => {
    const result = await poll('pending');
    expect(result.response.status).toBe(200);
    expect(result.body).toEqual({ status: 'pending' });
    expect(result.selects[0]).not.toContain('!inner');
  });
  it('does not provision credentials when another poll owns the claim', async () => {
    const result = await poll('approved', false);
    expect(result.body).toEqual({ status: 'pending' });
    expect(result.createUser).not.toHaveBeenCalled();
  });
  it('does not provision again while processing', async () => {
    const result = await poll('processing');
    expect(result.body).toEqual({ status: 'pending' });
    expect(result.createUser).not.toHaveBeenCalled();
  });
});