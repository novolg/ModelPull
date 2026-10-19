# ModelPull — Architecture Review Pack

> Naming: identifiers, paths and products below use the ModelPull names (rename done 2026-10-30). Line counts and check counts are from 2026-10-19.

> Purpose: give an external reviewer everything needed to critique design, correctness, durability, integrity, concurrency and security **without** opening the repo. File paths are relative to repo root. State as of 2026-10-19.
>
> Reviewer: please prioritise (1) any path where a corrupted or incomplete file could end up named as finished, (2) any path where progress is lost / download restarts from zero, (3) concurrency races, (4) security of the Linux local web UI. Section 13 lists questions.

> Follow-up: [implementation review findings and fixes](ARCHITECTURE-FINDINGS.md) records four fixes and six remaining issues. The descriptions below are the original review snapshot.

---

## 1. Problem & constraints

**User problem.** Large model files (15+ GB) from Hugging Face (HF) and Civitai fail to download on an unstable link behind NordVPN. Browser resume often restarts from byte 0.

**Root cause (verified).** HF/Civitai answer with a redirect to a **short-lived signed CDN URL** (sometimes IP-bound). After a drop or VPN IP change, the old signed URL is dead → client cannot resume → restarts.

**Design answer.** Persist the *permanent source link*; on every failure obtain a *fresh signed link*; continue with HTTP `Range` from the exact byte on disk; verify the whole file against the source hash before giving it its real name.

**Environment constraints.**
| Item | Value |
|---|---|
| User OS | macOS 14.3 (Apple Silicon). Second target: Ubuntu 24.04 x86_64 laptop (no SSH; ship a tarball). |
| Toolchain on Mac | Command Line Tools only (Swift 5.10). **No Xcode, no XCTest.** |
| Linux toolchain | Docker `swift:6.0-noble` (amd64 under emulation). Swift 5.10 rejected — see §12. |
| Network | Very variable: 30 KB/s → 4 MB/s on the same CDN within an hour. NordVPN. |
| Mac firewall | LuLu: prompts for every new binary signature. All builds are ad-hoc signed → every rebuild prompts. |
| Dependencies | None (no SwiftPM packages). Foundation, SwiftUI, Network, CryptoKit, Security on Apple; FoundationNetworking (libcurl) + Glibc on Linux. |

---

## 2. Repository layout & targets

```
Package.swift                  swift-tools 5.10, platforms macOS 14
src/DLCore/                    shared engine (macOS + Linux)
  Models.swift        119      SourceKind, ResolvedTarget, Tokens, DLError, Phase, ProgressSnapshot
  JobState.swift      158      persistent per-job state + StateStore (JSON files)
  Resolvers.swift     249      source link -> fresh direct link (HF, Civitai, direct)
  Fetcher.swift       228      probe + streaming Range fetch; one URLSession per connection
  Engine.swift        427      actor DownloadEngine: run loop, cycle, chunk scheduling, verify, repair
  Support.swift       278      PartWriter (pwrite), Backoff, SpeedMeter, FileHash, NetworkMonitor, Keychain (Apple)
  Platform.swift      240      Log, SHA256Stream, SHA1Stream (Linux fallbacks), file token store (Linux)
src/ModelPullApp/              macOS SwiftUI app (target ModelPullApp)
  App.swift, JobStore.swift, Views.swift, Theme.swift
src/ModelPullWeb/              Linux (also builds on macOS) local web UI (target ModelPullWeb)
  main.swift (routes), HTTPServer.swift (POSIX sockets), Manager.swift (scheduler), Page.swift (HTML/CSS/JS)
tests/DLChecks/main.swift 406  self-check runner (57 checks) + --real / --probe modes
tests/fixtures/state-v1.json   real state file written by the previous app version
scripts/                       build-app.sh, linux-build.sh, web-smoke.sh, verify-real.sh, speed-test.sh
packaging/linux/               install.sh, README.txt
docs/PLAN.md                   running plan + status log
```
Total ≈ 3.8 k lines.

Products:
- `ModelPullApp` → wrapped by `scripts/build-app.sh` into `build/ModelPull.app` (ad-hoc `codesign -s -`).
- `ModelPullWeb` → Linux binary `modelpull` (`--static-swift-stdlib`; dynamic libcurl, libssl…), packaged as `dist/modelpull-linux-amd64.tar.gz`.
- `DLChecks` → test runner (no XCTest available).

---

## 3. Core data flow

```
user pastes link ──► JobState(sourceURL, destDir, chunkSize=8 MiB) persisted
                         │
         ┌───────────────▼───────────────────────── run() loop (actor DownloadEngine) ──┐
         │ wait online ─► cycle():                                                       │
         │   resolve(sourceURL [pinned to commit]) ─► ResolvedTarget{directURL, sha256,  │
         │                                             gitSHA1, revision, headers}       │
         │   compare hashes with state (different ⇒ sourceChanged, fatal)                │
         │   probe(Range 0-0) ─► total size (Content-Range) ; size differs ⇒ fatal       │
         │   prepare sparse <name>.dlpart (first time)                                   │
         │   fetchMissing(): task group, N = connections, one chunk per task             │
         │       each task: Range request from (chunkStart + partial[c]) to chunkEnd     │
         │       bytes streamed → PartWriter.pwrite at exact offset                      │
         │       ticker every 1 s: snapshot partial → fsync → persist                    │
         │       chunk done: fsync → read chunk back → SHA256 → markDone → persist       │
         │ any error: classify fatal / retryable; backoff or 1 s; loop                   │
         │ network path change: cancel current cycle, restart in 1 s                     │
         └─────────────── all chunks done ──► finish(): full-file hash vs source ────────┘
                               match ─► rename .dlpart → final name, status=done, verified=true
                               mismatch ─► repair stage 1 / 2 (see §7) ─► back to run loop
                               mismatch after stage 2 ─► fatal hashMismatch, .dlpart kept
```

---

## 4. DLCore in detail

### 4.1 Models (`Models.swift`)
- `SourceKind`: `huggingface | civitai | direct`.
- `ResolvedTarget` (never persisted): `directURL`, `fileName`, `sha256?`, `headers` (auth only when the data host is the source host), `gitSHA1?`, `revision?`.
- `Tokens { huggingface?, civitai? }`.
- `DLError` and `isFatal`:

| Error | Fatal | Meaning / handling |
|---|---|---|
| `unsupportedURL` | ✔ | parser rejected link |
| `authRequired(kind)` | ✔ | 401/403 at source or Civitai login redirect; user adds token then Retry |
| `notFound` | ✔ | 404 at source / no file in Civitai version |
| `linkExpired(status)` | ✗ | CDN 400/401/403/404/410 → re-resolve after 1 s |
| `http(status)` | ✗ | 429/5xx etc. → exponential backoff |
| `rangeNotSupported` | ✗ (fatal after 5 consecutive w/o progress) | server answered 200 to a Range request |
| `badRange(msg)` | ✗ | wrong Content-Range / short or long body |
| `sizeChanged` | ✔ | probe total ≠ stored total |
| `sourceChanged` | ✔ | re-resolve returns a different SHA256 / git id |
| `hashMismatch` | ✔ | full-file hash wrong even after stage-2 full re-download |
| `badResponse(msg)` | ✗ | non-HTTP, malformed redirect, bad JSON |
| `disk(msg)` | ✔ | write/fsync/read/rename failure |
| `URLError` (not DLError) | ✗ | network; backoff |

- `Phase`: `queued, resolving, downloading, waitingNetwork, retrying(reason, inSeconds), verifying(fraction), paused, done, failed(msg)`.

### 4.2 Persistent state (`JobState.swift`)
One JSON file per job, written atomically (`Data.write(.atomic)`):
- macOS: `~/Library/Application Support/ModelPull/jobs/<uuid>.json`
- Linux: `~/.local/share/ModelPull/jobs/<uuid>.json` (Foundation's applicationSupport on Linux = XDG data dir)
- Override: env `MODELPULL_STATE_DIR` (tests).
- `LegacyData.migrate()` at app start moves the pre-rename folders (`…/Downloader/jobs`, `~/.config/downloader`) once, only when the new folder is missing.

Fields: `id, sourceURL, kind, destDir, fileName?, totalSize?, sha256?, chunkSize, doneBitmap (Data bitset), partial [chunk: bytesOnDiskFromChunkStart], status (active|paused|done|failed), lastError?, addedAt`, integrity fields `revision?, gitSHA1?, chunkHashes [chunk: sha256hex], repairStage (0/1/2), verified?`.

- Custom `init(from:)` uses `decodeIfPresent` for all post-v1 fields → old files load (fixture test with a real v1 file).
- `doneBytes = Σ finished chunk sizes + Σ partial`.
- `reset()` (user "Restart from zero") clears size, hashes, bitmap, partial, revision, chunkHashes, repairStage, verified.
- Data file: `<destDir>/<fileName>.dlpart`, sparse-preallocated via `truncate(atOffset: total)`. Renamed to `<fileName>` only after verification. Name collisions → `name (1).ext`.

### 4.3 Resolvers (`Resolvers.swift`)
`RouterResolver` dispatches by `SourceParser.kind(of:)`. All resolver requests use `NoRedirect` session (delegate returns `nil` from `willPerformHTTPRedirection`) so 3xx is visible.

**HF (`HFResolver`).**
- Accepts `/<repo...>/resolve|blob/<rev>/<path>` (models, `datasets/…`, `spaces/…`), canonicalises to `https://huggingface.co/.../resolve/...`, drops query.
- Request: **GET with `Range: bytes=0-0`** (not HEAD — HEAD hung on Linux 5.10; GET bounds the body to ≤1 byte), `Accept-Encoding: identity`, `Authorization: Bearer` if token.
- Loop ≤6 hops: same-host 3xx (e.g. `/api/resolve-cache/...`) → follow with auth; cross-host 3xx → that is the signed CDN URL (returned **without** auth header).
- Headers read: `X-Linked-Etag` / `ETag` → 64-hex = SHA256 (LFS), 40-hex = git blob SHA1 (non-LFS); `X-Repo-Commit` → `revision`.
- 200/206 on huggingface.co itself → small non-LFS file; data URL = resolve URL **with** auth header.
- `HFResolver.pinned(url, revision:)` rewrites `<rev>` to the commit. Engine uses it for every resolve after the first.

**Civitai (`CivitaiResolver`).**
- Accepts `/api/download/models/<versionId>[?type&format]`, `/models/<modelId>[/slug][?modelVersionId=<v>]`.
- Model-only link → `GET /api/v1/models/<id>` → first `modelVersions[0].id`.
- `GET /api/v1/model-versions/<v>` → choose file: one whose `downloadUrl` matches the explicit download link, else `primary == true`, else first. Gets `name`, `hashes.SHA256`.
- Then GET the download URL with `Range: 0-0`, Bearer token if present. 3xx → signed URL (Location to `civitai.com/...login...` ⇒ `authRequired`). 200/206 → serve directly with auth.
- No `revision` concept; integrity relies on SHA256 comparison each resolve.

**Direct.** Any other http(s) host → `.direct`: URL used as-is, no hash, no re-resolve value. (UI text says HF/Civitai only, but parser accepts — see §13.)

### 4.4 Fetcher (`Fetcher.swift`)
```swift
public protocol ChunkFetcher: Sendable {
    func probe(_ target: ResolvedTarget) async throws -> Int64              // Range 0-0, total from Content-Range
    func fetch(_ target: ResolvedTarget, range: ClosedRange<Int64>,
               sink: @escaping @Sendable (Data) throws -> Void) async throws // streams exactly `range`
    func invalidate()
}
```
`URLSessionFetcher(connections:)`:
- **One `URLSession` (+ own `StreamDelegate`) per connection ("lane").** Reason: CDN is HTTP/2; a single URLSession multiplexes all requests over **one TCP connection**, so "4 connections" ran at single-connection speed (measured: 4 multiplexed ≈ 60 KB/s total vs 4 separate ≈ 250 KB/s at the same time). Each fetch takes the least-busy lane.
- New fetcher (all sessions) **per retry cycle** → no pooled sockets survive an IP/VPN change. `invalidate()` cancels all.
- Session config: ephemeral, no cache, `timeoutIntervalForRequest = 30` (idle → stall guard), `timeoutIntervalForResource = 6 h`, `waitsForConnectivity = false` (macOS).
- Request headers: `Range`, `Accept-Encoding: identity` (no transparent gzip — offsets must be raw), plus target headers.
- `StreamDelegate` (per lane, NSLock-protected `[taskIdentifier: Handler]`):
  - `didReceive response`: `RangeCheck.header` (must be 206 and `Content-Range` must start with `bytes <lo>-<hi>/`), else cancel.
  - `didReceive data`: rejects body longer than range; calls `sink` **outside** the lock; counts bytes.
  - `didComplete`: resumes continuation; success only if `received == range.count`.
- `RangeCheck.status`: 206 ok; 200 → `rangeNotSupported`; 400/401/403/404/410 → `linkExpired`; 416 → `badRange`; else `http`.
- `URLSession.dlData(for:)`: portable async request (Linux FoundationNetworking lacks `data(for:)`), cancellation via `TaskBox` (handles cancel-before-task-exists).

### 4.5 Engine (`Engine.swift`, `actor DownloadEngine`)
Config: `connections (default 4), verifySHA (default true), backoffBase 2 s, backoffMax 60 s, linkRetryDelay 1 s`; chunk size 8 MiB.

**run()** (excerpt):
```swift
while true {                               // outer: download → verify → maybe repair
  while true {                             // inner: retry until all chunks on disk
    if Task.isCancelled { return pause() }
    if !network.isOnline { emit(.waitingNetwork); await network.waitUntilOnline(); continue }
    let task = Task { try await self.cycle() }; cycleTask = task
    do { try await withTaskCancellationHandler { try await task.value } onCancel: { task.cancel() }
         cycleTask = nil; break }
    catch {
      cycleTask = nil
      if Task.isCancelled { return pause() }
      if progressed { backoff.reset(); rangeFailures = 0 }; progressed = false
      if dl == .rangeNotSupported { rangeFailures += 1 }
      if dl.isFatal || rangeFailures >= 5 { return fail(dl) }
      delay = networkRestart || linkExpired ? 1 s : backoff.next()   // 2,4,8..60 s ±25 % jitter
      emit(.retrying(reason, delay)); sleep(delay)
    }
  }
  if try await finish() { return state }   // false = repair scheduled → loop again
}
```
- Cancellation of the outer task = **pause** (state persisted as `paused`).
- `networkChanged()` (from NetworkMonitor subscription) cancels only the current cycle task → retry in 1 s with fresh resolve + fresh sessions.

**cycle():** pin HF revision → resolve → set `fileName` (unique) → compare/store `sha256`, `gitSHA1`, `revision` (mismatch ⇒ `sourceChanged`) → new fetcher → `probe` → size check → create/prepare `.dlpart` if new or missing (then bitmap, partial, chunkHashes reset) → `fetchMissing`.

**fetchMissing():**
1. Promote `partial[c] >= chunkLen` to done (computing its chunk hash from disk).
2. `PartWriter` over the `.dlpart` (`starts[c]`, `partial`).
3. Ticker task (actor-isolated) every 1 s → `checkpoint`.
4. `withThrowingTaskGroup`: at most `connections` concurrent chunk tasks; each requests `[chunkStart + partial[c], chunkEnd]` and streams into `writer.append(chunk:)`.
5. On each finished task → `completeChunk`. On any error → `checkpoint` then rethrow (group auto-cancels siblings).

**Durability ordering (invariant: state never claims bytes that are not durable):**
```swift
// checkpoint (every 1 s and on error)
let snap = writer.snapshot()      // 1. take counters FIRST
try writer.sync()                 // 2. fsync: everything counted is now durable
state.partial = snap.filter { !state.isDone($0.key) }
persist()                         // 3. record

// completeChunk
try writer.sync()                                                    // 1. fsync
state.chunkHashes[idx] = try FileHash.sha256(of: part, range: chunk) // 2. hash what is ON DISK
writer.complete(idx); state.markDone(idx); state.partial = writer.snapshot()
persist()                                                            // 3. record
```
`PartWriter.append` = `pwrite` loop under an `NSLock`, advancing `partial[chunk]` only after bytes are written.

Max data loss per drop ≈ ≤1 s of bytes per connection (bytes after the last checkpoint are simply re-requested).

### 4.6 Support (`Support.swift`) & Platform (`Platform.swift`)
- `Backoff`: `base·2^n`, cap, ±25 % jitter; reset when a cycle made progress.
- `SpeedMeter`: 10 s window of `(time, doneBytes)` samples; reset on any non-downloading phase.
- `FileHash`: streaming SHA256 of file (progress callback, cancellable via `Task.checkCancellation`), SHA256 of a byte range, git blob SHA1 (`sha1("blob <size>\0" + content)`).
- `SHA256Stream` / `SHA1Stream`: CryptoKit on Apple; pure-Swift implementations on Linux (SHA256 uses a stack temp buffer per block). Vectors tested: "abc", empty, 1 MB vs Python hashlib, SHA1 "abc", 200-byte vs hashlib, git blob of `hello world\n` = `git hash-object`.
- `NetworkMonitor` (singleton): Apple → `NWPathMonitor`, signature = status + sorted interface names; Linux → poll `getifaddrs` every 2 s, signature = sorted `iface=addr` of UP+RUNNING non-loopback interfaces. Subscribers called only on signature change (not on the first update). `waitUntilOnline()` via continuations.
- Tokens: Apple → Keychain generic password (service `io.github.novolg.modelpull`, accounts `huggingface`/`civitai`; set = delete + add). Linux → `~/.config/modelpull/tokens.json` (dir 0700, file created 0600 then POSIX `rename` — `FileManager.replaceItemAt` is broken on Linux corelibs).
- `Log`: `os.Logger` on Apple (+stderr if `DL_LOG_STDERR=1`); stderr `key=value` lines on Linux.

---

## 5. Concurrency model
| Component | Isolation | Notes |
|---|---|---|
| `DownloadEngine` | actor | all state mutations; ticker task and group-result handling hop onto it |
| chunk fetch tasks | task-group children (non-isolated) | call `fetcher.fetch`, which bridges a URLSession delegate to a continuation |
| URLSession delegate callbacks | per-lane serial OperationQueue | `sink` → `PartWriter.append` (NSLock) |
| `PartWriter` | `@unchecked Sendable` + NSLock | `sync()` (fsync) is not under the lock (fd-level) |
| `NetworkMonitor` | NSLock + dispatch queue | callbacks spawn `Task { await engine.networkChanged() }` |
| verify / repair hashing | `Task.detached` | **does not inherit cancellation** (see §13) |
| macOS `JobStore` | `@MainActor` ObservableObject | progress via `Task { @MainActor in job.progress = snap }` per event |
| Linux `Manager` | actor | progress via `Task { await report() }`; late events after finish ignored |

Invariant relied upon: a chunk task cannot return before its URLSession task's `didComplete` fires, so no `sink` call can run after the group exits and `PartWriter.close()` runs.

---

## 6. Integrity model (the "100 % or never Done" guarantee)
**Rule:** a file gets its final name and status `done` **only** if the hash of the **entire** file equals the source hash. Every repair path ends in another full-file verification.

| Threat | Defence |
|---|---|
| Bytes corrupted in transit | TLS (AEAD) rejects; plus full-file hash |
| Wrong range/length from server | `RangeCheck` per response (206, exact Content-Range prefix, exact length) |
| Server publishes new version mid-download (same size) | HF: pinned commit; HF+Civitai: hash compared every resolve → `sourceChanged` (fatal) |
| File size changes | probe vs stored → `sizeChanged` (fatal) |
| Crash / power loss | write → fsync → record; atomic state file; `.dlpart` until verified |
| Disk bytes changed after write | per-chunk SHA256 read back at completion; stage-1 repair re-downloads only changed chunks |
| Our own bookkeeping bug / wrong bytes recorded | stage-2 full re-download; still wrong ⇒ stop |
| Small HF files (no SHA256) | git blob SHA1 verification |
| Source with no hash (direct URL, some Civitai files) | **Not verifiable.** Labelled "Done · not verified (source gives no hash)" |
| User turned "Check SHA256" off | same "not verified" label |

**Repair state machine (`finish` / `scheduleRepair`):**
```
verify whole file
 ├─ match → rename, done, verified=true
 └─ mismatch
     ├─ stage 0→1: rehash every finished chunk from disk; chunks whose hash ≠ recorded (or no recorded hash) → un-mark, re-download, verify whole file again
     │             (if none differ, fall through: wrong bytes arrived, chunk hashes cannot locate them)
     ├─ stage ≤1→2: un-mark all chunks, re-download everything, verify whole file again
     └─ stage 2 mismatch → fatal hashMismatch; .dlpart kept; never renamed
```
Labels: "Done · SHA256 OK", "Done · git hash OK", "Done · not verified (source gives no hash)".

---

## 7. macOS app (`src/ModelPullApp`)
- SwiftUI `WindowGroup`, hidden title bar, forced dark scheme. `applicationShouldTerminateAfterLastWindowClosed = false` (closing window keeps downloading).
- `JobStore` (@MainActor): loads all states at launch; `.active` jobs auto-start; scheduler `pump()` starts oldest active jobs up to `maxActive` (default 1). Pause = cancel engine task (engine persists `paused`). Remove / Restart await the engine task before touching files. `ProcessInfo.beginActivity(.idleSystemSleepDisabled)` while any job runs (setting).
- Settings (`@AppStorage`): connections 2/4/8, downloads at once 1/2/3, verify SHA, keep awake, save folder (NSOpenPanel). Tokens → Keychain.
- UI kit (`Theme.swift`): monochrome dark (bg 0.04 white, panels 0.075, fields 0.105), tracked caps labels, pill toggle with "on/off" text, radio rows, 3 px progress line.
- Built by `scripts/build-app.sh` (release, Info.plist, ad-hoc sign). **Current installed build predates the HTTP/2-lane and integrity changes** (rebuild pending user's go; a rebuild re-triggers LuLu once).

## 8. Linux app (`src/ModelPullWeb`)
- Single binary `modelpull [--port 8765] [--no-open]`. Starts POSIX HTTP/1.1 server on **127.0.0.1 only**, opens browser via `xdg-open`. If port busy and `/api/ping` answers `modelpull` → just opens browser and exits (single instance).
- `HTTPServer`: accept loop on a detached Thread; each connection handled on a global queue; 10 s receive timeout; header ≤64 KB; body ≤1 MB; one request per connection; response via `send` loop; `SIGPIPE` ignored.
- **Security:** Host header must be `127.0.0.1:<port>` or `localhost:<port>` (DNS-rebinding defence); every POST requires header `X-ModelPull: 1` (cross-site forms/fetch cannot add it without a CORS preflight, which the server never approves). Token values are never returned (only booleans). No auth beyond that: any local process/user on the machine can call the API.
- Routes: `GET /` page; `GET /api/ping|state|dirs?path=`; `POST /api/add|settings|tokens|quit`; `POST /api/jobs/<uuid>/pause|resume|restart|remove|delete|reveal`.
- `Manager` actor mirrors `JobStore` logic; settings in `~/.config/modelpull/settings.json`.
- Keep awake: `systemd-inhibit --what=idle:sleep … tail --pid=<ourpid> -f /dev/null` (inhibitor dies with the app; macOS dev fallback `caffeinate -i -w <pid>`). Lid-close is not inhibited.
- `Page.swift`: self-contained HTML/CSS/JS (no external assets), polls `/api/state` every 1 s, keyed DOM updates (actions re-rendered only when phase/status changes), folder browser modal, settings modal, quit modal.
- Install (`packaging/linux/install.sh`, no sudo): `~/.local/bin/modelpull`, icon, `.desktop` entry (stderr → `~/.local/state/modelpull/modelpull.log`), optional `--autostart` (`--no-open`), `--uninstall`; removes old `downloader` app files; warns if `ldd` shows missing libs (`libcurl4t64`).

---

## 9. Build, test & verification
| Script | Where | What |
|---|---|---|
| `swift build` | Mac (sandbox off) | all targets |
| `.build/debug/DLChecks` | Mac + Linux | 57 offline checks (below) |
| `scripts/web-smoke.sh <bin>` | Linux container (Mac without token tests) | API, security headers, settings, tokens (file mode 600), real HF download, dirs, quit, no orphan inhibitor |
| `scripts/verify-real.sh <DLChecks>` | Linux container | real HF LFS file: engine SHA256 + independent `sha256sum` vs HF API `lfs.oid`; small file: engine git id vs independent `printf blob…|sha1sum`; commit pinned |
| `scripts/speed-test.sh` | Linux container | 1 vs 4 connections on real HF file |
| `scripts/linux-build.sh amd64` | Mac → Docker | release build (static stdlib), DLChecks, web smoke, real integrity, `ldd`, strip, tarball |

**DLChecks coverage (fake in-memory CDN + fake resolver/fetcher, 64 KiB chunks, tiny backoff):**
parsers (HF blob/resolve/datasets, Civitai 3 link forms, rejects); ETag→SHA256/SHA1; SHA256/SHA1 vectors; git blob id; commit pinning; RangeCheck (206 ok, 200, short, wrong offset, 403→linkExpired, 15 GB total parse); hostile network (30 % mid-stream drops, links expire every 5 fetches, 5 % ignore Range); slow link (every request dies after 40 % → 0 bytes re-downloaded); pause → reload state from disk → resume (only missing bytes fetched); persistent corruption (never Done, stage 2 reached, no final file, .dlpart kept); one-time transit corruption (stage 2 → Done verified, identical); on-disk damage after chunk finished (stage 1, only that chunk re-fetched, identical); new version mid-download same size (sourceChanged, no final file); no-hash source (Done, verified=false); v1 state fixture loads with progress intact; size change (fatal). Ran 10× consecutively green on Mac; green on Linux (Swift 6.0).

**Real-network results:** Mac (earlier engine): HF kill -9 mid-chunk → resumed from exact byte; Civitai public model resolved + downloading. Linux container: LFS 125 MB file and `config.json` verified against independent tools; speed 1 conn 4.1 MB/s, 4 conn 6.0 MB/s.

---

## 10. Empirical findings log (bugs found while building)
1. **Whole-chunk atomicity fails on slow links.** At ~80 KB/s an 8 MiB chunk (4 parallel) never finished before the next drop → no progress. Fix: stream to disk + 1 s checkpoints of intra-chunk offset.
2. **HTTP/2 multiplexing** made N connections ≈ 1 (see §4.4). Fix: session per lane.
3. **Swift 5.10 Linux FoundationNetworking:** the **first request of every new URLSession hangs until timeout**; later requests on the same session are fast. Proven with a matrix (fresh/shared × identity/plain × redirect blocked/followed; "kick" workaround unreliable). Swift 6.0: 30/30 fast. Linux build moved to 6.0.
4. HEAD with blocked redirect hung on Linux 5.10 → resolver uses GET Range 0-0 (kept for safety on 6.0).
5. `FileManager.replaceItemAt` fails on Linux → POSIX `rename`.
6. LuLu firewall blocked DNS of every freshly-signed test binary → looked like "resolving hangs" → misdiagnosed once as slow network. Policy now: network tests only in Docker.
7. A chunk fully written at the moment of pause was promoted to done **without** a chunk hash → stage-1 repair would needlessly re-download it. Fixed (hash read from disk on promotion); caught by a flaky test.
8. HF CDN speed for this user varies 30 KB/s ↔ 4 MB/s within an hour on the same machine (not an app issue).

---

## 11. Known limitations, risks & smells (self-identified, unprioritised by reviewer)
**Correctness / robustness**
1. `Task.detached` hashing (full verify ~1–2 min for 15 GB, stage-1 rehash) does **not** observe pause/cancel → pause waits for hashing to finish.
2. `completeChunk` reads 8 MiB back and hashes it **synchronously on the actor** → blocks checkpoints/network-change handling briefly per chunk (~10–50 ms).
3. Stage-1 repair cannot locate *wrong bytes that arrived* (chunk hash describes what was written) → relies on stage 2 full re-download (expensive for 15 GB, but correct).
4. Chunks finished by the previous app version have no chunk hash → treated as damaged in stage 1 (conservative, costs bandwidth only on a mismatch).
5. macOS `JobStore`: per-event `Task { @MainActor … }` may apply a late `.downloading` snapshot after `.done` (Linux `Manager` guards against this; macOS does not).
6. `NetworkMonitor` on Linux includes IP addresses in the signature → IPv6 privacy-address rotation triggers needless cycle restarts. macOS uses interface names only → an IP change on the same interface (some VPN reconnects) may **not** trigger a restart (relies on 30 s idle timeout instead).
7. Disk space is not checked up front; sparse file → "disk full" surfaces mid-download as fatal `disk` error.
8. `rangeNotSupported` threshold (5 consecutive, reset on progress) is a heuristic for captive portals / proxies.
9. `persist()` writes the full JSON every second; for 15 GB `chunkHashes` ≈ 1 900 × 64 hex chars ≈ 130 KB/s of state writes.
10. `.direct` links (any host) are accepted though UI says HF/Civitai only; they get no re-resolve and no hash.
11. Civitai end-to-end download to completion + SHA256 not yet run on a real file (resolver + start of download verified only). Civitai file choice falls back to `primary`/first if the link has no explicit type/format.
12. HF pinning uses `X-Repo-Commit`; if absent, version is not pinned (hash comparison still protects).
13. Keychain `set` = delete + add (non-atomic; failure leaves no token).

**Security**
14. Linux tokens are plaintext JSON (0600). No libsecret integration.
15. Linux web API has no per-user auth: any local process can add downloads, change save folder (any existing directory), read directory listings (`/api/dirs` lists any path the user can read), or quit the app. Bound to loopback only.
16. Ad-hoc signing: Gatekeeper/LuLu friction; Keychain ACL prompts after each rebuild.

**Design smells**
17. Scheduling logic duplicated between macOS `JobStore` and Linux `Manager`.
18. Two UIs (SwiftUI and HTML) to keep visually and behaviourally in sync.
19. Linux built only for amd64 (no arm64 tarball); built under emulation.
20. No UI tests; macOS app verified manually by the user only.
21. Pure-Swift SHA256 speed on Linux not benchmarked for 15 GB.

---

## 12. Decisions & alternatives considered
| Decision | Why | Rejected alternatives |
|---|---|---|
| Native Swift app, no deps | Only CLT available; user wanted a macOS app; small attack surface | Electron/Tauri (heavier, needs toolchains), Python+pywebview |
| Own engine instead of `aria2c` | aria2c cannot re-resolve expired signed URLs (core bug) | wrapper around aria2c / `hf download` |
| Re-resolve on every cycle + new sessions | VPN IP change kills signed URLs and pooled sockets | keep sessions (stale sockets), only retry |
| 8 MiB chunks + intra-chunk offsets | parallelism + loss ≤1 s on drops | whole-chunk atomicity (failed on slow links) |
| Linux = same core + local web UI | reuse proven engine; works on desktop and headless | GTK UI, full rewrite in Rust/Tauri |
| Full-file hash as the only "Done" gate; chunk hashes for repair only | cryptographic certainty; repair cannot weaken guarantee | trusting chunk hashes alone; HF Xet per-chunk hashes (complex, HF-only — deferred) |
| Swift 6.0 for Linux | 5.10 URLSession first-request hang | per-session warm-up hacks (unreliable), libcurl/`curl` subprocess |

---

## 13. Open questions for the reviewer
1. Is the durability ordering (snapshot → fsync → persist; fsync → read-back hash → persist) sufficient on APFS and ext4 for the "state never claims non-durable bytes" invariant? Should the directory also be fsynced after the atomic state write and after the final rename?
2. Any race where a `sink` call could still run after `PartWriter.close()` (e.g. URLSession delegate delivering data after `cancel()` but before `didComplete`)?
3. Is treating CDN 400/401/403/404/410 as `linkExpired` (retry forever with fresh link) safe, or can a permanent CDN 404 loop forever? (Source-level 404 is fatal.)
4. Better design for cancellable full-file verification and off-actor chunk read-back?
5. Is per-lane `URLSession` the right fix for HTTP/2 multiplexing, or should we force HTTP/1.1 / use `URLSessionConfiguration` knobs?
6. Network-change detection: use interface + address on both platforms? Debounce?
7. Security of the Linux local API: add a random per-launch token in the page URL / cookie? Restrict `/api/dirs`?
8. Should stage-2 full re-download require user confirmation for very large files?
9. Should HF Xet chunk hashes be used to localise transit corruption (true per-range verification)?
10. Anything in §11 you would rank as a must-fix before the user trusts it with 15 GB downloads?
