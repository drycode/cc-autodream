#!/bin/bash
# bin/lib-install-dir.sh, the one install-dir resolver (issue #112), and the six
# scripts that use it. The resolver used to be pasted into each of them, and the
# copies disagreed about which files mark an install and whether to warn.
set -u

HERE=$(cd "$(dirname "$0")" && pwd)
REPO=$(cd "$HERE/.." && pwd)
_root="${TMPDIR:-/tmp}"; SUITE_TMP=$(mktemp -d "${_root%/}/instdir.XXXXXX")
trap 'rm -rf "$SUITE_TMP"' EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

pass=0; fail=0
ok(){ printf '  ok   - %s\n' "$1"; pass=$((pass + 1)); }
no(){ printf '  FAIL - %s\n' "$1"; fail=$((fail + 1)); }
assert_eq(){ [ "$1" = "$2" ] && ok "$3" || no "$3 (got [$1] want [$2])"; }

LIB="$REPO/bin/lib-install-dir.sh"
SCRIPTS="autodream-note vault-notes review autodream-now notify question-streaks"

echo "# install-dir: the helper exists and is the only resolver"
[ -f "$LIB" ] || { no "bin/lib-install-dir.sh missing; the rest of this suite would be vacuous"
                   printf '\npassed: %s   failed: %s\n' "$pass" "$fail"; exit 1; }
for s in $SCRIPTS; do
  if grep -q 'resolve_install_dir' "$REPO/bin/$s.sh"; then ok "$s.sh calls resolve_install_dir"
  else no "$s.sh calls resolve_install_dir"; fi
  # The marker test is what each pasted copy carried.
  if grep -q -- '/config" \]' "$REPO/bin/$s.sh"; then no "$s.sh still carries its own marker check"
  else ok "$s.sh carries no marker check of its own"; fi
done
grep -q 'lib-install-dir.sh' "$REPO/install.sh" && ok "install.sh links the helper" || no "install.sh links the helper"

echo "# install-dir: resolve_install_dir"
HOME_S="$SUITE_TMP/home"; mkdir -p "$HOME_S"
inst="$SUITE_TMP/install"; mkdir -p "$inst"; : > "$inst/config"
inst2="$SUITE_TMP/install2"; mkdir -p "$inst2"; : > "$inst2/PROMPT.md"
bare="$SUITE_TMP/bare"; mkdir -p "$bare"

run_resolve() { # $1=script path  $2=optional name  [env AUTODREAM_DIR passed by caller]
  ( . "$LIB"; resolve_install_dir "$1" ${2:+"$2"}; printf '%s' "$AUTODREAM_DIR" )
}
assert_eq "$(unset AUTODREAM_DIR; HOME="$HOME_S" run_resolve "$inst/x.sh" 2>&1)" "$inst" "a config marker makes the script's own directory the install"
assert_eq "$(unset AUTODREAM_DIR; HOME="$HOME_S" run_resolve "$inst2/x.sh" 2>&1)" "$inst2" "a PROMPT.md marker does too"
assert_eq "$(AUTODREAM_DIR=/elsewhere HOME="$HOME_S" run_resolve "$inst/x.sh" 2>&1)" "/elsewhere" "an AUTODREAM_DIR in the environment wins"
assert_eq "$(unset AUTODREAM_DIR; HOME="$HOME_S" run_resolve "$bare/x.sh" 2>&1)" "$HOME_S/.claude/autodream" "no marker falls back to the legacy default, silently without a name"
out=$(unset AUTODREAM_DIR; HOME="$HOME_S" run_resolve "$bare/x.sh" thing.sh 2>&1)
case "$out" in
  *"thing.sh: WARNING no install markers"*"$HOME_S/.claude/autodream") ok "with a name the fallback warns on stderr" ;;
  *) no "with a name the fallback warns on stderr (got [$out])" ;;
esac
assert_eq "$(unset AUTODREAM_DIR; HOME="$HOME_S" run_resolve "$REPO/bin/x.sh" 2>&1)" "$HOME_S/.claude/autodream" "the repo's own bin/ is never mistaken for an install"

echo "# install-dir: an installed script finds the helper even before install.sh links it"
# A merge updates the symlinks into the checkout at once; the helper's own link
# only appears when install.sh runs again. The script must still start.
linkdir="$SUITE_TMP/oldinstall"; mkdir -p "$linkdir"; : > "$linkdir/config"
for s in autodream-note vault-notes review; do ln -s "$REPO/bin/$s.sh" "$linkdir/$s.sh"; done
ln -s "$REPO/bin/question-streaks.sh" "$linkdir/question-streaks.sh"
ln -s "$REPO/bin/autodream-now.sh" "$linkdir/autodream-now.sh"
quiet() { ( unset AUTODREAM_DIR; HOME="$HOME_S" "$@" 2>&1 </dev/null ); }
out=$(quiet bash "$linkdir/autodream-note.sh")
case "$out" in *"No such file"*|*"lib-install-dir"*) no "autodream-note.sh starts without a linked helper ($out)" ;; *usage*) ok "autodream-note.sh starts without a linked helper" ;; *) no "autodream-note.sh starts without a linked helper ($out)" ;; esac
out=$(quiet bash "$linkdir/question-streaks.sh" bogus)
case "$out" in *"No such file"*) no "question-streaks.sh starts without a linked helper ($out)" ;; *usage*) ok "question-streaks.sh starts without a linked helper" ;; *) no "question-streaks.sh starts without a linked helper ($out)" ;; esac
out=$(quiet bash "$linkdir/vault-notes.sh" status)
case "$out" in *"$linkdir/notes.md"*) ok "vault-notes.sh status names the install it was linked into" ;; *) no "vault-notes.sh status names the install it was linked into ($out)" ;; esac
out=$(quiet bash "$linkdir/autodream-now.sh" --dry-run)
case "$out" in *"No such file"*"lib-install-dir"*) no "autodream-now.sh starts without a linked helper ($out)" ;; *"$linkdir"*) ok "autodream-now.sh --dry-run resolves the install it was linked into" ;; *) no "autodream-now.sh --dry-run resolves the install it was linked into ($out)" ;; esac
# notify.sh is covered by the structural check above only: its usage check runs
# before the resolver, and any argument that passes it raises a real banner.

printf '\npassed: %s   failed: %s\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
