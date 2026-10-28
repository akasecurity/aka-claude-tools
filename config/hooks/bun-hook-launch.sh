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
# Optional resident hook client for command-guard: it answers the hook itself, keeping the guard
# loaded between calls, and runs `bun <guard>` when it cannot. It is named only by a line
#   CT_HOOK_CLIENT=/absolute/path
# in the aka-claude-tools.config beside this launcher's hooks/ directory (the file the guards read),
# found from the launcher's own path and never from an environment variable, and is called as
#   <client> command-guard <bun> <guard>
# with the hook's stdin; its exit status and output are the hook's. The config and the client must be
# regular files owned by this user and not writable by group or others; otherwise bun runs the guard.
_owned() {
  [ -f "$1" ] && [ -O "$1" ] && [ -z "$(find "$1" -prune \( -perm -g+w -o -perm -o+w \) 2>/dev/null)" ]
}
case "$0:${SCRIPT##*/}" in
  /*:command-guard.ts)
    _cfg="${0%/*}/../aka-claude-tools.config"
    if _owned "$_cfg"; then
      _client="$(sed -n "s/^CT_HOOK_CLIENT=[\"']\{0,1\}\(\/[^\"']*\)[\"']\{0,1\}[[:space:]]*\$/\1/p" "$_cfg" | tail -n 1)"
      if [ -n "$_client" ] && [ -x "$_client" ] && _owned "$_client"; then
        exec "$_client" command-guard "$bun_bin" "$SCRIPT"
      fi
    fi ;;
esac
exec "$bun_bin" "$SCRIPT"
