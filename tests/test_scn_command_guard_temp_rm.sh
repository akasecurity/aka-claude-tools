#!/usr/bin/env bash
# Scenario — command-guard blocks a glob (or the root itself) over the shared temp folders.
#
# /tmp, /var/tmp and the per-user /var/folders/*/*/T are shared by every session on the host. A
# globbed `rm -rf /tmp/tmp.*` removes other sessions' working directories (seen: a worktree's
# gate scratch deleted mid-run). The guard blocks rm/rmdir/unlink, and find -delete / -exec rm,
# when a path in the shared root has a glob in the root itself, selects among its entries with a
# short or generic prefix (`tmp.*`, `t*`), or names the root. A distinctive own prefix
# (/tmp/wdcap-*.txt), a literal name, a glob below the first level, quoted globs and variables
# are allowed. Strings are only parsed, never run.
#
# Needs bun (command-guard's runtime; the suite already requires it).
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
echo "test_scn_command_guard_temp_rm:"

CG="$REPO_ROOT/config/hooks/command-guard.ts"
SB="$(sandbox)"
if ! command -v bun >/dev/null 2>&1; then echo "  (skip — bun not present)"; t_summary; exit $?; fi

# chk <expected-exit> <desc> <command>
chk() {
  jq -nc --arg c "$3" '{tool_name:"Bash",tool_input:{command:$c}}' > "$SB/in.json"
  bun "$CG" < "$SB/in.json" >/dev/null 2>&1
  assert_eq "$2" "$1" "$?"
}

# ── BLOCK (exit 2) ────────────────────────────────────────────────────────────
chk 2 "block: glob in the folders path"            'rm -rf /var/folders/*/*/T/tmp.*'
chk 2 "block: everything in /tmp"                  'rm -rf /tmp/*'
chk 2 "block: tmp.* in /tmp"                       'rm -rf /tmp/tmp.*'
chk 2 "block: everything in TMPDIR"                'rm -rf $TMPDIR/*'
chk 2 "block: sudo rm over the temp dir"           'sudo rm -rf /var/folders/*/*/T/*'
chk 2 "block: find -delete over /tmp, generic name" "find /tmp -name 'tmp.*' -delete"
chk 2 "block: find -exec rm over TMPDIR"           'find $TMPDIR -exec rm -rf {} +'
chk 2 "block: after cd &&"                         'cd x && rm -rf /tmp/*'
chk 2 "block: the root itself"                     'rm -rf /tmp'
chk 2 "block: the root with a slash"               'rm -rf /tmp/'
chk 2 "block: quoted TMPDIR root"                  'rm -rf "$TMPDIR"'
chk 2 "block: quoted TMPDIR, unquoted glob"        'rm -rf "$TMPDIR"/tmp.*'
chk 2 "block: /private/tmp"                        'rm -rf /private/tmp/*'
chk 2 "block: /private/var/folders"                'rm -rf /private/var/folders/*/*/T/tmp.*'
chk 2 "block: rm -f with a short prefix"           'rm -f /tmp/x*'
chk 2 "block: absolute rm"                         '/bin/rm -rf /tmp/*'
chk 2 "block: command wrapper, /var/tmp"           'command rm -rf /var/tmp/*'
chk 2 "block: two levels of the folders root"      'rm -rf /var/folders/*/*'
chk 2 "block: rm of every json in /tmp"            'rm /tmp/*.json'
chk 2 "block: one-letter prefix"                   'rm -rf /tmp/t*'
chk 2 "block: tmp* prefix"                         'rm -rf /tmp/tmp*'
chk 2 "block: TMPDIR tmp.*"                        'rm -rf $TMPDIR/tmp.*'
chk 2 "block: sudo with an option"               'sudo -n rm -rf /tmp/*'
chk 2 "block: env with an option"                'env -i rm -rf /tmp/*'
chk 2 "block: nice with a value option"          'nice -n 5 rm -rf /tmp/*'
chk 2 "block: rtk wrapper"                       'rtk rm -rf /tmp/*'
chk 2 "block: xargs wrapper"                     'xargs rm -rf /tmp/*'
chk 2 "block: find with a globbed generic start"  'find /tmp/tmp.* -delete'
chk 2 "block: find, globbed start, -exec rm"      'find /tmp/* -maxdepth 0 -exec rm -rf {} +'
chk 2 "block: rm in a heredoc fed to a shell"     $'bash <<EOF\nrm -rf /tmp/*\nEOF'
chk 2 "block: wrapper then --"                     'sudo -- rm -rf /tmp/*'
# ── ALLOW (exit 0) ────────────────────────────────────────────────────────────
chk 0 "allow: a literal directory"                 'rm -rf /tmp/gate-abc123'
chk 0 "allow: glob below the first level"          'rm /tmp/mydir/*.log'
chk 0 "allow: home path"                           'rm -rf ~/x'
chk 0 "allow: relative path"                       'rm -f ./out'
chk 0 "allow: git rm"                              'git rm -r dir'
chk 0 "allow: rm only in an echo string"           'echo "rm -rf /tmp/*"'
chk 0 "allow: find -delete under a subdirectory"   'find /tmp/mine -delete'
chk 0 "allow: ls is not a delete"                  'ls /tmp/*'
chk 0 "allow: quoted glob is a literal name"       "rm -rf '/tmp/*'"
chk 0 "allow: literal under TMPDIR"                'rm -rf "$TMPDIR/mine-123"'
chk 0 "allow: /var/folders C dir"                  'rm -rf /var/folders/ab/cdef/C/x'
chk 0 "allow: rm in a heredoc body"                $'cat <<EOF\nrm -rf /tmp/*\nEOF'
chk 0 "allow: unset variable path"                 'rm -rf $mydir'
chk 0 "allow: find -delete in the working dir"     'find . -name "*.tmp" -delete'
chk 0 "allow: a worktree path"                     'rm -rf /work/trees/x'
chk 0 "allow: distinctive own prefix"              'rm /tmp/wdcap-*.txt'
chk 0 "allow: own literal and own prefix"          'rm -rf /tmp/rvrev /tmp/rvrev.*'
chk 0 "allow: own prefix with extension"           'rm -f /tmp/scratch-r5.tfstate*'
chk 0 "allow: braced variable under /tmp"        'rm -rf /tmp/${run_id}'
chk 0 "allow: braced variable under TMPDIR"      'rm -rf "$TMPDIR"/${name}-out'
chk 0 "allow: find with an own-prefix glob start" 'find /tmp/myrun-* -delete'

t_summary
