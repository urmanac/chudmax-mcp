#!/bin/sh
# Phase 8 rehearsal (T-0037): the bare repo's PRE-RECEIVE hook — the stand-in
# for production's protected-branch rule. Git's receive-pack runs it once per
# push, feeding every pushed ref as "<old-sha> <new-sha> <refname>" lines on
# stdin; a non-zero exit rejects the whole push.
#
# Rule: refs/heads/main is UNWRITABLE over HTTP — to anyone, with any
# credential. The automation's review branch is writable. The bare repo is
# seeded by CLONE (never an HTTP push), so no setup step needs a main-push
# exemption — the hook that cannot drift is the one with no carve-outs.
#
# Mechanics note (the pre-flight receipt): this is PRE-RECEIVE, not update —
# the update hook takes refname/oldrev/newrev as $1-3 and its stdin is empty,
# so a stdin-reading update hook rejects nothing. One pre-receive with the
# stdin loop is the correct shape for "reject these refs, whatever the pack".
#
# The denial text is a receipt: the negative control's captured output must
# contain it.
deny() {
  echo "denied: $ref is protected — the automation credential writes review/image-updates only" >&2
  exit 1
}

while read -r _old _new ref; do
  case "$ref" in
    refs/heads/main) deny ;;
  esac
done

exit 0
