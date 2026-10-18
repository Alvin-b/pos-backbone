import { createFileRoute } from "@tanstack/react-router";
import { useCallback, useEffect, useMemo, useState } from "react";
import type { FormEvent } from "react";
import { supabase } from "@/integrations/supabase/client";

export const Route = createFileRoute("/")({
  head: () => ({
    meta: [
      { title: "Counter POS · Superadmin access" },
      { name: "description", content: "Protected rotating Superadmin token console." },
      { property: "og:title", content: "Counter POS · Superadmin access" },
      { property: "og:description", content: "Protected rotating Superadmin token console." },
      { property: "og:type", content: "website" },
      { name: "twitter:card", content: "summary" },
    ],
  }),
  component: SuperadminTokenPage,
});

function SuperadminTokenPage() {
  const [email, setEmail] = useState("");
  const [password, setPassword] = useState("");
  const [session, setSession] =
    useState<Awaited<ReturnType<typeof supabase.auth.getSession>>["data"]["session"]>(null);
  const [token, setToken] = useState<string | null>(null);
  const [expiresAt, setExpiresAt] = useState<string | null>(null);
  const [secondsLeft, setSecondsLeft] = useState(0);
  const [busy, setBusy] = useState(false);
  const [autoRefreshBlocked, setAutoRefreshBlocked] = useState(false);
  const [message, setMessage] = useState<string | null>(null);
  const [error, setError] = useState<string | null>(null);

  const expiresLabel = useMemo(() => {
    const minutes = Math.floor(secondsLeft / 60);
    const seconds = String(secondsLeft % 60).padStart(2, "0");
    return `${minutes}:${seconds}`;
  }, [secondsLeft]);

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
    if (!expiresAt) return;
    const update = () =>
      setSecondsLeft(Math.max(0, Math.floor((new Date(expiresAt).getTime() - Date.now()) / 1000)));
    update();
    const timer = window.setInterval(update, 1000);
    return () => window.clearInterval(timer);
  }, [expiresAt]);

  async function signIn(event: FormEvent) {
    event.preventDefault();
    setBusy(true);
    setError(null);
    setMessage(null);
    const result = await supabase.auth.signInWithPassword({ email: email.trim(), password });
    if (result.error) setError(result.error.message);
    else {
      setAutoRefreshBlocked(false);
      setMessage("Signed in. A temporary Superadmin token will be generated automatically.");
    }
    setBusy(false);
  }

  const issueToken = useCallback(async () => {
    setBusy(true);
    setError(null);
    setMessage(null);
    setAutoRefreshBlocked(false);
    const result = await supabase.functions.invoke("issue-superadmin-token", { body: {} });
    if (result.error) {
      setError(result.error.message || "Only a platform administrator can issue this token.");
      setToken(null);
      setExpiresAt(null);
      setAutoRefreshBlocked(true);
    } else {
      setToken(result.data?.token ?? null);
      setExpiresAt(result.data?.expires_at ?? null);
      setMessage("Token issued. Copy it privately before it expires.");
    }
    setBusy(false);
  }, []);

  useEffect(() => {
    if (!session || busy || autoRefreshBlocked || (expiresAt && secondsLeft > 0)) return;
    void issueToken();
  }, [autoRefreshBlocked, busy, expiresAt, issueToken, secondsLeft, session]);

  async function signOut() {
    await supabase.auth.signOut();
    setToken(null);
    setExpiresAt(null);
    setMessage(null);
  }

  if (!session) {
    return (
      <main className="flex min-h-screen items-center justify-center bg-slate-950 px-4 text-white">
        <form
          onSubmit={signIn}
          className="w-full max-w-md space-y-5 rounded-2xl border border-slate-800 bg-slate-900 p-7 shadow-2xl"
        >
          <div>
            <p className="text-sm font-medium text-cyan-300">COUNTER POS</p>
            <h1 className="mt-2 text-3xl font-semibold">Superadmin access</h1>
            <p className="mt-2 text-sm text-slate-400">
              Sign in with the protected platform-admin account to issue a 10-minute mobile access
              token.
            </p>
          </div>
          <label className="block text-sm text-slate-300">
            Email
            <input
              className="mt-2 w-full rounded-lg border border-slate-700 bg-slate-950 px-3 py-3 text-white"
              type="email"
              value={email}
              onChange={(event) => setEmail(event.target.value)}
              required
            />
          </label>
          <label className="block text-sm text-slate-300">
            Password
            <input
              className="mt-2 w-full rounded-lg border border-slate-700 bg-slate-950 px-3 py-3 text-white"
              type="password"
              value={password}
              onChange={(event) => setPassword(event.target.value)}
              required
            />
          </label>
          <button
            disabled={busy}
            className="w-full rounded-lg bg-cyan-400 px-4 py-3 font-semibold text-slate-950 disabled:opacity-50"
          >
            {busy ? "Signing in…" : "Sign in"}
          </button>
          {error && <p className="text-sm text-red-300">{error}</p>}
        </form>
      </main>
    );
  }

  return (
    <main className="min-h-screen bg-slate-950 px-4 py-10 text-white">
      <div className="mx-auto max-w-2xl space-y-6">
        <header className="flex items-start justify-between gap-4">
          <div>
            <p className="text-sm font-medium text-cyan-300">
              COUNTER POS · LOVABLE CONTROL CENTER
            </p>
            <h1 className="mt-2 text-3xl font-semibold">Superadmin mobile access</h1>
            <p className="mt-2 text-sm text-slate-400">
              Issue a short-lived token for the Android Superadmin interface. The token does not
              grant business-owner or employee access.
            </p>
          </div>
          <button
            onClick={signOut}
            className="rounded-lg border border-slate-700 px-3 py-2 text-sm text-slate-300"
          >
            Sign out
          </button>
        </header>
        <section className="rounded-2xl border border-slate-800 bg-slate-900 p-7 shadow-2xl">
          <div className="flex items-center justify-between">
            <div>
              <h2 className="text-xl font-semibold">Current token</h2>
              <p className="mt-1 text-sm text-slate-400">
                Each issue replaces the previous token and is valid for 10 minutes.
              </p>
            </div>
            <span className="rounded-full bg-emerald-950 px-3 py-1 text-sm text-emerald-300">
              {secondsLeft > 0 ? `${expiresLabel} left` : "Not issued"}
            </span>
          </div>
          <div className="mt-6 rounded-xl border border-dashed border-slate-700 bg-slate-950 p-5 text-center">
            <code className="break-all text-lg tracking-wider text-cyan-200">
              {token ?? "No active token"}
            </code>
          </div>
          <div className="mt-5 flex flex-wrap gap-3">
            <button
              onClick={issueToken}
              disabled={busy}
              className="rounded-lg bg-cyan-400 px-4 py-3 font-semibold text-slate-950 disabled:opacity-50"
            >
              {busy
                ? "Issuing…"
                : token && secondsLeft > 0
                  ? "Rotate token now"
                  : "Generate 10-minute token"}
            </button>
            <button
              onClick={() => token && navigator.clipboard.writeText(token)}
              disabled={!token || secondsLeft === 0}
              className="rounded-lg border border-slate-700 px-4 py-3 text-slate-200 disabled:opacity-50"
            >
              Copy token
            </button>
          </div>
          <p className="mt-5 text-xs text-amber-300">
            Treat this token like a password. Do not post it publicly. It is stored server-side only
            as a hash and expires automatically.
          </p>
          {message && <p className="mt-4 text-sm text-emerald-300">{message}</p>}
          {error && <p className="mt-4 text-sm text-red-300">{error}</p>}
        </section>
      </div>
    </main>
  );
}
