# par-server-tools

Collection of server tools for deployments. One directory per tool.

## Tools

- [**parbackup**](./parbackup/) — Backup tool for Docker deployments: online dumps of Postgres/MongoDB/MySQL, Docker volumes and local directories packaged as `.tar.gz`, uploaded to S3.
- [**paralert**](./paralert/) — Alert-notification tool: sends emails via SMTP. Used by other tools (e.g. parbackup) for failure alerts.

## Installation

Clone the repository into `/usr/local/share/par-server-tools` and run the
installer, which symlinks each tool into `/usr/local/bin`. The repository is
private, so `git clone` prompts for your Codeberg credentials interactively.
Run as root so it can write to `/usr/local`:

```bash
sh -c 'git clone https://codeberg.org/parthec/par-server-tools.git /usr/local/share/par-server-tools && /usr/local/share/par-server-tools/install.sh'
```

Override the install prefix with `PAR_PREFIX` (default `/usr/local`).

## Update

Re-run the command above. It is idempotent: if the repository already exists the
installer pulls the latest changes, and existing symlinks are left untouched.
