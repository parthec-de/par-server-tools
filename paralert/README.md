# paralert

Standalone alert-notification tool for par server tools. Sends notification
emails via SMTP (using `curl`). Other tools (e.g. [parbackup](../parbackup/))
delegate their alerting to `paralert`, which is assumed to be installed on the
host `PATH`.

## Requirements

- Bash
- curl
- [gum](https://github.com/charmbracelet/gum) (only for `config set`)

## Setup

Configure SMTP interactively:

```bash
paralert config set
```

This saves settings to `~/.config/par/paralert.conf`. View current config:

```bash
paralert config
```

Configuration keys (`~/.config/par/paralert.conf`):

```bash
ALERT_SMTP_HOST=''        # SMTP server host
ALERT_SMTP_PORT='587'     # SMTP server port
ALERT_SMTP_USER=''        # SMTP user (empty = no auth)
ALERT_SMTP_PASSWORD=''    # SMTP password
ALERT_SMTP_FROM=''        # From address
ALERT_RECIPIENTS=''       # Comma-separated recipient list
```

If `ALERT_SMTP_HOST`, `ALERT_SMTP_FROM`, or `ALERT_RECIPIENTS` are unset,
`paralert send` exits successfully without sending anything (alerting is
optional and must never break the calling tool).

## Usage

```bash
# Body as an argument
paralert send --subject "Backup FAILED" --body "See attached log."

# Body from stdin (when --body is omitted)
cat run.log | paralert send --subject "Backup FAILED"
```

## Development

A MailPit-based test stack is included in `./test/`.

```bash
bats test/test.bats
```
