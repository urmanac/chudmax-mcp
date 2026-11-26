#!/bin/sh
# Phase 8 rehearsal (T-0037): the bare repo's update hook — the stand-in for
# production's protected-branch rule. Git's receive-pack runs this once per
# pushed ref, feeding "<old-sha> <new-sha> <refname>" lines on stdin; a
# non-zero exit rejects that ref.
#
# Rule: refs/heads/main is UNWRITABLE over HTTP — to anyone, with any
# credential. The automation's review branch is writable; everything else
# follows the same rule (only main is special). The bare repo is seeded by
# CLONE (never an HTTP push), so no setup step needs a main-push exemption —
# the hook that cannot drift is the one with no carve-outs.
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
