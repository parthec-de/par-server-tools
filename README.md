# par-server-tools

Collection of server tools for deployments. One directory per tool.

## Tools

- [**parbackup**](./parbackup/) — Backup tool for Docker deployments: online dumps of Postgres/MongoDB, Docker volumes and local directories packaged as `.tar.gz`, uploaded to S3.
- [**paralert**](./paralert/) — Alert-notification tool: sends emails via SMTP. Used by other tools (e.g. parbackup) for failure alerts.
