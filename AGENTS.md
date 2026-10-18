<!-- LOVABLE:BEGIN -->
> [!IMPORTANT]
> This project is connected to [Lovable](https://lovable.dev). Avoid rewriting
> published git history — force pushing, or rebasing/amending/squashing commits
> that are already pushed — as it rewrites history on Lovable's side and the
> user will likely lose their project history.
>
> Commits you push to the connected branch sync back to Lovable and show up in
> the editor, so keep the branch in a working state.
<!-- LOVABLE:END -->

## Architecture
- Backend-only project: the mobile app talks directly to Lovable Cloud (auth, PostgREST tables, RPC functions, storage). Why: no web UI is required; RLS + SECURITY DEFINER RPCs keep stock/sales changes atomic and shop-scoped.
- All stock-changing actions (sell, undo, receive, register, add from catalog) go through RPC functions, never direct table writes. Why: keeps stock and the sales/receipt ledgers consistent.
- api.md at the project root is the mobile integration contract; update it whenever schema or RPCs change.
- Existing QR polling claims an approved challenge with a conditional database update before provisioning; only the claiming request may return credentials. Why: concurrent anonymous polls must not redeem the same challenge twice.
