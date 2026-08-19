#!/usr/bin/env bash
#
# par-server-tools installer.
#
# Clones the repository into $PREFIX/share/par-server-tools and symlinks each
# tool (parbackup, paralert) into $PREFIX/bin. Updating later is just:
#
#   git -C /usr/local/share/par-server-tools pull
#
# Intended to be run directly on a server. The one-liner prompts for a token
# (hidden input) and uses it to fetch this script and to clone the repo:
#
#   read -rsp "Codeberg token: " CODEBERG_TOKEN && echo && export CODEBERG_TOKEN
#   bash -c "$(curl -fsSL -H "Authorization: token $CODEBERG_TOKEN" \
#     https://codeberg.org/parthec/par-server-tools/raw/branch/main/install.sh)"
#
# Environment overrides:
#   PAR_PREFIX       Install prefix (default: /usr/local)
#   PAR_REPO_URL     Git URL to clone (default: the Codeberg repo below)
#   PAR_REF          Branch or tag to install (default: main)
#   CODEBERG_TOKEN   Access token for non-interactive auth (private repo).
#                    Without it, git clone prompts / uses your credential helper.

set -euo pipefail

REPO_URL="${PAR_REPO_URL:-https://codeberg.org/parthec/par-server-tools.git}"
REF="${PAR_REF:-main}"
PREFIX="${PAR_PREFIX:-/usr/local}"
SHAREDIR="${PREFIX}/share/par-server-tools"
BINDIR="${PREFIX}/bin"
TOOLS=(parbackup paralert)

info() { printf '\033[1;34m==>\033[0m %s\n' "$*"; }
err() { printf '\033[1;31mError:\033[0m %s\n' "$*" >&2; }

command -v git > /dev/null 2>&1 || {
  err "git is required but not installed."
  exit 1
}

# Non-interactive auth via a token, passed as an HTTP header so it never ends up
# in the remote URL. Passed as a -c argument (not an env var) so it survives sudo.
git_auth=()
if [[ -n "${CODEBERG_TOKEN:-}" ]]; then
  git_auth=(-c "http.extraHeader=Authorization: token ${CODEBERG_TOKEN}")
fi

# Escalate with sudo only when we cannot write into the prefix directories.
SUDO=""
if ! mkdir -p "$SHAREDIR" "$BINDIR" 2> /dev/null || [[ ! -w "$SHAREDIR" || ! -w "$BINDIR" ]]; then
  if command -v sudo > /dev/null 2>&1; then
    SUDO="sudo"
    $SUDO mkdir -p "$SHAREDIR" "$BINDIR"
  else
    err "No write access to $PREFIX and sudo is not available."
    exit 1
  fi
fi

# Fresh checkout: remove a previous install (only if it is our git checkout).
if [[ -e "$SHAREDIR" ]] && [[ -n "$(ls -A "$SHAREDIR" 2> /dev/null)" ]]; then
  if [[ -d "$SHAREDIR/.git" ]]; then
    info "Removing previous checkout at $SHAREDIR..."
    $SUDO rm -rf "$SHAREDIR"
    $SUDO mkdir -p "$SHAREDIR"
  else
    err "$SHAREDIR exists and is not a par-server-tools checkout; aborting."
    exit 1
  fi
fi

info "Cloning par-server-tools into $SHAREDIR (ref: $REF)..."
$SUDO git "${git_auth[@]}" clone --depth 1 --branch "$REF" "$REPO_URL" "$SHAREDIR"

info "Linking tools into $BINDIR..."
for tool in "${TOOLS[@]}"; do
  target="$SHAREDIR/$tool/$tool"
  if [[ ! -f "$target" ]]; then
    err "Tool script not found in checkout: $tool"
    exit 1
  fi
  $SUDO ln -sfn "$target" "$BINDIR/$tool"
  info "  linked $BINDIR/$tool -> $target"
done

info "Done. Installed: ${TOOLS[*]}"
echo ""
echo "Next steps:"
echo "  parbackup config set     # configure the S3 backend"
echo "  paralert  config set     # configure failure-alert emails"
echo ""
echo "Update later with: git -C $SHAREDIR pull"
echo "Ensure $BINDIR is on your PATH."
