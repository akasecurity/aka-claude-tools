#!/usr/bin/env sh
# aka-claude-tools:managed-hook — plugin guard launcher. Resolves bun even when Claude Code's
# hook PATH is minimal, so the guard actually runs. FAIL-OPEN: if bun is genuinely absent, warn
# and exit 0 (the tool proceeds) — never block the user. Loudness is the SessionStart preflight.
# Registered as: "${CLAUDE_PLUGIN_ROOT}/hooks/bun-hook-launch.sh" "${CLAUDE_PLUGIN_ROOT}/hooks/<guard>.ts"
set -u
SCRIPT="${1:-}"
if [ -z "$SCRIPT" ]; then
  printf '[aka-claude-tools] guard launcher called with no script — allowing (fail-open).\n' >&2
  exit 0
fi
# candidate locations (override in tests via AKA_BUN_CANDIDATES)
_cands="${AKA_BUN_CANDIDATES:-$HOME/.bun/bin/bun /opt/homebrew/bin/bun /usr/local/bin/bun $HOME/.local/bin/bun}"
bun_bin=""
if command -v bun >/dev/null 2>&1; then
  bun_bin="$(command -v bun)"
else
  for c in $_cands; do [ -x "$c" ] && { bun_bin="$c"; break; }; done
fi
if [ -z "$bun_bin" ]; then
  printf '[aka-claude-tools] guard INACTIVE: bun not found — this tool is NOT being scanned. Install bun (https://bun.sh) to activate the guard.\n' >&2
  exit 0   # FAIL OPEN — never block
fi
# The guards read the session's directory from the hook input, never from their own working
# directory, so start bun from / : bun's start-up slows with a very large working directory.
cd / 2>/dev/null || :
# Optional resident hook client: CT_HOOK_CLIENT (an absolute path to an executable) answers the hook
# itself, keeping the guard loaded between calls, and runs `bun <guard>` when it cannot. Called as
#   $CT_HOOK_CLIENT <guard name> <bun> <guard>   (guard name = the script's file name without .ts)
# with the hook's stdin; its exit status and output are the hook's.
case "${CT_HOOK_CLIENT:-}" in
  /*) if [ -x "$CT_HOOK_CLIENT" ]; then
        _name="${SCRIPT##*/}"
        exec "$CT_HOOK_CLIENT" "${_name%.ts}" "$bun_bin" "$SCRIPT"
      fi ;;
esac
exec "$bun_bin" "$SCRIPT"
