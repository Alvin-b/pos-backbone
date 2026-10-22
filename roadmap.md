# Sign-in deployment
- [ ] Stop starter dining-table seeding and enforce secure table-name validation in the linked backend.
- [ ] Clean only identified legacy starter tables without orders; verify creation, persistence, isolation, and order preservation.
- [ ] Update mobile table-screen integration instructions; mobile screen source is not present in this backend project.
- [ ] Publish the updated Lovable app after checking security.
- [x] Correct QR polling; live creation/pending flow and three regression tests pass.
- [x] Deploy all seven existing sign-in functions; public calls and protected authentication rejection checked.
- [ ] Authenticated enrollment/token checks: requesting user has no matching auth account; requires preview sign-in.
- [ ] Complete counter/profile repair: supplied guide references absent 0021/0022 SQL files; live counter table/column are missing. Requires exact migration SQL and prerequisites from the mobile repository.