#!/usr/bin/env bash
set -uo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/.."
L="config/hooks/bun-hook-launch.sh"
tmp="$(mktemp -d)"; trap 'rm -rf "$tmp"' EXIT
fails=0
# fake bun that proves the guard ran and echoes stdin
printf '#!/usr/bin/env sh\necho "RAN $1 <$(cat)>"; exit 5\n' > "$tmp/bun"; chmod +x "$tmp/bun"

# CASE 1: bun on PATH -> launcher execs it (guard runs), exit passes through (5)
out="$(printf '{"t":1}' | PATH="$tmp:$PATH" "$L" /g.ts)"; rc=$?
[[ "$out" == 'RAN /g.ts <{"t":1}>' && $rc -eq 5 ]] || { echo "FAIL case1: '$out' rc=$rc"; fails=1; }

# CASE 2: bun only at ~/.bun/bin (off PATH) -> probe finds it
mkdir -p "$tmp/h/.bun/bin"; cp "$tmp/bun" "$tmp/h/.bun/bin/bun"
out="$(printf '{}' | env -i HOME="$tmp/h" PATH=/usr/bin:/bin "$L" /g.ts)"; rc=$?
[[ "$out" == 'RAN /g.ts <{}>' && $rc -eq 5 ]] || { echo "FAIL case2: '$out' rc=$rc"; fails=1; }

# CASE 3: bun absent everywhere -> FAIL OPEN: exit 0, warning on stderr, no block
err="$(printf '{}' | env -i HOME="$tmp/none" PATH=/usr/bin:/bin AKA_BUN_CANDIDATES="/no/bun" "$L" /g.ts 2>&1 1>/dev/null)"; rc=$?
[[ $rc -eq 0 ]] || { echo "FAIL case3 must fail-open (exit 0) got rc=$rc"; fails=1; }
[[ "$err" == *"guard INACTIVE"* ]] || { echo "FAIL case3 must warn loudly: '$err'"; fails=1; }

# CASE 4: no guard-script arg -> FAIL OPEN (exit 0), no unbound-variable abort
printf '{}' | "$L" >/dev/null 2>&1; rc=$?
[[ $rc -eq 0 ]] || { echo "FAIL case4: zero-arg must fail-open (exit 0) got rc=$rc"; fails=1; }

# The resident client cases run a copy of the launcher from a sandbox root by its absolute path;
# the config it reads is <root>/aka-claude-tools.config, beside its hooks/ directory.
R="$tmp/root"; mkdir -p "$R/hooks"; cp "$L" "$R/hooks/bun-hook-launch.sh"; LA="$R/hooks/bun-hook-launch.sh"
CFG="$R/aka-claude-tools.config"
printf '#!/usr/bin/env sh\necho "CLIENT $1 $2 $3 <$(cat)>"; exit 7\n' > "$tmp/client"; chmod 700 "$tmp/client"

# CASE 5: a client named in the config beside the launcher -> command-guard goes to it with
# <name> <bun> <guard> and the stdin; its exit status is the hook's
printf 'CT_HOOK_CLIENT="%s"\n' "$tmp/client" > "$CFG"; chmod 600 "$CFG"
out="$(printf '{"t":2}' | PATH="$tmp:$PATH" "$LA" /x/command-guard.ts)"; rc=$?
[[ "$out" == "CLIENT command-guard $tmp/bun /x/command-guard.ts <{\"t\":2}>" && $rc -eq 7 ]] || { echo "FAIL case5: '$out' rc=$rc"; fails=1; }

# CASE 6: the client is never taken from the environment: CT_HOOK_CLIENT=/usr/bin/true (or our own
# client) in the env must not skip any guard
for c in /usr/bin/true "$tmp/client"; do
  for g in /x/command-guard.ts /x/leak-guard.ts; do
    out="$(printf '{}' | PATH="$tmp:$PATH" CT_HOOK_CLIENT="$c" "$L" "$g")"; rc=$?
    [[ "$out" == "RAN $g <{}>" && $rc -eq 5 ]] || { echo "FAIL case6 (env $c, $g): '$out' rc=$rc"; fails=1; }
  done
done

# CASE 7: nor is the config found through the environment: CLAUDE_CONFIG_DIR naming a user-owned
# dir with a valid config and client still runs bun
mkdir -p "$tmp/envcfg"; printf 'CT_HOOK_CLIENT=%s\n' "$tmp/client" > "$tmp/envcfg/aka-claude-tools.config"
chmod 600 "$tmp/envcfg/aka-claude-tools.config"
out="$(printf '{}' | PATH="$tmp:$PATH" CLAUDE_CONFIG_DIR="$tmp/envcfg" HOME="$tmp/envcfg" "$L" /x/command-guard.ts)"; rc=$?
[[ "$out" == 'RAN /x/command-guard.ts <{}>' && $rc -eq 5 ]] || { echo "FAIL case7: '$out' rc=$rc"; fails=1; }

# CASE 8: only command-guard is handed to the client, and only by a launcher run by absolute path
out="$(printf '{}' | PATH="$tmp:$PATH" "$LA" /x/leak-guard.ts)"; rc=$?
[[ "$out" == 'RAN /x/leak-guard.ts <{}>' && $rc -eq 5 ]] || { echo "FAIL case8 (leak-guard): '$out' rc=$rc"; fails=1; }
out="$(cd "$R" && printf '{}' | PATH="$tmp:$PATH" hooks/bun-hook-launch.sh /x/command-guard.ts)"; rc=$?
[[ "$out" == 'RAN /x/command-guard.ts <{}>' && $rc -eq 5 ]] || { echo "FAIL case8 (relative): '$out' rc=$rc"; fails=1; }

# CASE 9: a config client that is relative, missing, not executable, not owned by this user
# (/usr/bin/true), or group/world-writable -> bun runs the guard
printf 'echo no\n' > "$tmp/noexec"; chmod 600 "$tmp/noexec"
cp "$tmp/client" "$tmp/gw"; chmod 770 "$tmp/gw"; cp "$tmp/client" "$tmp/ow"; chmod 707 "$tmp/ow"
for c in client "$tmp/missing" "$tmp/noexec" /usr/bin/true "$tmp/gw" "$tmp/ow" ""; do
  printf 'CT_HOOK_CLIENT=%s\n' "$c" > "$CFG"
  out="$(printf '{}' | PATH="$tmp:$PATH" "$LA" /x/command-guard.ts)"; rc=$?
  [[ "$out" == 'RAN /x/command-guard.ts <{}>' && $rc -eq 5 ]] || { echo "FAIL case9 ($c): '$out' rc=$rc"; fails=1; }
done

# CASE 10: a group- or world-writable config is ignored, even when it names a good client
printf 'CT_HOOK_CLIENT=%s\n' "$tmp/client" > "$CFG"
for m in 620 602; do
  chmod "$m" "$CFG"
  out="$(printf '{}' | PATH="$tmp:$PATH" "$LA" /x/command-guard.ts)"; rc=$?
  [[ "$out" == 'RAN /x/command-guard.ts <{}>' && $rc -eq 5 ]] || { echo "FAIL case10 ($m): '$out' rc=$rc"; fails=1; }
done

# CASE 11: the guard runs from /, whatever the caller's working directory
printf '#!/usr/bin/env sh\npwd\n' > "$tmp/pwdbun"; mkdir -p "$tmp/pb"; cp "$tmp/pwdbun" "$tmp/pb/bun"; chmod +x "$tmp/pb/bun"
out="$(cd "$tmp" && printf '{}' | PATH="$tmp/pb:$PATH" "$OLDPWD/$L" /g.ts)"
[[ "$out" == "/" ]] || { echo "FAIL case11: guard cwd '$out'"; fails=1; }

[ "$fails" -eq 0 ] && echo "PASS test_plugin_launcher" || exit 1
