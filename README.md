# par-server-tools

Back up and restore entire Docker Compose deployments with one config file and one command. Plain Bash on the host: no daemon, no extra container, no changes to your `docker-compose.yaml`.

## Tools

- [**parbackup**](./parbackup/): backup and restore of Postgres, MySQL and MongoDB databases, Docker volumes and host directories to S3, with retention and cron scheduling.
- [**paralert**](./paralert/): email alerts via SMTP with mandatory TLS. parbackup uses it for failure alerts. On its own, it alerts on disk usage and on failing commands or cron jobs.

## Motivation

- **One file per deployment:** a `Parbackupfile` lists databases, volumes and directories. Each backup is a single self-describing `.tar.gz`.
- **One-command restore:** `parbackup restore --pick` restores everything from S3, databases included.
- **Matching dump versions:** dumps run inside the database container via `docker exec`.
- **Nothing in the background:** Bash and cron, no daemon, no container.
- **Tested end to end:** real Postgres, MySQL, MongoDB, S3 and SMTP in the test suites.

## How it works

```mermaid
flowchart LR
  subgraph host["Docker host"]
    PF["Parbackupfile"]
    DB[("Postgres / MySQL / MongoDB")]
    VOL["Volumes"]
    DIR["Directories"]
    PB["parbackup"]
    PA["paralert"]
  end
  PF --> PB
  DB -- "docker exec dump" --> PB
  VOL -- "docker cp" --> PB
  DIR -- "cp -a" --> PB
  PB -- "tar.gz" --> S3[("S3")]
  S3 -- "restore --pick" --> PB
  PB -.->|"failure + run log"| PA
  PA -- "SMTP (TLS)" --> MAIL["Email"]
```

## Quick start

```bash
# Install (as root)
git clone https://github.com/parthec-de/par-server-tools.git /usr/local/share/par-server-tools
/usr/local/share/par-server-tools/install.sh

# Configure S3 and, optionally, alert emails
parbackup config set
paralert config set

# Describe the deployment in a Parbackupfile (see the parbackup README), then:
parbackup create -f /opt/my-project/Parbackupfile
parbackup cron -f /opt/my-project/Parbackupfile --schedule "0 3 * * *"

# Restore later
parbackup restore --pick
```

## Limitations

- **No encryption:** archives are plain `.tar.gz`, including the `Parbackupfile` with its database passwords. Keep the bucket private.
- **No deduplication or incremental backups:** every run uploads a full archive.
- **S3 only** as remote target.
- **Email only** as alert channel.
- **Single host:** no central overview across servers.
- **Debian and Ubuntu** for auto-installing dependencies (`apt`).

## Alternatives

**parbackup**

- [restic](https://restic.net/): encrypted, deduplicated backups to many backends. Database dumps and their restore are up to you.
- [offen/docker-volume-backup](https://github.com/offen/docker-volume-backup): runs as a container in the compose stack and backs up volumes. Database dumps via custom hooks, manual restore.
- [nfrastack/db-backup](https://github.com/nfrastack/db-backup): databases only, but nine engines, incremental backups and encryption.

**paralert**

- [Monit](https://mmonit.com/monit/): full monitoring daemon with its own config language. Checks processes, ports and certificates, restarts services, has a web UI. paralert only covers disk usage and failing commands, but needs no daemon and can be called from any script.

## Installation

Clone the repository into `/usr/local/share/par-server-tools` and run the installer, which symlinks each tool into `/usr/local/bin`. Run as root so it can write to `/usr/local`:

```bash
git clone https://github.com/parthec-de/par-server-tools.git /usr/local/share/par-server-tools
/usr/local/share/par-server-tools/install.sh
```

Override the install prefix with `PAR_PREFIX` (default `/usr/local`).

## Update

Re-run the installer. It pulls the latest changes and leaves existing symlinks untouched:

```bash
/usr/local/share/par-server-tools/install.sh
```

## License

[Apache License 2.0](./LICENSE), attribution in [NOTICE](./NOTICE).
