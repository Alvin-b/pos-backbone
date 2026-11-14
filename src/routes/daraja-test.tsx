import { createFileRoute } from "@tanstack/react-router";
import { useEffect, useState } from "react";
import type { FormEvent } from "react";
import { supabase } from "@/integrations/supabase/client";

export const Route = createFileRoute("/daraja-test")({
  head: () => ({ meta: [{ title: "Counter POS · M-Pesa STK test" }] }),
  component: DarajaTestPage,
});

type Session = Awaited<ReturnType<typeof supabase.auth.getSession>>["data"]["session"];
type Membership = {
  shop_id: string;
  shop_name: string;
  role: string;
  status: string;
  employment_status: string;
};
type Result = Record<string, unknown>;

function DarajaTestPage() {
  const [session, setSession] = useState<Session>(null);
  const [email, setEmail] = useState("");
  const [password, setPassword] = useState("");
  const [businesses, setBusinesses] = useState<Membership[]>([]);
  const [shopId, setShopId] = useState("");
  const [phone, setPhone] = useState("");
  const [busy, setBusy] = useState(false);
  const [loadingBusinesses, setLoadingBusinesses] = useState(false);
  const [error, setError] = useState<string | null>(null);
  const [result, setResult] = useState<Result | null>(null);
  const [checkoutId, setCheckoutId] = useState("");

  useEffect(() => {
    let mounted = true;
    supabase.auth.getSession().then(({ data }) => {
      if (mounted) setSession(data.session);
    });
    const { data: listener } = supabase.auth.onAuthStateChange((_event, next) => {
      if (mounted) setSession(next);
    });
    return () => {
      mounted = false;
      listener.subscription.unsubscribe();
    };
  }, []);

  useEffect(() => {
    if (!session) return;
    let mounted = true;
    setLoadingBusinesses(true);
    setError(null);
    supabase.rpc("my_account").then(({ data, error: accountError }) => {
      if (!mounted) return;
      if (accountError) {
        setError(accountError.message);
      } else {
        const account = data as { memberships?: Membership[] } | null;
        const owners = (account?.memberships ?? []).filter(
          (membership) =>
            membership.role.toLowerCase() === "owner" &&
            membership.status === "active" &&
            membership.employment_status === "active",
        );
        setBusinesses(owners);
        setShopId((current) => current || owners[0]?.shop_id || "");
        if (owners.length === 0) setError("No active owner business was found for this account.");
      }
      setLoadingBusinesses(false);
    });
    return () => {
      mounted = false;
    };
  }, [session]);

  async function signIn(event: FormEvent) {
    event.preventDefault();
    setBusy(true);
    setError(null);
    const { error: signInError } = await supabase.auth.signInWithPassword({
      email: email.trim(),
      password,
    });
    if (signInError) setError(signInError.message);
    setBusy(false);
  }

  async function initiate(event: FormEvent) {
    event.preventDefault();
    setBusy(true);
    setResult(null);
    setCheckoutId("");
    const { data, error: invokeError } = await supabase.functions.invoke("daraja-stk-push", {
      body: { shop_id: shopId, phone_number: phone.trim() },
    });
    if (invokeError) {
      const context = (invokeError as { context?: Response }).context;
      let response: Result = { success: false, error: invokeError.message };
      if (context) {
        try {
          response = await context.clone().json();
        } catch {
          // Keep the SDK error when the function did not return JSON.
        }
      }
      setResult(response);
    } else {
      const response = (data ?? { success: false, error: "empty_response" }) as Result;
      setResult(response);
      if (typeof response["checkout_request_id"] === "string") {
        setCheckoutId(response["checkout_request_id"] as string);
      }
    }
    setBusy(false);
  }

  async function checkStatus() {
    if (!checkoutId) return;
    setBusy(true);
    const { data, error: invokeError } = await supabase.functions.invoke("daraja-stk-status", {
      body: { shop_id: shopId, checkout_request_id: checkoutId },
    });
    if (invokeError) {
      setResult({ success: false, error: invokeError.message });
    } else {
      setResult((data ?? { success: false, error: "empty_response" }) as Result);
    }
    setBusy(false);
  }

  if (!session) {
    return (
      <main className="flex min-h-screen items-center justify-center bg-slate-950 px-4 text-white">
        <form
          onSubmit={signIn}
          className="w-full max-w-md space-y-4 rounded-2xl border border-slate-800 bg-slate-900 p-6 shadow-2xl"
        >
          <p className="text-xs font-semibold tracking-[0.2em] text-emerald-400">COUNTER POS</p>
          <h1 className="text-2xl font-semibold">Business sign-in</h1>
          <p className="text-sm text-slate-400">
            Sign in as the active business owner to test the production Daraja function.
          </p>
          <input
            className="w-full rounded-lg border border-slate-700 bg-slate-950 px-3 py-3 text-white"
            type="email"
            placeholder="Business email"
            value={email}
            onChange={(event) => setEmail(event.target.value)}
            required
          />
          <input
            className="w-full rounded-lg border border-slate-700 bg-slate-950 px-3 py-3 text-white"
            type="password"
            placeholder="Password"
            value={password}
            onChange={(event) => setPassword(event.target.value)}
            required
          />
          <button
            disabled={busy}
            className="w-full rounded-lg bg-emerald-500 px-4 py-3 font-semibold text-white disabled:opacity-50"
          >
            {busy ? "Signing in…" : "Sign in"}
          </button>
          {error && <p className="text-sm text-red-300">{error}</p>}
        </form>
      </main>
    );
  }

  const successful = result?.["success"] === true;
  const selectedBusiness = businesses.find((business) => business.shop_id === shopId);

  return (
    <main className="flex min-h-screen items-center justify-center bg-slate-950 px-4 text-white">
      <section className="w-full max-w-md rounded-2xl border border-slate-800 bg-slate-900 p-6 shadow-2xl">
        <div className="flex items-start justify-between gap-4">
          <div>
            <p className="text-xs font-semibold tracking-[0.2em] text-emerald-400">COUNTER POS</p>
            <h1 className="mt-2 text-2xl font-semibold">M-Pesa STK Push test</h1>
          </div>
          <button
            onClick={() => supabase.auth.signOut()}
            className="text-sm text-slate-400 hover:text-white"
          >
            Sign out
          </button>
        </div>
        <p className="mt-2 text-sm text-slate-400">
          Business: {loadingBusinesses ? "Loading…" : (selectedBusiness?.shop_name ?? "Not found")}
        </p>
        <form onSubmit={initiate} className="mt-6 space-y-4">
          <label className="block text-sm text-slate-300">
            M-Pesa phone number
            <input
              className="mt-2 w-full rounded-lg border border-slate-700 bg-slate-950 px-3 py-3 text-white"
              value={phone}
              onChange={(event) => setPhone(event.target.value)}
              placeholder="0712345678"
              inputMode="tel"
              required
            />
          </label>
          <button
            disabled={busy || !shopId || businesses.length === 0}
            className="w-full rounded-lg bg-emerald-500 px-4 py-3 font-semibold text-white disabled:opacity-50"
          >
            {busy ? "Initiating…" : "Initiate STK Push"}
          </button>
        </form>
        {error && (
          <p className="mt-4 rounded-lg border border-red-900 bg-red-950/30 p-3 text-sm text-red-200">
            {error}
          </p>
        )}
        {result && (
          <pre
            className={`mt-5 max-h-80 overflow-auto rounded-xl border p-4 text-xs leading-5 ${successful ? "border-emerald-900 bg-emerald-950/30 text-emerald-200" : "border-red-900 bg-red-950/30 text-red-200"}`}
          >
            {JSON.stringify(result, null, 2)}
          </pre>
        )}
        {checkoutId && (
          <button
            type="button"
            onClick={checkStatus}
            disabled={busy}
            className="mt-3 w-full rounded-lg border border-slate-700 px-4 py-3 font-semibold text-slate-200 hover:border-emerald-500 disabled:opacity-50"
          >
            {busy ? "Checking…" : "Check STK Status"}
          </button>
        )}
      </section>
    </main>
  );
}
