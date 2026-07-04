# Install / pre-flight test plan

Verifies two things end to end:

1. **Pre-flight** (`scripts/k3s-preflight.sh`, step 0 of `./tui install`) detects
   every missing prerequisite and either **auto-fixes** it or prints the **exact
   command** to fix it.
2. **The full install** stands the stack up, and **uninstall** tears it all down.

How each gap is handled:

| Prerequisite | Missing → preflight does | Auto-fix? |
|---|---|---|
| Homebrew | offers to run the official installer | ✅ (offer) |
| CLI tools (limactl/kubectl/helm/curl) | `brew install …` | ✅ |
| **sudo / admin access** | warns + prints the IT ask | ❌ can't self-grant |
| socket_vmnet | `brew install socket_vmnet` | ✅ |
| Lima sudoers + shared network | `limactl sudoers \| sudo tee /etc/sudoers.d/lima` | ✅ (sudo) |
| Docker (bundle build) | `brew install --cask docker`, then `open -a Docker` + wait | ✅ |
| **github.com reachable** (bundle build) | prints proxy/mirror + copy-bundle workaround | ❌ can't unblock a network |
| **RAM** | warns + points at `K3S_*_MEM` | ❌ can't add RAM |

> ⚠️ **Read before breaking things:** `socket_vmnet` and `/etc/sudoers.d/lima`
> are shared by **every Lima VM on this Mac**, not just `ddk3s-*`. Removing them
> to test will briefly affect your other Lima instances too — restore them right
> after. The CLI-tool and bundle/Docker/github tests are isolated and safe.

Run each test with `./tui preflight` (interactive: it asks before each fix) or
`scripts/k3s-preflight.sh --check` (report only, changes nothing — best for just
seeing the ✘ + fix command without auto-fixing).

---

## Part A — pre-flight gap detection (break → verify → restore)

### A1. A CLI tool missing  *(safe, isolated)*
Rename the binary out of the way — this works no matter where the tool came
from (Homebrew, Rancher Desktop's `~/.rd/bin`, etc.). `brew unlink` is NOT
reliable: your `helm`/`kubectl` may not be Homebrew's.
```sh
H="$(command -v helm)"; mv "$H" "$H.off"     # break: helm gone from PATH
scripts/k3s-preflight.sh --check             # EXPECT: ✘ install CLI tools: helm  → brew install helm
mv "$H.off" "$H"                             # restore the original binary
# (If you instead run `./tui preflight` and answer Y, it runs `brew install
#  helm`, which installs a *Homebrew* copy — restore your original PATH order
#  or `brew uninstall helm` afterward.)
```

### A2. Lima sudoers missing  *(affects all Lima VMs — restore right after)*
```sh
sudo rm -f /etc/sudoers.d/lima        # break
limactl sudoers --check; echo $?      # EXPECT: non-zero (needs setup)
scripts/k3s-preflight.sh --check      # EXPECT: ✘ configure Lima sudoers → limactl sudoers | sudo tee …
./tui preflight                       # EXPECT: offers it; Y → sudo prompt → recreated, ✔  (this is the restore)
```

### A3. socket_vmnet missing  *(affects all Lima VMs — reinstall right after)*
```sh
brew uninstall socket_vmnet           # break (heavier; unlink alone won't hide the keg path)
scripts/k3s-preflight.sh --check      # EXPECT: ✘ install socket_vmnet → brew install socket_vmnet
./tui preflight                       # EXPECT: offers it; Y → reinstalled, ✔
limactl sudoers | sudo tee /etc/sudoers.d/lima >/dev/null   # restore the sudoers it references
```

### A4. Bundle missing + Docker stopped  *(safe, isolated)*
```sh
mv dumps/airgap /tmp/airgap.bak       # break: bundle gone → Docker now required
osascript -e 'quit app "Docker"' 2>/dev/null || killall Docker 2>/dev/null   # stop Docker
scripts/k3s-preflight.sh --check      # EXPECT: ✘ Docker isn't running → open -a Docker
./tui preflight                       # EXPECT: launches Docker, waits up to 60s, ✔ (if it starts)
mv /tmp/airgap.bak dumps/airgap       # restore the bundle
```

### A5. Bundle missing + github blocked  *(corporate-MITM simulation)*
```sh
mv dumps/airgap /tmp/airgap.bak                        # break: bundle gone → sources checked
echo "127.0.0.1 github.com" | sudo tee -a /etc/hosts   # block github
scripts/k3s-preflight.sh --check      # EXPECT: ✘ can't reach github.com → proxy/mirror + copy-bundle workaround
# restore:
sudo sed -i '' '/[[:space:]]github.com$/d' /etc/hosts
mv /tmp/airgap.bak dumps/airgap
```

### A6. Low RAM  *(can't remove RAM — verify the fitted-profile advice)*
The check reads `sysctl hw.memsize` (passes when `mem ≥ VM budget + ~4 GiB for
macOS). On a short Mac it doesn't just fail — it computes a **smaller profile
sized to your RAM** and prints the exact override to try, e.g.:
```
⚠ RAM: 16 GiB — the default VMs need 18 GiB (+~4 for macOS). You can shrink them and try:
   K3S_SERVER_MEM=2 K3S_AGENT_MEM=4 K3S_LB_MEM=1 ./tui install
   (tight — 4 GiB agents may OOM under Oracle+MQ+Valkey+app; install fewer charts or use a bigger Mac)
```
Those env vars are honored end-to-end (k3s-env.sh → cluster + LB VM sizing), and
persist if you edit `scripts/lib/k3s-env.sh` instead of prefixing each command.
Try it live by actually installing with a smaller profile:
```sh
K3S_SERVER_MEM=2 K3S_AGENT_MEM=5 K3S_LB_MEM=1 ./tui install   # then ./tui doctor / smoke
```

### A7. sudo / non-admin  *(describe — needs a non-admin account to truly test)*
On a non-admin account the check prints:
`⚠ your account can't sudo … ask IT to run 'limactl sudoers | sudo tee /etc/sudoers.d/lima', or use an admin account.`
The sudoers/resolver steps then hard-fail (can't `sudo tee`), with the same command to hand to IT.

### A8. Everything present  *(the happy path)*
```sh
scripts/k3s-preflight.sh              # EXPECT: 7 ✔ and "Pre-flight passed"
```

---

## Part B — full install → verify → uninstall

```sh
# 0. prerequisites (auto-fixes / instructs anything missing)
./tui preflight

# 1. full install — preflight → bundle → 3 k3s VMs + LB VM → k3s → DNS →
#    ingress → charts → LB tier → smoke  (~15-20 min first time; the bundle
#    build needs internet, everything after is air-gapped)
./tui install

# 2. health across every layer (VMs, VIP on ddk3s-lb, DNS, ingress, workloads,
#    Valkey cluster, end-to-end) — expect all ✔ except the optional Mac resolver
./tui doctor

# 3. end-to-end smoke, all by hostname — expect 14/14
./tui smoke

# 4. (optional) exhaustive Valkey protocol suite — expect 58/58
scripts/valkey-cluster-tests.sh --skip-failover      # add nothing for the full failover cycle

# 5. (optional) resilience drills
./tui chaos node-down agent-1        # stop a worker → pods reschedule; VIP unaffected (it's on ddk3s-lb)
./tui chaos heal node-down
./tui chaos lb-down                  # stop the LB VM → VIP + access down (SPOF drill)
./tui chaos heal lb-down

# 6. use it (HTTP by hostname through the VIP)
curl --resolve debug-demo.local:80:192.168.105.100 http://debug-demo.local/actuator/health

# 7. tear down — expect "removed ddk3s-server / -agent-1 / -agent-2 / -lb"
./tui uninstall
limactl list | grep ddk3s || echo "all ddk3s VMs gone"
```

### B — install idempotency / resume
```sh
./tui install        # run it again on a healthy stack → each phase is a no-op / upgrade, ends green
```

### B — VIP-taken path (pre-flight for the VIP itself)
```sh
# With something already on .100, install aborts with a free-VIP recipe:
K3S_VIP=192.168.105.240 ./tui install   # install onto a different VIP; it persists (dumps/k3s-vip)
```

---

## Expected end state
- `./tui doctor` → 23/24 (only ✘ = optional Mac `/etc/resolver`, or 24/24 after `./tui resolver`)
- `./tui smoke` → 14/14
- 4 VMs Running: `ddk3s-server` (tainted control-plane), `ddk3s-agent-1/2` (workers), `ddk3s-lb` (VIP + HAProxy)
- After `./tui uninstall`: `limactl list` shows no `ddk3s-*` instances
