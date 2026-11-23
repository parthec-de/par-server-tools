#!/usr/bin/env bats

# Tests for the par management command. They run against a copy of the tools in
# a temporary directory, so nothing is written outside it.

setup() {
  TEST_REPO="$(mktemp -d /tmp/par-test-XXXXXX)"
  export TEST_REPO
  export TEST_BIN="${TEST_REPO}/bin"
  export PAR="${TEST_REPO}/par/par"
  export PAR_PREFIX="$TEST_REPO"

  mkdir -p "${TEST_REPO}/par" "${TEST_REPO}/parbackup" "${TEST_REPO}/paralert"
  cp "${BATS_TEST_DIRNAME}/../par" "${TEST_REPO}/par/par"
  cp "${BATS_TEST_DIRNAME}/../../parbackup/parbackup" "${TEST_REPO}/parbackup/parbackup"
  cp "${BATS_TEST_DIRNAME}/../../paralert/paralert" "${TEST_REPO}/paralert/paralert"
  chmod +x "$PAR" "${TEST_REPO}/parbackup/parbackup" "${TEST_REPO}/paralert/paralert"
}

teardown() {
  rm -rf "$TEST_REPO"
}

@test "version lists every tool in the requested format" {
  run "$PAR" version
  [ "$status" -eq 0 ]
  [[ "$output" =~ paralert:\ +v[0-9]+\.[0-9]+\.[0-9]+ ]]
  [[ "$output" =~ parbackup:\ +v[0-9]+\.[0-9]+\.[0-9]+ ]]
}

@test "version does not list the manager itself" {
  run "$PAR" version
  [ "$status" -eq 0 ]
  [[ "$output" != *"par:"* ]]
}

@test "version reports a tool without a version" {
  mkdir -p "${TEST_REPO}/broken"
  printf '#!/usr/bin/env bash\n' > "${TEST_REPO}/broken/broken"
  chmod +x "${TEST_REPO}/broken/broken"

  run "$PAR" version
  [ "$status" -eq 0 ]
  [[ "$output" == *"No script_version"* ]]
  [[ "$output" =~ broken:\ +unknown ]]
}

@test "update links every tool into the prefix" {
  run "$PAR" update
  [ "$status" -eq 0 ]
  [[ "$output" == *"No git repository"* ]]
  [ -L "${TEST_BIN}/par" ]
  [ -L "${TEST_BIN}/parbackup" ]
  [ -L "${TEST_BIN}/paralert" ]
  [ "$(readlink -f "${TEST_BIN}/parbackup")" = "${TEST_REPO}/parbackup/parbackup" ]
}

@test "update keeps existing links and is idempotent" {
  run "$PAR" update
  [ "$status" -eq 0 ]

  run "$PAR" update
  [ "$status" -eq 0 ]
  [[ "$output" == *"kept ${TEST_BIN}/parbackup"* ]]
  [ "$(readlink "${TEST_BIN}/parbackup")" = "${TEST_REPO}/parbackup/parbackup" ]
}

@test "update links a tool that appears later" {
  run "$PAR" update
  [ "$status" -eq 0 ]

  mkdir -p "${TEST_REPO}/newtool"
  printf '#!/usr/bin/env bash\nscript_version="0.1.0"\n' > "${TEST_REPO}/newtool/newtool"
  chmod +x "${TEST_REPO}/newtool/newtool"

  run "$PAR" update
  [ "$status" -eq 0 ]
  [ -L "${TEST_BIN}/newtool" ]

  run "$PAR" version
  [[ "$output" =~ newtool:\ +v0\.1\.0 ]]
}

@test "update leaves a foreign file alone" {
  mkdir -p "$TEST_BIN"
  echo "not ours" > "${TEST_BIN}/parbackup"

  run "$PAR" update
  [ "$status" -eq 0 ]
  [[ "$output" == *"not a symlink"* ]]
  [ ! -L "${TEST_BIN}/parbackup" ]
  [ "$(cat "${TEST_BIN}/parbackup")" = "not ours" ]
}

@test "update leaves a symlink to another path alone" {
  mkdir -p "$TEST_BIN"
  ln -s /bin/true "${TEST_BIN}/parbackup"

  run "$PAR" update
  [ "$status" -eq 0 ]
  [[ "$output" == *"points to"* ]]
  [ "$(readlink "${TEST_BIN}/parbackup")" = "/bin/true" ]
}

@test "help lists update and version" {
  run "$PAR" help
  [ "$status" -eq 0 ]
  [[ "$output" == *"update"* ]]
  [[ "$output" == *"version"* ]]
}

@test "unknown command fails and prints the help" {
  run "$PAR" bogus
  [ "$status" -eq 1 ]
  [[ "$output" == *"Unknown command 'bogus'"* ]]
  [[ "$output" == *"Usage: par <command>"* ]]
}

@test "update rejects unexpected arguments" {
  run "$PAR" update --bogus
  [ "$status" -eq 1 ]
  [[ "$output" == *"Unexpected argument '--bogus' for 'update'"* ]]
}

@test "subcommands accept --help" {
  run "$PAR" version --help
  [ "$status" -eq 0 ]
  [[ "$output" == *"Usage: par <command>"* ]]
}
