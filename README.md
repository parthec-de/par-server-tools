# par-server-tools

Collection of server tools for deployments. One directory per tool.

## Tools

- [**parbackup**](./parbackup/) — Backup tool for Docker deployments: online dumps of Postgres/MongoDB/MySQL, Docker volumes and local directories packaged as `.tar.gz`, uploaded to S3.
- [**paralert**](./paralert/) — Alert-notification tool: sends emails via SMTP. Used by other tools (e.g. parbackup) for failure alerts.

## Installation

Install all tools to `/usr/local/bin` on a server. The repository is private, so
authentication is required — pass a [Codeberg access token](https://codeberg.org/user/settings/applications):

```bash
export CODEBERG_TOKEN=<your-token>
bash -c "$(curl -fsSL -H "Authorization: token $CODEBERG_TOKEN" \
  https://codeberg.org/parthec/par-server-tools/raw/branch/main/install.sh)"
```

The token is used both to fetch the installer and (via `CODEBERG_TOKEN`) to clone
the repository. Overrides: `PAR_BINDIR` (install dir), `PAR_REF` (branch/tag).

Alternatively, clone the repo and run the installer directly:

```bash
git clone https://codeberg.org/parthec/par-server-tools.git
cd par-server-tools && ./install.sh
```
