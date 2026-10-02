#!/usr/bin/env bash
# install.sh - install the secgate pre-push hook into one or more repos.
# Usage: ./install.sh <repo-path> [<repo-path> ...]
set -euo pipefail
SECGATE_HOME="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
NOTES_REF="${SEC_NOTES_REF:-refs/notes/security-reviews}"
[ $# -gt 0 ] || { echo "usage: $0 <repo-path> [...]" >&2; exit 1; }

for repo in "$@"; do
  if ! git -C "$repo" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
    echo "skip (not a git repo): $repo" >&2; continue
  fi
  root="$(git -C "$repo" rev-parse --show-toplevel)"
  hooks="$(git -C "$repo" rev-parse --git-path hooks)"
  dest="$root/$hooks/pre-push"
  mkdir -p "$(dirname "$dest")"

  if [ -e "$dest" ] && ! grep -q "secgate pre-push hook" "$dest" 2>/dev/null; then
    cp "$dest" "$dest.pre-secgate.bak"
    echo "  existing hook backed up -> pre-push.pre-secgate.bak"
  fi

  sed "s|__SECGATE_HOME__|$SECGATE_HOME|g" "$SECGATE_HOME/hooks/pre-push" > "$dest"
  chmod +x "$dest"

  mkdir -p "$root/.security-reviews"
  [ -f "$root/.security-reviews/accepted.json" ] || echo '[]' > "$root/.security-reviews/accepted.json"

  # evidence lives on a notes ref, which git neither fetches nor shows by
  # default. Without these two settings the records are invisible to everyone
  # who did not produce them.
  if ! git -C "$root" config --get-all remote.origin.fetch 2>/dev/null | grep -qF "$NOTES_REF"; then
    git -C "$root" config --add remote.origin.fetch "+$NOTES_REF:$NOTES_REF"
  fi
  git -C "$root" config notes.displayRef "$NOTES_REF"

  echo "installed: $root"
done
echo
echo "Done. Verify with:  git -C <repo> push --dry-run"
