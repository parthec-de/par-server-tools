#!/usr/bin/env bash
#
# par-server-tools installer.
#
# Installs all tools (parbackup, paralert) to a bin directory on the host.
# Intended to be run directly on a server, e.g.:
#
#   export CODEBERG_TOKEN=<token>
#   bash -c "$(curl -fsSL -H "Authorization: token $CODEBERG_TOKEN" \
#     https://codeberg.org/parthec/par-server-tools/raw/branch/main/install.sh)"
#
# Environment overrides:
#   PAR_REPO_URL     Git URL to clone (default: the Codeberg repo below)
#   PAR_REF          Branch or tag to install (default: main)
#   PAR_BINDIR       Install directory (default: /usr/local/bin)
#   CODEBERG_TOKEN   Access token for non-interactive auth (private repo).
#                    Without it, git clone prompts / uses your credential helper.

set -euo pipefail

REPO_URL="${PAR_REPO_URL:-https://codeberg.org/parthec/par-server-tools.git}"
REF="${PAR_REF:-main}"
BINDIR="${PAR_BINDIR:-/usr/local/bin}"
TOOLS=(parbackup paralert)

info() { printf '\033[1;34m==>\033[0m %s\n' "$*"; }
err() { printf '\033[1;31mError:\033[0m %s\n' "$*" >&2; }

command -v git > /dev/null 2>&1 || {
  err "git is required but not installed."
  exit 1
}

# Non-interactive auth via a token, passed as an HTTP header so it never ends up
# in the remote URL (avoids leaking it in error output or the process list URL).
git_auth=()
if [[ -n "${CODEBERG_TOKEN:-}" ]]; then
  git_auth=(-c "http.extraHeader=Authorization: token ${CODEBERG_TOKEN}")
fi

# Use sudo only when we cannot create/write the target directory ourselves.
# mkdir -p on an existing directory succeeds even without write access, so the
# -w check below is what actually decides whether escalation is needed.
SUDO=""
if ! mkdir -p "$BINDIR" 2> /dev/null || [[ ! -w "$BINDIR" ]]; then
  if command -v sudo > /dev/null 2>&1; then
    SUDO="sudo"
    $SUDO mkdir -p "$BINDIR"
  else
    err "No write access to $BINDIR and sudo is not available."
    exit 1
  fi
fi

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

info "Cloning par-server-tools (ref: $REF)..."
git "${git_auth[@]}" clone --depth 1 --branch "$REF" "$REPO_URL" "$tmp/repo"

info "Installing tools to $BINDIR..."
for tool in "${TOOLS[@]}"; do
  src="$tmp/repo/$tool/$tool"
  if [[ ! -f "$src" ]]; then
    err "Tool script not found in repo: $tool"
    exit 1
  fi
  $SUDO install -m 0755 "$src" "$BINDIR/$tool"
  info "  installed $BINDIR/$tool"
done

info "Done. Installed: ${TOOLS[*]}"
echo ""
echo "Next steps:"
echo "  parbackup config set     # configure the S3 backend"
echo "  paralert  config set     # configure failure-alert emails"
echo ""
echo "Ensure $BINDIR is on your PATH."
