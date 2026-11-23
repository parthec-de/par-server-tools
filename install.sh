#!/usr/bin/env bash
#
# par-server-tools installer.
#
# Links the tools of this repo into $PREFIX/bin. The work is done by
# par/par update, so a later `par update` repeats the same steps. Run it from the
# cloned repo, e.g.:
#
#   git clone https://github.com/parthec-de/par-server-tools.git \
#     /usr/local/share/par-server-tools
#   /usr/local/share/par-server-tools/install.sh
#
# $PREFIX defaults to /usr/local (override with PAR_PREFIX).

set -euo pipefail

PREFIX="${PAR_PREFIX:-/usr/local}"
SRC="$(cd "$(dirname "$(readlink -f "$0")")" && pwd)"

"$SRC/par/par" update

echo ""
echo "Ensure $PREFIX/bin is on your PATH."
