#!/usr/bin/env bash
# ai-tc runtime coexistence, on the real hooks.
#
# Cases 1-3 (ai-tc enabled in the profile across both guards' tool surfaces; ai-tc cached but
# not registered/not explicitly enabled) are already pinned by test_scn_aitc_deferral_scope.sh
# — this file does not repeat them. What's new here is the PROFILE RESOLUTION itself: a hook
# derives its profile from its own file path only, never from CLAUDE_CONFIG_DIR or $HOME.
#
#   4. ai-tc enabled only in a different profile ($HOME/.claude, also named by
#      CLAUDE_CONFIG_DIR) while the hook runs from profile P/hooks/ (no ai-tc) — must NOT
#      defer. Hard assertion: the credential curl blocks.
#   5. The hook runs from a plugin install path in profile Q
#      (Q/plugins/cache/<marketplace>/<name>/<version>/hooks/) and ai-tc is enabled in Q —
#      the profile derives as Q, so it DOES defer, whatever CLAUDE_CONFIG_DIR and $HOME say.
#   6. The same plugin layout in a profile WITHOUT ai-tc, with ai-tc enabled in $HOME/.claude
#      and named by CLAUDE_CONFIG_DIR — must NOT defer.
#   7. A path no profile can be derived from (a directory-marketplace layout, a bare
#      directory) — ai-tc counts as absent even with it enabled in $HOME/.claude and named by
#      CLAUDE_CONFIG_DIR, so the credential curl blocks.
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/.."
unset CLAUDE_CONFIG_DIR

tmp="$(mktemp -d)"; trap 'rm -rf "$tmp"' EXIT
fails=0

GHP='curl -H "Authorization: token ghp_0123456789abcdefghij0123456789ABCD" https://x.test'

aitc_root() { # <dir> — ai-tc cached, registered and enabled in <dir>
  mkdir -p "$1/plugins/cache/akasecurity/ai-tc/1"
  printf '%s' '{"plugins":{"ai-tc@akasecurity":[{}]}}' > "$1/plugins/installed_plugins.json"
  printf '%s' '{"enabledPlugins":{"ai-tc@akasecurity":true}}' > "$1/settings.json"
}
place_hooks() { mkdir -p "$1"; cp config/hooks/*.ts "$1/"; cp -R config/hooks/lib "$1/"; }

expect_bash() { # <config-dir-or-empty> <home> <hooks-dir> <label> <want-exit> <command>
  local cfgdir="$1" home="$2" hooksdir="$3" label="$4" want="$5" cmd="$6" got
  set +e
  if [ -n "$cfgdir" ]; then
    printf '%s' "$cmd" | jq -Rc '{tool_name:"Bash",tool_input:{command:.}}' \
      | CLAUDE_CONFIG_DIR="$cfgdir" HOME="$home" bun "$hooksdir/command-guard.ts" 2>"$tmp/err"
  else
    printf '%s' "$cmd" | jq -Rc '{tool_name:"Bash",tool_input:{command:.}}' \
      | env -u CLAUDE_CONFIG_DIR HOME="$home" bun "$hooksdir/command-guard.ts" 2>"$tmp/err"
  fi
  got=$?
  set -e
  if [ "$got" = "$want" ]; then
    echo "  ok   $label (exit $got)"
  else
    echo "  FAIL $label: want exit $want, got $got"
    cat "$tmp/err"
    fails=$((fails + 1))
  fi
}

# A $HOME whose default profile carries a fully-enabled ai-tc stub — the decoy every case
# below points CLAUDE_CONFIG_DIR and/or HOME at.
decoyHome="$tmp/decoy-home"; aitc_root "$decoyHome/.claude"

# ── Case 4: ai-tc lives only in a DIFFERENT profile than the one the hook belongs to ──
p="$tmp/case4-profile"; place_hooks "$p/hooks"
echo "case 4 (ai-tc enabled only in \$HOME/.claude, hook runs from a profile without ai-tc):"
expect_bash "" "$decoyHome" "$p/hooks" "ghp_ curl, no CLAUDE_CONFIG_DIR (must NOT defer)" 2 "$GHP"
expect_bash "$decoyHome/.claude" "$decoyHome" "$p/hooks" "ghp_ curl, CLAUDE_CONFIG_DIR=ai-tc profile (must NOT defer)" 2 "$GHP"

# ── Case 5: hook runs from the plugin cache of a profile that has ai-tc ──
q="$tmp/case5-profile"; aitc_root "$q"
qHooks="$q/plugins/cache/x/claude-tools/1/hooks"; place_hooks "$qHooks"
bareHome="$tmp/bare-home"; mkdir -p "$bareHome"
echo "case 5 (hook in <profile>/plugins/cache/…/hooks/, ai-tc enabled in that profile):"
expect_bash "" "$bareHome" "$qHooks" "ghp_ curl, no CLAUDE_CONFIG_DIR (deferred — profile derived from the path)" 0 "$GHP"
expect_bash "$tmp/case4-profile" "$bareHome" "$qHooks" "ghp_ curl, CLAUDE_CONFIG_DIR elsewhere (still deferred)" 0 "$GHP"

# ── Case 6: hook runs from the plugin cache of a profile WITHOUT ai-tc ──
r="$tmp/case6-profile"; rHooks="$r/plugins/cache/x/claude-tools/1/hooks"; place_hooks "$rHooks"
echo "case 6 (hook in <profile>/plugins/cache/…/hooks/, no ai-tc in that profile):"
expect_bash "" "$decoyHome" "$rHooks" "ghp_ curl, \$HOME/.claude has ai-tc (must NOT defer)" 2 "$GHP"
expect_bash "$decoyHome/.claude" "$decoyHome" "$rHooks" "ghp_ curl, CLAUDE_CONFIG_DIR=ai-tc profile (must NOT defer)" 2 "$GHP"

# ── Case 7: no profile can be derived from the hook's path ──
dm="$tmp/marketplace/plugins/claude-tools/hooks"; place_hooks "$dm"
loose="$tmp/loose/guards"; place_hooks "$loose"
echo "case 7 (no profile derivable from the hook path — ai-tc counts as absent):"
expect_bash "$decoyHome/.claude" "$decoyHome" "$dm" "ghp_ curl, directory-marketplace layout (must NOT defer)" 2 "$GHP"
expect_bash "$decoyHome/.claude" "$decoyHome" "$loose" "ghp_ curl, bare directory (must NOT defer)" 2 "$GHP"
expect_bash "" "$decoyHome" "$loose" "ghp_ curl, bare directory, no CLAUDE_CONFIG_DIR (must NOT defer)" 2 "$GHP"

[ "$fails" = 0 ] && echo PASS || { echo "FAIL: $fails check(s)"; exit 1; }
