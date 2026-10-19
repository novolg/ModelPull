# Plan: ModelPull — resumable, verified downloads for Hugging Face + Civitai

> Product name: **ModelPull** (decided 2026-10-19). Code, paths and products renamed 2026-10-30; names below are the current ones.

## Goal
Download 15+ GB files over an unstable link + NordVPN (IP changes) without restarting from zero. Native macOS app, minimal dark UI, tokens set in app.

## Root cause of "restart from zero"
- HF / Civitai redirect to short-lived signed CDN URLs (sometimes IP-bound).
- After drop / IP change the old URL is dead → browser starts over.
- Second problem found in testing: on a slow link (~80 KB/s) any whole-chunk approach never finishes a chunk before the next drop.

## Fix
1. Store the permanent source link. On every failure resolve a fresh signed link.
2. HTTP `Range` from the exact byte on disk.
3. Stream bytes straight into a sparse `.dlpart` file; checkpoint per-chunk position every 1 s (fsync, then save state). Max loss per drop ≈ 1 s of data.
4. New URLSession per retry cycle (drops sockets bound to old IP). NWPathMonitor: network/VPN change → restart cycle at once.
5. Backoff 2→60 s with jitter, retry forever. Fatal only: auth needed, 404, file changed on server, SHA mismatch, disk error.
6. SHA256 check at end (HF `X-Linked-Etag`, Civitai API hash).

## Layout
- `src/DLCore` — engine (actor), resolvers (HF, Civitai), streaming fetcher, state, Keychain, network monitor.
- `src/ModelPullApp` — SwiftUI UI: link field, save folder, job cards, Settings (tokens → Keychain, connections, downloads at once, SHA toggle, keep awake).
- `tests/DLChecks` — self-check runner (no XCTest in CLT) + `--real` mode.
- `scripts/build-app.sh` — release build → `build/ModelPull.app`, ad-hoc signed.

## Status (2026-10-18)
- [x] Engine + checks: hostile network, slow link (0 bytes re-downloaded), pause/resume, corruption, size change.
- [x] Real HF: kill -9 mid-chunk → resumed from exact byte.
- [x] Real Civitai (public model, no token): resolves + downloads.
- [x] App builds and launches.
- [ ] User test: real 15+ GB model with NordVPN server switches.
- [ ] UI visual check by user.

## Linux version — status (paused 2026-10-18 evening)
- Approach A chosen: same DLCore + `ModelPullWeb` (local web UI on 127.0.0.1:8765). Target: Ubuntu 24.04 x86_64 laptop, no SSH → ship tarball.
- Done: DLCore ported (Log, SHA256 fallback, file token store, getifaddrs network monitor, `dlData` async helper). Web server + page + Manager. `install.sh`, `.desktop`, autostart, README.txt. Mac: all offline checks + web smoke pass.
- Linux (Docker amd64): core checks pass. Web smoke found: HEAD hangs on Linux FoundationNetworking → fixed (HF resolver uses GET Range 0-0); token removal `replaceItemAt` broken → fixed (POSIX rename).
- 2026-10-19: Linux build switched to Swift 6.0 (`swift:6.0-noble`): Swift 5.10 Linux URLSession hangs on the FIRST request of every new session (proven with `DLChecks --probe` matrix). All core checks + web smoke green on Linux. Delivered the Linux tarball (needs libcurl4t64, present on Ubuntu desktop).
- 2026-10-19: Fixed "4 connections = 1": CDN is HTTP/2, one URLSession multiplexes all requests over one TCP connection. Now one session per connection (`URLSessionFetcher(connections:)`). Docker test: 1 conn 4.1 MB/s, 4 conn 6.0 MB/s.
- HF CDN speed varies hugely over time (30 KB/s → 4 MB/s same day, same Mac). Not an app issue.
- 2026-10-19: Integrity guarantee. "Done · SHA256 OK" only after the FULL file hash matches the source.
  - HF: pin commit (`X-Repo-Commit`) on first resolve; retries use that commit. Hash differs on re-resolve → `sourceChanged` (stop, never mix versions).
  - Small HF files: git blob SHA1 check ("Done · git hash OK"). No hash at all → "Done · not verified".
  - Per-chunk SHA256 read back from disk. On mismatch: stage 1 re-download changed chunks → verify whole file; stage 2 re-download all → verify; then stop (`hashMismatch`), .dlpart never renamed.
  - Old state files load (fixture `tests/fixtures/state-v1.json`).
  - Real files on Linux: LFS SHA256 + small-file git id both match independent tools (`scripts/verify-real.sh`, part of linux-build).
- 2026-10-19: External code review → `docs/ARCHITECTURE-FINDINGS.md`. Reviewer applied 4 fixes in code (chunk-completion snapshot ordering, cancellable verification, HTTP Content-Length hardening, stale macOS progress callbacks) and listed 6 open issues. Reviewer validated on macOS only (Swift 5.10, offline checks); **Linux build + new HTTP smoke checks not yet run** → the Linux tarball of that day may predate these fixes.

## Rename to ModelPull (done 2026-10-30, code only)
- Product `ModelPull.app`, bundle id / log subsystem / Keychain service `io.github.novolg.modelpull` (no personal name). Linux binary, tarball, `.desktop`, icon, log: `modelpull`.
- SwiftPM targets `ModelPullApp`, `ModelPullWeb` (DLCore, DLChecks unchanged). UI texts, `/api/ping` → `modelpull`, POST guard header `X-ModelPull`, env `MODELPULL_STATE_DIR`.
- `LegacyData.migrate()` at start moves old jobs folder and `~/.config/downloader` once (only if the new path is missing). Keychain tokens and macOS UserDefaults are NOT moved: the old keys carry the old bundle id, which must not appear in the repo. User re-enters them once.
- `install.sh` removes the old `downloader` binary, `.desktop`, autostart, icon and log folder.
- Checks: 5 new DLChecks for the folder move (94 total, green on Mac); web smoke checks config move + old header rejected.
- Not yet run: web smoke + Linux build (Docker was off), ModelPull.app rebuild.

## NEXT (in order)
1. ~~Linux checks with reviewer's fixes~~ — green (incl. malformed Content-Length).
2. ~~Findings 1–4~~ — fixed + 25 new checks; see FINDINGS "Status update". Open: #5 (unbounded body if server ignores Range), #6 (Civitai query-order file match).
3. Run `scripts/linux-build.sh amd64` (Docker), rebuild ModelPull.app when user closes the running app (LuLu will prompt once). Then user tests Linux tarball.
- Rules: no network tests on host Mac (LuLu prompts) — Docker only. Don't rebuild the app while user is testing it.
- Open questions to user: delete stray test `config.json` in ~/Downloads? Laptop arch (`uname -m`)? Stable signing cert for LuLu?

## Later
- App icon, notifications when done, menu-bar mode, queue reordering.
