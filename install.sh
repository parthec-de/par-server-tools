#!/usr/bin/env bash
#
# par-server-tools installer.
#
# Symlinks the tools (parbackup, paralert) from this repo into $PREFIX/bin.
# Idempotent: updates the repo with git pull if it is a git repo, and leaves
# existing symlinks untouched. Run it from the cloned repo, e.g.:
#
#   git clone https://github.com/parthec-de/par-server-tools.git \
#     /usr/local/share/par-server-tools
#   /usr/local/share/par-server-tools/install.sh
#
# $PREFIX defaults to /usr/local (override with PAR_PREFIX).

set -euo pipefail

PREFIX="${PAR_PREFIX:-/usr/local}"
BINDIR="$PREFIX/bin"
SRC="$(cd "$(dirname "$(readlink -f "$0")")" && pwd)"
TOOLS=(parbackup paralert)

# Update the repo on re-runs (no-op right after a fresh clone).
if [[ -d "$SRC/.git" ]]; then
  echo "Updating repo in $SRC ..."
  git -C "$SRC" pull --ff-only || echo "warning: git pull failed, continuing with the current repo"
fi

mkdir -p "$BINDIR"
for tool in "${TOOLS[@]}"; do
  link="$BINDIR/$tool"
  if [[ -e "$link" || -L "$link" ]]; then
    echo "skip $link (already exists)"
    continue
  fi
  ln -s "$SRC/$tool/$tool" "$link"
  echo "linked $link -> $SRC/$tool/$tool"
done

echo ""
echo "Done."
echo "Ensure $BINDIR is on your PATH."
