# Prompt — evaluate the debugging capability + TUI

> Hand this to a fresh reviewer (a new Claude Code session, a subagent, or a
> human). It is self-contained: everything needed is in the repo. Be concrete
> and critical — this is a design review of the project's **primary
> deliverable**, not a rubber stamp. No vague praise; cite `file:line` and show
> commands.

## Role & framing

You are a senior SRE / JVM-platform engineer. Standing up the k3s cluster + the
Spring Boot app was scaffolding; the **point of this project is the debugging
capability** — tools that diagnose memory- and CPU-related issues in JVM pods on
Kubernetes **without JDK tools in the image** (JRE-only runtime; capture goes
through actuator → `jattach` → an ephemeral JDK container, in that preference
order). Read `CLAUDE.md` (esp. "Test tools", "Analyzing dumps", "Recipes", the
Step 1–6 runbook) and the memory file
`~/.claude/projects/-Users-techdesigns-dev-debugging-java-springboot-k8s/memory/k8s_gotchas.md`
before judging anything, so you evaluate against the intended design, not your
assumptions.

## Step 0 — inventory (do this first, don't trust the list below)

List every file in `scripts/` (and `./tui`) and classify each as:
- **(A) cluster lifecycle** — install/teardown/networking/LB (`k3s-install`,
  `k3s-cluster`, `k3s-net`, `k3s-platform`, `k3s-charts`, `k3s-lb`,
  `k3s-preflight`, `k3s-uninstall`, `bundle-images`, `k3s.sh`, `k3s-tui.sh`)
- **(B) debugging / diagnostics capability** — the focus of this review:
  `dump-threads.sh`, `dump-heap.sh`, `dump-jattach.sh`, `memory-report.sh`,
  `tail-logs.sh`, `set-log-level.sh` (and the diagnostic parts of `k3s-doctor.sh`
  / `k3s-chaos.sh`)
- **(C) app / API tours + protocol tests** — `api-tour.sh`, `valkey-tour.sh`,
  `valkey-cluster-tests.sh`, `k3s-smoke.sh`
- **(D) build / CI** — `run-unit-tests.sh`, `local-ci.sh`
- **(E) shared lib** — `lib/common.sh`, `lib/k3s-env.sh`

Confirm the real classification against the directory; note anything that
doesn't fit or straddles categories. **Category (B) is what you are grading.**

## Evaluation dimensions

Score each **1–5** with concrete evidence (`file:line`, sample output, a
command you ran). A 5 needs proof, not vibes.

1. **Correctness & the no-JDK constraint.** Do the capture tools actually work
   JRE-only? Is the actuator → jattach → ephemeral-JDK preference order honored
   and documented per tool? Any tool that quietly assumes a JDK in the image
   (that would be a design violation)? Does `dump-jattach.sh` correctly find the
   JVM PID (not the `/pause` PID 1 under `shareProcessNamespace`), match
   arch/libc, and use the `jcmd` action so output is capturable?

2. **Code quality & safety.** Error handling, `set -euo pipefail` hygiene,
   idempotency, cleanup of ephemeral debug containers. Are **destructive**
   operations gated? (Heap dump freezes the JVM — is `--confirm` required and is
   it labeled "destructive in production"? Same for anything that restarts pods
   or scales workloads.) Any foot-guns?

3. **Ease of use & discoverability.** Consistent `--help` on every tool?
   Consistent flags (`-n <ns>`, `-l <selector>`)? Sensible defaults? Does each
   tool print the exact `kubectl`/`curl` it runs (copy-paste cookbook), and tell
   you the next step? Could an on-call engineer who has never seen the repo use
   `dump-jattach.sh` under pressure from `--help` alone?

4. **TUI coverage of the debug tools.** The current `k3s-tui.sh` menu is
   lifecycle-first (install/doctor/smoke/chaos/tours). Are the **capture** tools
   (threads/heap/jattach/jcmd, `memory-report`, `tail-logs`, `set-log-level`)
   reachable from it at all? If not, is that a gap? Rate how well the TUI
   surfaces the actual debugging workflow (the Step 1–6 runbook and the 6
   recipes).

5. **Should the debug tools have their OWN front door?** Argue both sides. The
   debug tools are conceptually independent of *this* cluster's lifecycle — they
   should work against **any** JVM-on-k8s pod. Decide: keep them in the one TUI,
   add a "Debug" submenu, or split a dedicated `./debug` / `scripts/debug.sh`
   front door (+ its own TUI) that takes `-n/-l/--context` and is cluster-
   agnostic. If you recommend a split, **propose the concrete menu** (grouped by
   the runbook: triage → capture → memory anatomy → live metrics → logs →
   snapshot bundle) and say what moves where.

6. **Portability / extraction.** Could someone lift the debug kit into a
   different repo and point it at their own Spring Boot pod in ~10 minutes?
   Identify every coupling point that would block that, e.g.:
   - `lib/common.sh` auto-targeting `dumps/k3s.kubeconfig` (assumes this repo's
     layout / this cluster)
   - `lib/k3s-env.sh` hardcoding `APP_HOST`, namespaces, `debug-demo` label
     selectors, VIP, Valkey specifics
   - assumptions about `dumps/{threads,heap}/` output paths
   - the `eclipse-temurin:25-jdk-alpine` ephemeral image / actuator port 8080
   Then specify the **minimal drop-in kit**: which files, what to parameterize
   (namespace, selector, actuator path, kubeconfig/context), and what a
   `debug-kit/` folder + one-line usage would look like. Bonus: could it be a
   `krew` plugin or a single curl-able script?

7. **Consistency & conventions.** Naming (`k3s-*` vs bare), dump-file naming
   (`${POD}-${ISO8601}`), duplicated color/`info`/`ok`/`bad` helpers across
   scripts (should they be in `lib/`?), flag styles, exit-code conventions.
   Where does (B) diverge from the house style set by (A)?

8. **Straggler files / cruft.** Find orphans and half-migrations: scripts
   nobody calls, dead code paths, docs/README/CLAUDE lines pointing at removed
   files, leftover lockfiles (`.claude/scheduled_tasks.lock`), stale
   `install-stack.sh`-era references, unused `lib/` functions, empty dirs,
   committed artifacts that should be gitignored. For each: `path` → why it's a
   straggler → keep / fix / delete.

9. **Docs fidelity.** Do the tools match what `CLAUDE.md` and `README.md`
   claim (flags, output, file paths, the runbook commands)? List every drift.

10. **Capability gaps.** Map the tools to the **6 recipes** (slow leak, sudden
    OOM, GC thrash, thread starvation, CPU spike, MQ consumer lag) and the Step
    1–6 runbook. Is there a clear path (ideally one command) per recipe? Is
    there a one-shot **snapshot bundle** collector (the "Step 6" bundle:
    metrics + threaddump + memory-report + jcmd outputs, zipped for offline
    MAT/VisualVM)? Continuous metrics via `/actuator/prometheus`? What's
    missing that a real incident would need?

## How to evaluate (method)

- Read each **(B)** script top to bottom. Don't skim.
- Run `--help` on every tool; capture the output; grade it.
- If a cluster is up (`./tui status` shows VMs Running), **dry-run the safe,
  read-only tools** against it and paste real output: `scripts/memory-report.sh
  -n debug-demo`, `scripts/dump-jattach.sh jcmd "GC.heap_info" -n debug-demo`,
  a `text/plain` actuator threaddump, `scripts/tail-logs.sh` (briefly). **Do
  NOT** run destructive ones (heap dump, chaos, scale-to-zero) — note that you
  skipped them and why.
- `grep -rn` across the repo to prove orphans (a script/file referenced by
  nothing) and doc drift (a doc naming a path that no longer exists).
- Prefer evidence you generated over claims in the docs.

## Deliverables (write to `docs/debugging-tools-eval.md`)

1. **Scorecard** — a table: dimension → score (1–5) → one-line justification.
2. **Findings by severity** — Blocker / Major / Minor, each with `file:line`
   and a suggested fix.
3. **The "own TUI" decision** — a clear recommendation with rationale, and if
   "yes", the concrete proposed menu + what moves.
4. **Portability report** — the exact coupling points, and a numbered plan to
   extract a standalone, cluster-agnostic debug kit (what to parameterize, the
   proposed `debug-kit/` layout, one-line usage).
5. **Straggler-file list** — `path` → reason → keep/fix/delete.
6. **Prioritized backlog** — the ordered next steps for the debugging phase
   (biggest usability/portability win first), with rough effort (S/M/L).

Keep it specific and skimmable. Every claim should be checkable.
