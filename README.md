# par-server-tools

Collection of server tools for deployments. One directory per tool.

## Tools

- [**parbackup**](./parbackup/) — Backup tool for Docker deployments: online dumps of Postgres/MongoDB/MySQL, Docker volumes and local directories packaged as `.tar.gz`, uploaded to S3.
- [**paralert**](./paralert/) — Alert-notification tool: sends emails via SMTP. Used by other tools (e.g. parbackup) for failure alerts.

## Installation

Clone the repository into `/usr/local/share/par-server-tools` and run the
installer, which symlinks each tool into `/usr/local/bin`. Run as root so it
can write to `/usr/local`:

```bash
git clone https://codeberg.org/parthec/par-server-tools.git /usr/local/share/par-server-tools
/usr/local/share/par-server-tools/install.sh
```

Override the install prefix with `PAR_PREFIX` (default `/usr/local`).

## Update

Re-run the installer. It pulls the latest changes and leaves existing symlinks
untouched:

```bash
/usr/local/share/par-server-tools/install.sh
```

## License

[Apache License 2.0](./LICENSE), attribution in [NOTICE](./NOTICE).
