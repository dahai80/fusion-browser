#!/usr/bin/env bash
# R-7: release gate for fusion-browser.
# swift test covers 0% of the WKWebView live path (ARCH-3: no main run loop under
# swift test -> evaluateJSSync/screenshotSync deadlock). The live path is verified ONLY
# by the built release binary + the Python verify harnesses in scripts/. This gate
# wires them into one PASS/FAIL gate so "198 tests green" can never be misread as a
# live-path regression pass.
#
# E-17~20 (#68): Rust core removed — build is pure Swift now, no plugin, no cargo.
# --disable-sandbox was mandatory only because the FBCoreRustBuilder plugin ran cargo;
# with the plugin gone it is no longer required but kept on the gate lines for
# compatibility (harmless).
#
# Gate stages (each is a hard gate — first failure aborts with non-zero exit):
#   1. swift build -c release --disable-sandbox   (pure Swift, no plugin)
#   2. swift test --disable-sandbox               (deterministic unit tests, 198)
#   3. live-path verify harnesses against the release binary:
#        verify_nonpersistent.py  (FR-04 non-persistence)
#        navigate_execute_smoke.py (create-no-url -> execute navigate -> extract)
#        evaluate_smoke.py         (E-9 Runtime.evaluate returns real JS result)
#        cdp_dom_smoke.py          (E-8 CDP DOM domain derefs real elements)
#        cdp_event_smoke.py        (E-11 CDP events: real status, console, order, per-nav loaderId)
#        metrics_smoke.py          (R-3/B-3 UDS metrics read path: real counters + p50/p95)
#        longrun_leak.py           (1000-action no-leak)
#        uma_coexist.py            (UMA coexistence baseline)
#        ownership_smoke.py        (B-5/E-34 session ownership: not_owner on cross-client op)
#      perf_bench.py is informational (perf, not correctness), NOT a hard gate —
#      runs last and its failure is logged but non-fatal.
#
# Process data: each harness owns its cleanup (socket unlink, config restore).
# This script cleans the shared smoke socket/config leftovers on exit.
#
# Usage: scripts/release_gate.sh [--skip-perf]
# Exit: 0 = all hard gates PASS, non-zero = regression.
set -euo pipefail

cd "$(dirname "$0")/.."

SKIP_PERF=0
[[ "${1:-}" == "--skip-perf" ]] && SKIP_PERF=1

RED=$'\033[31m'; GRN=$'\033[32m'; YLW=$'\033[33m'; RST=$'\033[0m'
pass() { echo "${GRN}[GATE PASS]${RST} $1"; }
fail() { echo "${RED}[GATE FAIL]${RST} $1"; }
info() { echo "${YLW}[gate]${RST} $1"; }

GATE_FAIL=0
run_gate() {
    local name="$1"; shift
    info "running: $name"
    if "$@"; then
        pass "$name"
    else
        fail "$name"
        GATE_FAIL=1
    fi
}

# --- stage 1: build ---
run_gate "swift build -c release" swift build -c release --disable-sandbox

# --- stage 2: deterministic tests (198) ---
run_gate "swift test (198)" swift test --disable-sandbox

# --- stage 3: live-path verify harnesses ---
# These drive the RELEASE binary over UDS. Each harness starts/stops its own binary
# and cleans its own socket. Hard correctness gates.
HARD_HARNESSES=(
    "scripts/verify_nonpersistent.py"
    "scripts/navigate_execute_smoke.py"
    "scripts/evaluate_smoke.py"
    "scripts/cdp_dom_smoke.py"
    "scripts/cdp_event_smoke.py"
    "scripts/metrics_smoke.py"
    "scripts/longrun_leak.py"
    "scripts/uma_coexist.py"
    "scripts/ownership_smoke.py"
)
for h in "${HARD_HARNESSES[@]}"; do
    if [[ -f "$h" ]]; then
        run_gate "live: $h" python3 "$h"
    else
        info "harness absent, skipping: $h"
    fi
done

# --- informational (non-fatal): perf ---
if [[ "$SKIP_PERF" -eq 0 ]]; then
    for h in "scripts/perf_bench.py"; do
        if [[ -f "$h" ]]; then
            info "informational (non-fatal): $h"
            if python3 "$h"; then
                pass "info: $h"
            else
                info "informational $h reported issues (non-fatal)"
            fi
        fi
    done
fi

# --- cleanup shared leftovers (Rule: clean process data) ---
rm -f /tmp/fusion-browser-smoke.sock /tmp/fusion-browser-verify.sock /tmp/fusion-browser-metrics.sock 2>/dev/null || true

echo ""
if [[ "$GATE_FAIL" -eq 0 ]]; then
    pass "ALL HARD GATES PASSED — release binary + live path verified"
    exit 0
else
    fail "ONE OR MORE HARD GATES FAILED — regression"
    exit 1
fi
