# Debugging capability + TUI — design review

Reviewer role: senior SRE / JVM-platform engineer. Scope: the **category-(B)
debugging tools** (the project's primary deliverable), the TUI's coverage of
them, and their portability. Evaluated against the intended design in
`CLAUDE.md` and the `k8s_gotchas.md` memory file, with a **live cluster up**
(all four `ddk3s-*` VMs Running) — every read-only tool was actually executed
and its real output is quoted below. Destructive operations (heap dumps, chaos
scenarios) were **not** run.

Date: 2026-07-03. Host: macOS, stock `/bin/bash` 3.2.57 (no Homebrew bash on
PATH — relevant, see Blocker B2).

---

## Step 0 — inventory & classification

Verified against the actual directory (`ls scripts/ scripts/lib/`):

| File | Class | Notes |
|---|---|---|
| `tui` (root), `k3s.sh`, `k3s-tui.sh` | A | front door + menu |
| `k3s-install.sh`, `k3s-cluster.sh`, `k3s-net.sh`, `k3s-platform.sh`, `k3s-charts.sh`, `k3s-lb.sh`, `k3s-preflight.sh`, `k3s-uninstall.sh`, `bundle-images.sh` | A | lifecycle |
| `dump-threads.sh`, `dump-heap.sh`, `dump-jattach.sh`, `memory-report.sh`, `tail-logs.sh`, `set-log-level.sh` | **B** | **the graded set** |
| `k3s-doctor.sh` | A/B straddle | infra-layer triage; nothing JVM-level |
| `k3s-chaos.sh` | A/B straddle | failure injection (backend-down, node-down); feeds the recipes but drives no JVM failure mode |
| `api-tour.sh`, `valkey-tour.sh`, `valkey-cluster-tests.sh`, `k3s-smoke.sh` | C | tours + protocol tests (`api-tour.sh:170` incidentally demos the actuator threaddump) |
| `run-unit-tests.sh`, `local-ci.sh` | D | build/CI |
| `lib/common.sh`, `lib/k3s-env.sh` | E | shared lib — **note**: `common.sh` mixes the debug-kit core (arg parsing, pod resolution) with Valkey-tour helpers (`valkey_announced_endpoints`, `vkexec`, `lib/common.sh:80-106`) used only by C scripts |
| `scripts/.cache/` | — | jattach binary cache, gitignored (by design) |
| `scripts/.DS_Store` | — | Finder noise, gitignored, delete locally |

Doesn't fit cleanly: **there is no tool for capture path #1 (actuator
threaddump/heapdump)** — the "default" tier exists only as copy-paste
one-liners in CLAUDE.md. See Gaps.

---

## 1. Scorecard

| # | Dimension | Score | One-line justification |
|---|---|---|---|
| 1 | Correctness & no-JDK constraint | **2/5** | jattach path is excellent and proven live; but both ephemeral-JDK tools are broken three independent ways and have plainly never completed a successful run |
| 2 | Code quality & safety | **3/5** | `--confirm` gating and host-side-download patterns are right; bash-3.2 empty-array crash breaks documented invocations on a stock Mac; silent-zero metrics on scrape failure |
| 3 | Ease of use & discoverability | **2/5** | consistent `-n/-l/--container` via lib; but only 1 of 6 tools has `--help`, and `--help` on the others streams logs / stack-traces / gets treated as a pod name |
| 4 | TUI coverage of debug tools | **1/5** | zero (B) tools reachable from `./tui` or `k3s.sh`; the primary deliverable is invisible from the front door |
| 5 | Own front door? | — | **Yes — split a `./debug` front door** (recommendation + menu below) |
| 6 | Portability / extraction | **2/5** | env-overridable defaults are close, but kubeconfig auto-targeting, hardcoded `:8080/actuator`, and the mixed lib block a 10-minute lift |
| 7 | Consistency & conventions | **3/5** | naming and dump-file conventions hold; two different help/output/color house styles between (A/C) and (B) |
| 8 | Stragglers / cruft | **4/5** | repo is clean (gitignore covers dumps/cache); cruft is mostly off-repo (leftover Lima VMs) + one wrong doc paragraph |
| 9 | Docs fidelity | **2/5** | README/CLAUDE.md claim Java 25 (runtime is 21), document invocations that crash, and describe broken tools as working |
| 10 | Capability gaps | **2/5** | strong triage primitives, but no actuator-dump tool, no snapshot bundle, no per-recipe drivers, no trend/watch mode |

---

## 2. Findings by severity

### Blockers

**B1 — `dump-threads.sh` and `dump-heap.sh` have never worked (three independent defects).**
Ran live (safe: it fails before creating anything):

```
$ scripts/debug/capture/jdk-threads.sh -n debug-demo
[23:34:55] dumping threads from pod=app-debug-demo-app-6c6c4b5769-48shx ... (ephemeral=thread-dump-20260704T033455Z)
The Pod "app-debug-demo-app-6c6c4b5769-48shx" is invalid: spec.ephemeralContainers[0].name:
Invalid value: "thread-dump-20260704T033455Z": a lowercase RFC 1123 label must consist of
lower case alphanumeric characters ...
```

1. **Invalid container name** — `dump-threads.sh:25-26` / `dump-heap.sh:34-35`
   build `DEBUG_CONTAINER="thread-dump-$TS"` from `%Y%m%dT%H%M%SZ`; the
   uppercase `T`/`Z` fail RFC 1123 validation, so `kubectl debug` is rejected
   outright. Fix: lowercase the name (`tr 'A-Z' 'a-z'`) or use `date +%s`.
2. **`jstack 1` / `jmap ... 1` target the pause sandbox** —
   `dump-threads.sh:37`, `dump-heap.sh:47`. The chart sets
   `shareProcessNamespace: true`
   (`charts/debug-demo-app/templates/deployment.yaml:22`), so PID 1 is
   `/pause`, not the JVM — the *exact* trap documented in the project's own
   memory file, and proven live: jattach found the JVM at **PID 224**. The
   header comment (`dump-threads.sh:10-11`, "Because the app Deployment sets
   shareProcessNamespace=true, jstack targets PID 1") has the logic
   backwards; `charts/README.md:45-47` repeats the same wrong claim. Fix:
   reuse the `find_jvm_pid` walk from `dump-jattach.sh:160-175`.
3. **The debug image can't exist on this cluster** —
   `JDK_DEBUG_IMAGE=eclipse-temurin:25-jdk-alpine` (`lib/common.sh:10`) is not
   in `K3S_IMAGES` (`lib/k3s-env.sh:62-72`), and the cluster is air-gapped by
   design ("no image is ever pulled inside a VM or pod"). Even with 1+2 fixed,
   `kubectl debug` would sit in `ErrImagePull`. Also a version mismatch: the
   runtime is Java **21** (`app/Dockerfile:10`), the debug JDK is 25. Fix:
   add a matching `eclipse-temurin:21-jdk-alpine` to `K3S_IMAGES` (or
   document that path #3 is online-cluster-only).

Latent 4th defect: `dump-threads.sh:43` `kubectl exec -c $DEBUG_CONTAINER`
runs *after* the ephemeral container's command completed — exec into a
terminated ephemeral container fails; the copy-out path is racy even with
1–3 fixed. (Prefer `kubectl debug -it ... -- sh -c 'jstack <pid>' > file`
directly, no second exec.)

**B2 — Documented invocations crash on stock macOS bash (3.2).**
`bash 3.2` treats `"${arr[@]}"` on an empty array as unbound under `set -u`
(fixed only in bash 4.4). Proven live:

```
$ scripts/debug/capture/jattach.sh install
scripts/debug/capture/jattach.sh: line 73: FILTERED_ARGS[@]: unbound variable
```

Affected: `dump-jattach.sh:73` (any bare `install`/`threads` invocation —
exactly what `README.md:554-555` documents) and `dump-heap.sh:29` (bare
`--confirm`-only invocation — exactly `README.md:561`). Only `/bin/bash`
exists on this machine (`which -a bash` → `/bin/bash`), so this is live, not
theoretical. Fix: `parse_common_args ${FILTERED_ARGS[@]+"${FILTERED_ARGS[@]}"}`
(the standard bash-3.2-safe expansion), applied in all three call sites.

### Major

**M1 — The "default" capture path has no tool.** CLAUDE.md's preference order
is actuator → jattach → ephemeral JDK, but tier 1 exists only as raw
`kubectl exec ... curl` one-liners in CLAUDE.md. Tier 3 is broken (B1), so
today the *only* working scripted dump path is tier 2 (jattach). A
~20-line `dump-actuator.sh` (threaddump JSON/text + gated heapdump) closes
the gap and makes the preference order real.

**M2 — No snapshot-bundle collector.** The "Step 6" bundle (metrics +
threaddump + memory-report + 4 jcmd outputs + optional hprof) is prose in
CLAUDE.md, ~10 commands to be typed mid-incident. `grep -rn snapshot
scripts/` → nothing. This is the single highest-value missing tool.

**M3 — Zero TUI/front-door discoverability** (dimension 4 = 1/5). The
`k3s-tui.sh` menu (`k3s-tui.sh:79-91`) exposes preflight/install/doctor/
smoke/chaos/tours; none of the six (B) tools appear, and `k3s.sh:40-56` has no
subcommand for any of them. An operator who only knows `./tui` cannot
discover that thread/heap capture exists.

**M4 — `memory-report.sh` fails silently to zeros.** `memory-report.sh:55-62`
returns `0` on any actuator/parse failure (`except Exception: print(0)`). A
half-down actuator yields a plausible-looking report with 0.0 MiB rows and a
grossly inflated "Unaccounted" — dangerous during a real OOM triage. Also
`memory-report.sh:143` divides by the cgroup limit; with no memory limit set
(`memory.max` = literal `max`) both `mib` and the percentage line throw
Python errors — a portability trap outside this chart (which always sets 1Gi).

**M5 — Docs describe a different runtime.** README.md:3,541 and
CLAUDE.md:3,12,31,1003 say **Java 25 / `eclipse-temurin:25-jre-alpine`**; the
actual build is **Java 21** (`app/Dockerfile:3,10`, `app/pom.xml:22-23`,
`lib/k3s-env.sh:77-78`, and the live pod: `Full thread dump OpenJDK 64-Bit
Server VM (21.0.11+10-LTS ...)`). Every version-sensitive decision (debug JDK
image, MAT/VisualVM compatibility, Mockito notes) inherits this confusion.

### Minor

- **m1 — `--help` inconsistency.** Only `dump-jattach.sh` handles `-h/--help`
  (`dump-jattach.sh:56-58`; output is genuinely good — captured, would let an
  on-call engineer operate it cold). Proven misbehavior elsewhere:
  `tail-logs.sh --help` **starts streaming logs** (ran with a 5s alarm);
  `memory-report.sh --help` treats `--help` as a pod name and stack-traces
  (`reading pod --help ... json.decoder error`); `dump-threads.sh --help`
  would pass `--help` as the pod name into `kubectl debug`. `dump-heap.sh`
  and `set-log-level.sh` at least exit 64 with a usage line.
- **m2 — jattach banner pollutes captured output.** `Connected to remote JVM
  / JVM response code = 0` lands on stdout ahead of the payload (seen in the
  live `GC.heap_info` run) — anything parsing the capture must skip it;
  `Thread.print` files aren't byte-clean jstack format for fastthread.io.
- **m3 — failed captures leave 0-byte files.** `dumps/threads/…20260628T015351Z.txt`
  is 0 bytes — the `> "$LOCAL_PATH"` redirect creates the file before the exec
  can fail (`dump-jattach.sh:205-206`); no cleanup or size check.
- **m4 — destructive-gating inconsistency.** Heap dumps require `--confirm`
  (good), but `k3s-chaos.sh` stops whole VMs and scales StatefulSets to 0
  with no confirmation at the CLI (TUI gates only `lb-down`,
  `k3s-tui.sh:115`). Not (B)-scoped, but the house rule "destructive ⇒
  gate" is applied unevenly.
- **m5 — duplicated presentation helpers.** `ok/bad/sect` + color setup are
  re-declared in `k3s-doctor.sh:36-40`, `k3s-chaos.sh:37-43`,
  `k3s-tui.sh:23-27` (and the tour/smoke scripts) instead of living in
  `lib/`; the (B) tools use a different, plainer `info/err` style from
  `common.sh:23-24`. Two house styles.
- **m6 — thread-stack estimate hardcodes 1 MiB/thread** (`memory-report.sh:135`)
  — fine for the default `-Xss`, silently wrong if JAVA_OPTS changes it.

### What's genuinely good (evidence, not vibes)

`dump-jattach.sh` is the flagship and it survived a live end-to-end run:

```
$ scripts/debug/capture/jattach.sh jcmd "GC.heap_info" -n debug-demo
[23:33:37] using cached jattach: scripts/.cache/jattach-aarch64-v2.2
[23:33:38] jattach installed and working (jattach 2.2 built on Jan 10 2024...)
[23:33:38] JVM PID inside pod: 224
 def new generation   total 36800K, used 4046K ...
 Metaspace       used 124107K, committed 125184K, reserved 1179648K
```

It honors every constraint: dynamic PID discovery (`find_jvm_pid`,
`dump-jattach.sh:160-175`), arch detection from the pod (`:109-114`),
host-side download with cache + `--binary` air-gap override (`:96-138`),
the `jcmd` action so output is capturable (`:188-197`, correctly explained),
idempotent install (`:89-93`), and `--confirm` on heap (`:80-83`).
`memory-report.sh` also ran clean against the live pod (355 MiB RSS
reconciled: 55.9 heap + 168.9 non-heap + 8.1 direct + 36 stacks + 86.1
unaccounted) and its host-side-parsing design (alpine has no python/jq) is
exactly right. `set-log-level.sh` correctly iterates **all** replicas and
validates levels. The constraint itself is never violated: nothing in (B)
assumes a JDK in the image.

---

## 3. The "own front door" decision

**Recommendation: yes — split a dedicated `./debug` front door
(`scripts/debug.sh` + `scripts/debug/ui/tui.sh`), and add one line to the main
TUI that jumps into it.**

For: (a) the debug kit is the project's product; the cluster is scaffolding —
today the product has no entry point at all (M3). (b) The tools are already
cluster-agnostic in spirit (`-n/-l/--container`, no `k3s-env.sh` dependency —
none of the six (B) scripts source it), so a front door that takes
`-n/-l/--context` cements that boundary and becomes the extraction seam for
dimension 6. (c) The lifecycle TUI's mental model is "operate *this* stack";
the debug TUI's is "diagnose *any* JVM pod" — different defaults, different
safety rails.

Against: one more entry point to document; the runbook's Step 1–4 (pods,
health, logs, top) is generic kubectl that a submenu could just print; and a
submenu inside `./tui` would be less code. But a submenu keeps the kit
welded to `k3s-tui.sh`'s cluster assumptions (`k3s-env.sh` sourcing, VIP
status line) — precisely the coupling to break.

Proposed menu (grouped by the runbook):

```
debug-demo · JVM debug kit          target: ns=debug-demo  sel=app.kubernetes.io/name=debug-demo-app
─────────────────────────────────────────────────────────────
 TRIAGE                         CAPTURE
  1 pod status + events          6 thread dump (actuator, text)     [safe]
  2 actuator health (per-check)  7 thread dump (jattach Thread.print)
  3 top pods / HPA state         8 heap dump   (jattach, PAUSES JVM) [--confirm]
                                 9 jcmd …      (GC.heap_info, NMT, codecache, JFR)
 MEMORY / METRICS               LOGS
  4 memory-report (anatomy)     10 tail logs (all replicas)
  5 watch memory-report          11 set log level
 SNAPSHOT
 12 snapshot bundle → dumps/snapshot-<ts>/   (metrics+threads+memory+jcmd)
  t change target (ns/selector/context)      q quit
```

What moves where: `dump-*.sh`, `memory-report.sh`, `tail-logs.sh`,
`set-log-level.sh` stay in place (or move under `scripts/debug/`);
`debug.sh` dispatches to them exactly as `k3s.sh` dispatches to `k3s-*.sh`.
`k3s-tui.sh` gains one menu item ("d → JVM debug kit") that execs
`debug-tui.sh`. `k3s-doctor.sh`/`k3s-chaos.sh` stay in the lifecycle TUI —
they are about *this* cluster.

---

## 4. Portability report

Could someone lift the kit into another repo and point it at their own Spring
Boot pod in ~10 minutes? **Not today.** Exact coupling points:

1. **Kubeconfig auto-targeting** — `lib/common.sh:16-21` silently exports
   `KUBECONFIG=<repo>/dumps/k3s.kubeconfig` if present and unset. Correct
   here; wrong everywhere else. No `--context`/`--kubeconfig` flag exists.
   (It does respect a pre-set `KUBECONFIG`, which is the one saving grace.)
2. **Defaults** — `NAMESPACE=debug-demo`, `SELECTOR=app.kubernetes.io/name=debug-demo-app`,
   `APP_CONTAINER=app` (`lib/common.sh:7-9`). Overridable via flags/env — fine,
   just needs the default to be declared, not assumed.
3. **Actuator endpoint hardcoded** — `http://localhost:8080/actuator/...` in
   `memory-report.sh:43` and `set-log-level.sh:49`. Needs `--port` /
   `--actuator-base` (management port ≠ 8080 is common in real shops).
4. **Debug image** — `JDK_DEBUG_IMAGE=eclipse-temurin:25-jdk-alpine`
   (`lib/common.sh:10`), env-only override, wrong major version (B1.3).
5. **Output paths** — `OUT_DIR=./dumps/{threads,heap}` relative to CWD
   (`dump-jattach.sh:201,210` etc.); env-overridable, undocumented.
6. **Mixed lib** — `lib/common.sh:80-106` carries Valkey-tour helpers used
   only by (C) scripts (`valkey-tour.sh:52`, `valkey-cluster-tests.sh:149`,
   `k3s-smoke.sh`); lifting `common.sh` drags cluster-specific code along.
7. **Host prerequisites** — `python3` for `memory-report.sh` (fine, checked
   via `require_cmd`), bash-3.2 bug (B2) breaks stock-Mac usage anywhere.

**Extraction plan (numbered):**

1. Fix B2 (bash-3.2 expansion) — prerequisite for any distribution.
2. Split `lib/common.sh`: keep args/pod-resolution/`info`/`err`/`require_cmd`
   as `debug-kit/lib.sh`; move `valkey_announced_endpoints`/`vkexec` to
   `lib/valkey.sh` sourced by the (C) scripts.
3. Add `--context <ctx>` and `--kubeconfig <path>` to `parse_common_args`
   (thread through as `kubectl --context ...`); gate the auto-KUBECONFIG
   export behind "file exists AND no flag given", and print one info line
   when it fires so the hijack is visible.
4. Parameterize `--actuator-base` (default `http://localhost:8080/actuator`)
   in `memory-report.sh`, `set-log-level.sh`, and the new `dump-actuator.sh`.
5. Make `JDK_DEBUG_IMAGE` a `--jdk-image` flag defaulting to the runtime's
   major version; document the air-gap caveat in `--help`.
6. Standardize `--out-dir` (default `./dumps`) and `-h/--help` (one shared
   `print_help` in the lib) across all six tools.

**Proposed `debug-kit/` layout + usage:**

```
debug-kit/
  debug            # front door: debug <cmd> [-n ns] [-l sel] [--context c]
  debug-tui.sh
  lib.sh
  dump-actuator.sh # NEW: threaddump (json/text), heapdump (--confirm)
  dump-jattach.sh
  dump-threads.sh  dump-heap.sh      # ephemeral-JDK fallback (fixed per B1)
  memory-report.sh tail-logs.sh set-log-level.sh
  snapshot.sh      # NEW: the Step-6 bundle
  README.md
# one-liner:
debug-kit/debug snapshot -n prod -l app=payments --context prod-us-east
```

Bonus: the shape maps naturally onto a **krew plugin** (`kubectl jvm-debug
snapshot -n prod -l app=payments`) — everything is already kubectl-only. A
single curl-able script is feasible but would mean inlining the lib; krew or
a tarball release is the better target.

---

## 5. Straggler-file list

| Path | Why it's a straggler | Verdict |
|---|---|---|
| `charts/README.md:45-47` | Claims `shareProcessNamespace: true` lets the debug scripts "target the app's PID 1" — factually inverted (it makes PID 1 the pause sandbox; the memory file documents this) | **fix** |
| `dump-threads.sh:10-11` header comment | Same inverted claim, inside the tool itself | **fix** |
| `dumps/threads/app-…20260628T015351Z.txt` (0 bytes) | Artifact of a failed jattach run (m3); gitignored but misleading in the dump dir | **delete** |
| `scripts/.DS_Store` | Finder noise (gitignored, still on disk) | **delete** |
| Lima VM `debug-demo-haproxy` (**Running**, 512 MiB) | Leftover from the retired single-node VIP-shim design; zero references in the repo (`grep -rn debug-demo-haproxy` → nothing); `k3s-uninstall.sh` won't touch it | **deleted** (2026-07-04) |
| Lima VMs `dns`, `haproxy`, `haproxy-b` (Stopped) | ~~Same era~~ **Correction:** their lima.yaml headers show they belong to a *different* project (multi-DC simulation, with the `dc1-k8s-*` VMs) | **keep — not ours** |
| `docs/debugging-tools-eval-prompt.md` (untracked) | This review's prompt; decide whether it's meant to be committed | **keep or commit intentionally** |

Checked and clean: no `install-stack.sh` references anywhere, no
`.claude/scheduled_tasks.lock`, no committed `.DS_Store`/lockfiles
(`git ls-files` grep → empty), `dumps/` and `scripts/.cache/` correctly
gitignored, `docs/k3s-architecture.md` and `docs/install-test-plan.md` both
exist and are referenced. `maven:3.9-eclipse-temurin-21` /
`eclipse-temurin:21-jre-alpine` in `K3S_IMAGES` are *not* cruft — they're the
Dockerfile's build/runtime stages, bundled so the app image builds air-gapped.

---

## 6. Docs-fidelity drift list (dimension 9 details)

1. **Java 25 vs 21** — README.md:3,541; CLAUDE.md:3,12,31,1003 vs
   `app/Dockerfile:3,10`, `app/pom.xml:22-23`, live JVM `21.0.11+10-LTS` (M5).
2. **README.md:554-555** (`dump-jattach.sh install` / `threads`, bare) — crash
   on stock bash (B2).
3. **README.md:560-561** — documents `dump-threads.sh` / `dump-heap.sh
   --confirm` as working; both are broken (B1), and the bare `--confirm`
   form also hits B2.
4. **CLAUDE.md:31** — names `eclipse-temurin:25-jdk-alpine` for the ephemeral
   path; image isn't in the air-gap bundle, so the documented command cannot
   run on the documented cluster (B1.3).
5. **CLAUDE.md "Pre-trigger automatic capture"** — claims
   `-XX:HeapDumpPath=/tmp/heapdumps` + emptyDir; not re-verified in this
   review (out of (B) scope) — flagging as unchecked rather than confirmed.
6. Cosmetic: CLAUDE.md's sample `memory-report.sh` output labels differ
   slightly from real output ("sum = area:heap" vs "sum should match
   area:heap") — harmless.

Everything else spot-checked matched: `-n/-l/--container` flags, dump naming
`${POD}-${ISO8601}`, `memory-report.sh` behavior and hints, jattach cache
location, `set-log-level.sh` semantics, doctor/chaos claims.

---

## 7. Capability-gap map (dimension 10 details)

| Recipe (CLAUDE.md) | One-command path today? | Gap |
|---|---|---|
| 1. Slow leak under steady load | No | load-gen is a README paste (`hpa-load` pod); no periodic-heap-dump loop, no MAT `ParseHeapDump.sh` wrapper for the diff |
| 2. Sudden OOM (oversized CSV) | No | no trigger script; no "pull `/tmp/heapdumps` before restart" helper (a race the docs themselves warn about — ideal automation target) |
| 3. GC thrash w/o OOM | No | no `jvm.gc.pause` watcher/alarmer; would be ~20 lines on top of the `memory-report.sh` actuator plumbing |
| 4. Thread starvation / deadlock | Partial | capture exists (jattach `Thread.print`); no inducer, no blocked-thread summarizer |
| 5. Hot-loop CPU spike | Partial | HPA exists; no load driver script, no scale-up-timing verifier |
| 6. MQ consumer lag | No | runbook has the `runmqsc` one-liner; nothing correlates MQ depth with `jms.message.processing.time` |

Runbook coverage: Steps 3 (logs), 5 (memory anatomy) have real tools; Steps
1–2 (pod status, health) are raw kubectl; Step 4 (top/HPA) raw kubectl; Step
6 (snapshot) is prose (M2). Missing entirely: an actuator-dump tool (M1), a
`--watch`/interval mode for trend questions ("is Metaspace *growing*?" — the
question the report's own hints ask but the tool can't answer), and any
`/actuator/prometheus` scrape/Grafana story beyond a doc mention.

---

## 8. Prioritized backlog

| # | Item | Why first | Effort |
|---|---|---|---|
| 1 | Fix B2 (bash-3.2-safe expansions in `dump-jattach.sh:73`, `dump-heap.sh:29`) | Documented commands crash on a stock Mac; 3-line fix unblocks everything else | **S** |
| 2 | Fix B1 (container name lowercase, `find_jvm_pid` reuse, add JDK-21 image to `K3S_IMAGES` or mark path online-only; fix the two wrong doc paragraphs) | The advertised last-resort tier has never worked | **S–M** |
| 3 | Add `dump-actuator.sh` (threaddump text/json; heapdump behind `--confirm`) | Makes the documented preference order real; trivial given existing plumbing | **S** |
| 4 | Add `snapshot.sh` (Step-6 bundle → `dumps/snapshot-<ts>/`) | Biggest single incident-time win; pure composition of existing tools | **M** |
| 5 | Uniform `-h/--help` via shared lib helper + echo-the-kubectl-command in (B) tools (match the (A/C) cookbook style) | Discoverability under pressure; fixes the tail-logs/memory-report `--help` traps | **S** |
| 6 | `debug.sh` + `debug-tui.sh` front door; one jump-in entry in `k3s-tui.sh` | Closes M3; establishes the extraction seam | **M** |
| 7 | `memory-report.sh` hardening: fail loudly instead of `print(0)`, handle `memory.max=max`, `--watch <sec>` mode | Turns a demo into an incident tool | **M** |
| 8 | Portability pass (context/kubeconfig/actuator-base/out-dir flags; split `lib/common.sh`; `debug-kit/` layout) | The 10-minute-lift goal; krew-able afterwards | **M–L** |
| 9 | Fix the Java-25-vs-21 doc drift everywhere (or actually move to 25 — decide once) | Every version-sensitive choice depends on it | **S** |
| 10 | Recipe drivers (load-gen, CSV-OOM trigger, GC-thrash watcher, MQ-lag correlator) | Completes the "toolkit targets these recipes" promise | **L** |
