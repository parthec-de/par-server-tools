# paralert

Email alerts via SMTP from the command line. parbackup sends its failure alerts through paralert. On its own, paralert checks disk usage and reports failing commands or cron jobs.

## Requirements

- **Bash**
- **curl:** for sending emails
- **[gum](https://github.com/charmbracelet/gum):** for `config` and log output, auto-installed via `apt` on Debian and Ubuntu

## Configuration

```bash
paralert config set   # configure interactively
paralert config       # show the current configuration
```

The settings live in `~/.config/par/paralert.conf`:

| Key                   | Purpose                                          | Default |
| --------------------- | ------------------------------------------------ | ------- |
| `ALERT_SMTP_HOST`     | SMTP server                                      |         |
| `ALERT_SMTP_PORT`     | SMTP port                                        | `587`   |
| `ALERT_SMTP_USER`     | SMTP user, empty disables authentication         |         |
| `ALERT_SMTP_PASSWORD` | SMTP password                                    |         |
| `ALERT_SMTP_FROM`     | Sender address                                   |         |
| `ALERT_RECIPIENTS`    | Comma-separated recipients                       |         |
| `ALERT_SMTP_INSECURE` | `true` disables TLS, for local test servers only |         |

- **TLS is mandatory:** port 465 uses implicit TLS, every other port STARTTLS. Without TLS, sending fails instead of falling back to plain text.
- **Alerting is optional:** without host, sender or recipients, `paralert send` exits successfully without sending anything.
- **Failed sends exit non-zero:** callers that must not break on a failed alert append `|| true`.

## Usage

### Send an alert

```bash
paralert send --subject "Backup FAILED" --body "See attached log."
cat run.log | paralert send --subject "Backup FAILED"
```

Without `--body`, the body is read from stdin.

### Check disk usage

```bash
paralert check-disk --threshold 90 --path /
```

An alert goes out once usage reaches the threshold. The defaults are `90` percent on `/`.

### Alert on a failing command

```bash
paralert run --subject "Cert renew failed" -- certbot renew
```

On a non-zero exit, the alert contains the output of the command.

### Schedule checks

```bash
paralert cron          # add a cron job interactively
paralert cron show     # list paralert cron jobs
paralert cron remove   # remove one interactively
```

| Type       | Asks for                   | Runs         | Crontab marker             |
| ---------- | -------------------------- | ------------ | -------------------------- |
| Disk Usage | schedule, threshold, path  | `check-disk` | `# paralert:disk`          |
| Custom     | schedule, subject, command | `run`        | `# paralert:custom-<slug>` |

## Development

The tests run against a MailPit SMTP server from `./test/`:

```bash
mise run test:paralert
```
