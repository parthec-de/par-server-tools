# par-server-tools

Collection of server tools for deployments. One directory per tool.

## Tools

- [**parbackup**](./parbackup/) — Backup tool for Docker deployments: online dumps of Postgres/MongoDB/MySQL, Docker volumes and local directories packaged as `.tar.gz`, uploaded to S3.
- [**paralert**](./paralert/) — Alert-notification tool: sends emails via SMTP. Used by other tools (e.g. parbackup) for failure alerts.

## Installation

The installer clones the repository into `/usr/local/share/par-server-tools` and
symlinks each tool into `/usr/local/bin`. The repository is private, so
authentication is required — the one-liner prompts for a
[Codeberg access token](https://codeberg.org/user/settings/applications)
(input is hidden):

```bash
read -rsp "Codeberg token: " CODEBERG_TOKEN && echo && export CODEBERG_TOKEN
bash -c "$(curl -fsSL -H "Authorization: token $CODEBERG_TOKEN" \
  https://codeberg.org/parthec/par-server-tools/raw/branch/main/install.sh)"
```

The token is used both to fetch the installer and (via `CODEBERG_TOKEN`) to clone
the repository. For non-interactive use (CI), set `CODEBERG_TOKEN` beforehand and
skip the first line. Overrides: `PAR_PREFIX` (install prefix, default `/usr/local`),
`PAR_REF` (branch/tag).

Update an existing install by pulling the checkout (or just re-run the installer):

```bash
git -C /usr/local/share/par-server-tools pull
```

Alternatively, clone the repo and run the installer directly:

```bash
git clone https://codeberg.org/parthec/par-server-tools.git
cd par-server-tools && ./install.sh
```
