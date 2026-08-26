#!/usr/bin/env bash
#
# wgm/test-plugin-registry.sh — deterministic backpressure for the proposed plugin registry.
#
# This harness deliberately exercises both halves of the registry contract: metadata discovery
# with no declared dependency, and the real callable `invoke` path. A metadata-only assertion could
# pass while importlib loading or handler execution is broken ([learn] issue #105). The fixture lives
# under a temporary HOME, so the test never depends on or mutates an operator's installed plugins.
#
# Exit 0 = all assertions pass (GREEN); exit 1 = one or more failed (RED, described on stderr).

set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
REGISTRY="$ROOT/scripts/wgm_plugin_registry.py"
FAILED=0
pass() { printf 'ok:   %s\n' "$*"; }
fail() { printf 'FAIL: %s\n' "$*" >&2; FAILED=1; }

if ! command -v python3 >/dev/null 2>&1; then
  fail "python3 is required for the registry parity harness"
  echo "plugin registry harness: RED" >&2
  exit 1
fi
[[ -f "$REGISTRY" ]] || { fail "missing $REGISTRY"; exit 1; }

PARENT_HOME="${HOME-}"
TMP="$(mktemp -d "${TMPDIR:-/tmp}/wgm-plugin-registry-test.XXXXXX")"
PLUGIN_HOME="$TMP/home"
PLUGIN_DIR="$PLUGIN_HOME/.copilot/skills/parity_fixture"
MARKER="$TMP/handler.marker"
mkdir -p "$PLUGIN_DIR"
cleanup() { rm -rf "$TMP"; }
trap cleanup EXIT

cat >"$PLUGIN_DIR/plugin.toml" <<'EOF'
[plugin]
name = "parity_fixture"
version = "0.0.0"
description = "Temporary no-dependency parity fixture"
lifecycle = ["validate"]
requires = []
depends_on = []
timeout = 1
enabled_by_default = true
EOF

cat >"$PLUGIN_DIR/parity_fixture.py" <<'PYEOF'
from pathlib import Path


def invoke(hook_name, context):
    """Return a value derived from the call and leave proof that this handler ran."""
    if hook_name != "validate":
        return {"success": False, "error": f"unsupported hook: {hook_name}"}
    Path(context["marker"]).write_text("callable-handler-ran\n", encoding="utf-8")
    return {
        "success": True,
        "handler": "real-invoke",
        "observed": f"{context['subject']}:{hook_name}",
    }
PYEOF

OUT=""
RC=0
HOME="$PLUGIN_HOME" PYTHONPATH="$ROOT/scripts" PYTHONDONTWRITEBYTECODE=1 SOFA_API_KEY="" \
  python3 - "$MARKER" <<'PYRUN' >"$TMP/driver.out" 2>"$TMP/driver.err"
import sys
from pathlib import Path

from wgm_plugin_registry import check_soft_dependencies, discover_plugins, load_plugin

marker = Path(sys.argv[1])
plugins = discover_plugins()
if "parity_fixture" not in plugins:
    raise SystemExit("fixture was not discovered from the temporary HOME")
print("discovery=ok", flush=True)

metadata = plugins["parity_fixture"]
if metadata.get("depends_on") != [] or metadata.get("requires") != []:
    raise SystemExit("fixture unexpectedly has a dependency")
if check_soft_dependencies(metadata) != {}:
    raise SystemExit("no-dependency fixture reported a missing soft dependency")
print("dependencies=empty", flush=True)

result = load_plugin(
    "parity_fixture",
    "validate",
    {"phase": "validate", "subject": "issue-105", "marker": str(marker)},
)
if result.get("success") is not True:
    raise SystemExit(f"real handler did not report success: {result}")
if result.get("handler") != "real-invoke":
    raise SystemExit(f"unexpected handler result: {result}")
if result.get("observed") != "issue-105:validate":
    raise SystemExit(f"context-derived observation missing: {result}")
print("handler=real-invoke", flush=True)
print("observation=issue-105:validate", flush=True)

if marker.read_text(encoding="utf-8") != "callable-handler-ran\n":
    raise SystemExit("callable handler did not leave its execution marker")
print("marker=written-by-handler", flush=True)
PYRUN
RC=$?
OUT="$(cat "$TMP/driver.out" 2>/dev/null || true)"
ERR="$(cat "$TMP/driver.err" 2>/dev/null || true)"

if [[ "$RC" -eq 0 ]] && grep -q '^discovery=ok$' <<<"$OUT"; then
  pass "real registry discovers a plugin from the isolated HOME"
else
  fail "real registry discovery failed (rc=$RC): ${ERR:-$OUT}"
fi

if [[ "$RC" -eq 0 ]] && grep -q '^dependencies=empty$' <<<"$OUT"; then
  pass "no-dependency construction path needs no credential or package"
else
  fail "no-dependency path was not proven (rc=$RC): ${ERR:-$OUT}"
fi

if [[ "$RC" -eq 0 ]] && grep -q '^handler=real-invoke$' <<<"$OUT" \
   && grep -q '^observation=issue-105:validate$' <<<"$OUT" \
   && grep -q '^marker=written-by-handler$' <<<"$OUT"; then
  pass "load_plugin executes the real callable handler and returns an observable result"
else
  fail "real callable handler path was not proven (rc=$RC): ${ERR:-$OUT}"
fi

if [[ "${HOME-}" == "$PARENT_HOME" ]]; then
  pass "the parent process HOME remains unchanged after the isolated run"
else
  fail "the isolated run changed the parent process HOME"
fi

cleanup
trap - EXIT
if [[ ! -e "$TMP" ]]; then
  pass "temporary plugin fixture is cleaned up"
else
  fail "temporary plugin fixture was not cleaned up"
fi

if [[ "$FAILED" -eq 0 ]]; then
  echo "plugin registry harness: GREEN"
  exit 0
else
  echo "plugin registry harness: RED" >&2
  exit 1
fi
