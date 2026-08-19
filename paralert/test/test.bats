#!/usr/bin/env bats

# Integration tests for paralert: SMTP delivery via curl against a MailPit instance.

TEST_DIR="$(cd "$(dirname "$BATS_TEST_FILENAME")" && pwd)"
PARALERT="${TEST_DIR}/../paralert"
COMPOSE_FILE="${TEST_DIR}/docker-compose.yaml"

MAILPIT_API="http://localhost:38025"

#
# MailPit helpers
#

wait_for_mailpit() {
  for i in $(seq 1 30); do
    if curl -sf "${MAILPIT_API}/api/v1/messages" > /dev/null 2>&1; then
      return 0
    fi
    sleep 1
  done
  return 1
}

mailpit_clear() {
  curl -sf -X DELETE "${MAILPIT_API}/api/v1/messages" > /dev/null 2>&1 || true
}

mailpit_message_count() {
  curl -sf "${MAILPIT_API}/api/v1/messages" | grep -o '"total":[0-9]*' | cut -d: -f2
}

mailpit_latest_subject() {
  curl -sf "${MAILPIT_API}/api/v1/messages" \
    | grep -o '"Subject":"[^"]*"' | head -1 | sed 's/"Subject":"//;s/"$//'
}

mailpit_latest_id() {
  curl -sf "${MAILPIT_API}/api/v1/messages" \
    | grep -o '"ID":"[^"]*"' | head -1 | sed 's/"ID":"//;s/"$//'
}

mailpit_latest_body() {
  local id
  id="$(mailpit_latest_id)"
  curl -sf "${MAILPIT_API}/api/v1/message/${id}" \
    | python3 -c "import sys,json; print(json.load(sys.stdin)['Text'])"
}

# Return the raw email source (preserves original CRLF/LF line endings)
mailpit_latest_raw() {
  local id
  id="$(mailpit_latest_id)"
  curl -sf "${MAILPIT_API}/api/v1/message/${id}/raw"
}

# Write a paralert config pointing to MailPit (with auth)
write_paralert_config() {
  local home_dir="$1"
  mkdir -p "${home_dir}/.config/par"
  cat > "${home_dir}/.config/par/paralert.conf" << 'CONF'
ALERT_SMTP_HOST='localhost'
ALERT_SMTP_PORT='31025'
ALERT_SMTP_USER='backups@test.local'
ALERT_SMTP_PASSWORD='p@$$w0rd$FZ=x!'
ALERT_SMTP_FROM='backups@test.local'
ALERT_RECIPIENTS='admin@test.local'
CONF
}

#
# Setup / Teardown
#

setup_file() {
  docker compose -f "$COMPOSE_FILE" down -v --remove-orphans 2> /dev/null || true
  docker compose -f "$COMPOSE_FILE" up -d
  wait_for_mailpit
}

teardown_file() {
  docker compose -f "$COMPOSE_FILE" down -v --remove-orphans 2> /dev/null || true
}

#
# Tests: send
#

@test "send: delivers an email via SMTP when configured" {
  mailpit_clear

  local home_dir
  home_dir="$(mktemp -d /tmp/paralert-test-home-XXXXXX)"
  write_paralert_config "$home_dir"

  env HOME="$home_dir" "$PARALERT" send \
    --subject "Hello from paralert" \
    --body "This is the body."

  sleep 1

  [ "$(mailpit_message_count)" -ge 1 ]
  [[ "$(mailpit_latest_subject)" == *"Hello from paralert"* ]]
  [[ "$(mailpit_latest_body)" == *"This is the body."* ]]

  rm -rf "$home_dir"
}

@test "send: silently skips (exit 0, no email) when no config exists" {
  mailpit_clear

  local home_dir
  home_dir="$(mktemp -d /tmp/paralert-test-home-XXXXXX)"

  run env HOME="$home_dir" "$PARALERT" send \
    --subject "Should not be sent" --body "nope"
  [ "$status" -eq 0 ]

  sleep 1
  [ "$(mailpit_message_count)" -eq 0 ]

  rm -rf "$home_dir"
}

@test "send: silently skips when config present but SMTP host unset" {
  mailpit_clear

  local home_dir
  home_dir="$(mktemp -d /tmp/paralert-test-home-XXXXXX)"
  mkdir -p "${home_dir}/.config/par"
  cat > "${home_dir}/.config/par/paralert.conf" << 'EOF'
# No SMTP settings configured
ALERT_RECIPIENTS='admin@test.local'
EOF

  run env HOME="$home_dir" "$PARALERT" send \
    --subject "Should not be sent" --body "nope"
  [ "$status" -eq 0 ]

  sleep 1
  [ "$(mailpit_message_count)" -eq 0 ]

  rm -rf "$home_dir"
}

@test "send: reads body from stdin when --body is omitted" {
  mailpit_clear

  local home_dir
  home_dir="$(mktemp -d /tmp/paralert-test-home-XXXXXX)"
  write_paralert_config "$home_dir"

  echo "body delivered via stdin" | env HOME="$home_dir" "$PARALERT" send \
    --subject "Stdin body test"

  sleep 1

  [ "$(mailpit_message_count)" -ge 1 ]
  [[ "$(mailpit_latest_body)" == *"body delivered via stdin"* ]]

  rm -rf "$home_dir"
}

@test "send: SMTP password with dollar sign does not break sending" {
  mailpit_clear

  local home_dir
  home_dir="$(mktemp -d /tmp/paralert-test-home-XXXXXX)"
  # write_paralert_config uses the $-laden password 'p@$$w0rd$FZ=x!'
  write_paralert_config "$home_dir"

  env HOME="$home_dir" "$PARALERT" send \
    --subject "Dollar password test" --body "ok"

  sleep 1
  [ "$(mailpit_message_count)" -ge 1 ]
  [[ "$(mailpit_latest_subject)" == *"Dollar password test"* ]]

  rm -rf "$home_dir"
}

@test "send: email uses CRLF line endings throughout" {
  mailpit_clear

  local home_dir
  home_dir="$(mktemp -d /tmp/paralert-test-home-XXXXXX)"
  write_paralert_config "$home_dir"

  printf 'line one\nline two\nline three\n' \
    | env HOME="$home_dir" "$PARALERT" send --subject "crlf_check"

  sleep 1

  local raw
  raw="$(mailpit_latest_raw)"
  [[ "$raw" == *"crlf_check"* ]]
  [[ "$raw" == *"Host:"* ]]
  [[ "$raw" == *"Date:"* ]]

  # Body starts after the first blank line (\r\n\r\n)
  local body
  body="$(printf '%s' "$raw" | sed -n '/^\r$/,$p' | tail -n +2)"

  local total_lines bare_lf_lines
  total_lines="$(printf '%s' "$body" | wc -l)"
  bare_lf_lines="$(printf '%s' "$body" | grep -cv $'\r$' || true)"

  [ "$total_lines" -ge 6 ]
  [ "$bare_lf_lines" -eq 0 ]

  rm -rf "$home_dir"
}

#
# Tests: config
#

@test "config: shows settings and masks the password" {
  local home_dir
  home_dir="$(mktemp -d /tmp/paralert-test-home-XXXXXX)"
  write_paralert_config "$home_dir"

  run env HOME="$home_dir" "$PARALERT" config
  [ "$status" -eq 0 ]

  [[ "$output" == *"ALERT_SMTP_HOST"* ]]
  [[ "$output" == *"ALERT_RECIPIENTS"* ]]
  [[ "$output" == *"admin@test.local"* ]]
  # Password must be masked, never shown in full
  [[ "$output" != *"p@\$\$w0rd\$FZ=x!"* ]]

  rm -rf "$home_dir"
}

@test "config: warns when no config exists" {
  local home_dir
  home_dir="$(mktemp -d /tmp/paralert-test-home-XXXXXX)"

  run env HOME="$home_dir" "$PARALERT" config
  [ "$status" -eq 0 ]
  [[ "$output" == *"No config found"* ]]

  rm -rf "$home_dir"
}

@test "config: dollar-sign values survive round-trip without expansion" {
  local home_dir
  home_dir="$(mktemp -d /tmp/paralert-test-home-XXXXXX)"
  mkdir -p "${home_dir}/.config/par"
  cat > "${home_dir}/.config/par/paralert.conf" << 'EOF'
ALERT_SMTP_PASSWORD='h3llo$WORLD!'
EOF

  run env HOME="$home_dir" "$PARALERT" config
  [ "$status" -eq 0 ]
  # Masked prefix proves the value was sourced without $-expansion
  [[ "$output" == *"h3ll"* ]]

  rm -rf "$home_dir"
}
