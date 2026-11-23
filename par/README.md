# par

Management command for the installed par server tools.

## Commands

| Command       | Effect                                                         |
| ------------- | -------------------------------------------------------------- |
| `par update`  | Pulls the repository and links new tools into `/usr/local/bin` |
| `par version` | Lists the version of every tool                                |

`par update` keeps symlinks that point into the repository, adds tools that appeared since the last run and leaves foreign files and symlinks alone. `install.sh` runs the same command on the first install. The command writes into `$PAR_PREFIX/bin`, defaults to `/usr/local` and needs root for the links.

```text
$ par version
paralert:  v1.2.0
parbackup: v1.9.0
```

A tool is a directory in the repository with an executable file of the same name. `par` does not list itself.

## Name

`par` is also a paragraph reformatter in the Debian repositories. The symlink in `/usr/local/bin` comes first in the usual `PATH`, so the manager wins. A host that needs the reformatter can still call `/usr/bin/par`, or move the manager with `PAR_PREFIX`.

## Development

```bash
mise run test:par
```

The tests copy the tools into a temporary directory and do not touch `/usr/local/bin`.
