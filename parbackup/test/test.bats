#!/usr/bin/env bats

# Integration tests for parbackup: local backup/restore and S3 round-trip.

TEST_DIR="$(cd "$(dirname "$BATS_TEST_FILENAME")" && pwd)"
PARBACKUP="${TEST_DIR}/../parbackup"
COMPOSE_FILE="${TEST_DIR}/docker-compose.yaml"

# parbackup delegates alerting to the standalone paralert tool and assumes it is
# installed on the host PATH. paralert lives in the sibling tool directory, so
# put it on PATH here to make it discoverable in the tests.
PATH="$(cd "${TEST_DIR}/../../paralert" && pwd):${PATH}"
export PATH

MINIO_ENDPOINT="http://localhost:29000"
MINIO_ACCESS_KEY="minioadmin"
MINIO_SECRET_KEY="minioadmin"
MINIO_BUCKET="parbackup-test"

MAILPIT_SMTP_HOST="localhost"
MAILPIT_SMTP_PORT="21025"
MAILPIT_SMTP_USER="backups@test.local"
MAILPIT_SMTP_PASSWORD='p@$$w0rd$FZ=x!'
MAILPIT_API="http://localhost:28025"

#
# Helpers
#

pg_query() {
  docker exec -e PGPASSWORD=testpass parbackup-test-postgres \
    psql -U testuser -d testdb -t -A -c "$1"
}

pg_defaultdb_query() {
  docker exec -e PGPASSWORD=testpass parbackup-test-postgres-defaultdb \
    psql -U testuser -d postgres -t -A -c "$1"
}

mongo_query() {
  docker exec parbackup-test-mongo \
    mongosh -u testuser -p testpass --authenticationDatabase admin \
      --quiet --eval "$1"
}

wait_for_dbs() {
  for i in $(seq 1 30); do
    if docker exec parbackup-test-postgres pg_isready -q 2> /dev/null \
      && docker exec parbackup-test-postgres-defaultdb pg_isready -q 2> /dev/null \
      && docker exec parbackup-test-mongo mongosh -u testuser -p testpass \
           --authenticationDatabase admin --quiet \
           --eval "db.getSiblingDB('testdb').products.countDocuments()" 2> /dev/null \
         | grep -q "3"; then
      return 0
    fi
    sleep 1
  done
  return 1
}

wait_for_minio() {
  for i in $(seq 1 30); do
    if curl -sf "${MINIO_ENDPOINT}/minio/health/live" > /dev/null 2>&1; then
      return 0
    fi
    sleep 1
  done
  return 1
}

setup_minio() {
  wait_for_minio

  # Create test bucket via s3cmd
  local host
  host="$(echo "$MINIO_ENDPOINT" | sed 's|https\?://||')"

  s3cmd \
    --access_key="$MINIO_ACCESS_KEY" \
    --secret_key="$MINIO_SECRET_KEY" \
    --host="$host" \
    --host-bucket="$host/%(bucket)" \
    --no-ssl \
    mb "s3://${MINIO_BUCKET}" 2> /dev/null || true

  # Write parbackup config pointing to MinIO
  export TEST_CONFIG_DIR
  TEST_CONFIG_DIR="$(mktemp -d /tmp/parbackup-test-config-XXXXXX)"
  mkdir -p "${TEST_CONFIG_DIR}/.config/par"
  cat > "${TEST_CONFIG_DIR}/.config/par/parbackup.conf" << EOF
S3_ENDPOINT="${MINIO_ENDPOINT}"
S3_BUCKET="${MINIO_BUCKET}"
S3_ACCESS_KEY="${MINIO_ACCESS_KEY}"
S3_SECRET_KEY="${MINIO_SECRET_KEY}"
EOF
}

cron_exec() {
  docker exec parbackup-test-cron "$@"
}

wait_for_cron() {
  for i in $(seq 1 30); do
    if docker exec parbackup-test-cron bash --version > /dev/null 2>&1; then
      return 0
    fi
    sleep 1
  done
  return 1
}

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

# Write a paralert config with alert settings pointing to MailPit (with auth)
write_alert_config() {
  local config_dir="$1"
  cat > "${config_dir}/.config/par/paralert.conf" << 'CONF'
ALERT_SMTP_HOST='localhost'
ALERT_SMTP_PORT='21025'
ALERT_SMTP_USER='backups@test.local'
ALERT_SMTP_PASSWORD='p@$$w0rd$FZ=x!'
ALERT_SMTP_FROM='backups@test.local'
ALERT_RECIPIENTS='admin@test.local'
CONF
}

seed_uploads() {
  docker exec parbackup-test-uploads sh -c "
    mkdir -p /app/public/uploads/images
    echo 'fake-image-data-1' > /app/public/uploads/images/logo.png
    echo 'fake-image-data-2' > /app/public/uploads/images/banner.jpg
    echo 'hello world' > /app/public/uploads/readme.txt
  "
}

seed_local_dir() {
  export TEST_LOCAL_DIR="/tmp/parbackup-test-localdir"
  rm -rf "$TEST_LOCAL_DIR"
  mkdir -p "$TEST_LOCAL_DIR/css"
  echo 'body { color: red }' > "$TEST_LOCAL_DIR/css/style.css"
  echo 'h1 { font-size: 2em }' > "$TEST_LOCAL_DIR/css/headings.css"
  echo '<!DOCTYPE html>' > "$TEST_LOCAL_DIR/index.html"
}

#
# Setup / Teardown
#

setup_file() {
  # Isolated HOME prevents loading real user config (e.g. SMTP alert settings)
  export ISOLATED_HOME
  ISOLATED_HOME="$(mktemp -d /tmp/parbackup-test-iso-XXXXXX)"
  mkdir -p "${ISOLATED_HOME}/.config/par"

  # Clean previous state
  docker compose -f "$COMPOSE_FILE" down -v --remove-orphans 2> /dev/null || true
  rm -rf /tmp/parbackup/test_deployment-* 2> /dev/null || true

  # Start stack
  docker compose -f "$COMPOSE_FILE" up -d
  wait_for_dbs
  setup_minio
  wait_for_mailpit
  seed_uploads
  seed_local_dir
  wait_for_cron

  # Create local backup (--local to skip S3)
  BACKUP_OUTPUT="$(cd "$TEST_DIR" && env HOME="$ISOLATED_HOME" "$PARBACKUP" create --local 2>&1)"
  export BACKUP_ARCHIVE
  BACKUP_ARCHIVE="$(echo "$BACKUP_OUTPUT" | grep "Backup complete:" | sed 's/.*Backup complete: //')"
}

teardown_file() {
  docker compose -f "$COMPOSE_FILE" down -v --remove-orphans 2> /dev/null || true
  rm -rf /tmp/parbackup/test_deployment-* 2> /dev/null || true
  rm -rf /tmp/parbackup/test_defaultdb-* 2> /dev/null || true
  rm -rf /tmp/parbackup/restore-* 2> /dev/null || true
  rm -rf /tmp/parbackup-test-localdir 2> /dev/null || true
  rm -rf "${TEST_CONFIG_DIR:-}" 2> /dev/null || true
  rm -rf "${ISOLATED_HOME:-}" 2> /dev/null || true
}

#
# Test: Seed data
#

@test "postgres seed: Alice, Bob, Charlie exist" {
  result="$(pg_query "SELECT name FROM users ORDER BY id;")"
  [[ "$result" == *"Alice Mueller"* ]]
  [[ "$result" == *"Bob Schmidt"* ]]
  [[ "$result" == *"Charlie Weber"* ]]
}

@test "mongo seed: Widget A, Widget B, Gadget C exist" {
  result="$(mongo_query "db.getSiblingDB('testdb').products.find({},{name:1,_id:0}).sort({name:1}).toArray().map(d=>d.name).join('\n')")"
  [[ "$result" == *"Widget A"* ]]
  [[ "$result" == *"Widget B"* ]]
  [[ "$result" == *"Gadget C"* ]]
}

@test "uploads seed: logo.png, banner.jpg, readme.txt exist" {
  run docker exec parbackup-test-uploads sh -c "ls /app/public/uploads/images/ && cat /app/public/uploads/readme.txt"
  [ "$status" -eq 0 ]
  [[ "$output" == *"logo.png"* ]]
  [[ "$output" == *"banner.jpg"* ]]
  [[ "$output" == *"hello world"* ]]
}

@test "local dir seed: style.css, headings.css, index.html exist" {
  [ -f "/tmp/parbackup-test-localdir/css/style.css" ]
  [ -f "/tmp/parbackup-test-localdir/css/headings.css" ]
  [ -f "/tmp/parbackup-test-localdir/index.html" ]
  run cat /tmp/parbackup-test-localdir/css/style.css
  [[ "$output" == *"body { color: red }"* ]]
}

#
# Test: Local backup to tar.gz
#

@test "backup: tar.gz archive was created" {
  [ -f "$BACKUP_ARCHIVE" ]
  [[ "$BACKUP_ARCHIVE" == *.tar.gz ]]
}

@test "backup: archive contains Parbackupfile" {
  tar -tzf "$BACKUP_ARCHIVE" | grep -q "Parbackupfile"
}

@test "backup: archive contains app_db/dump.sql" {
  tar -tzf "$BACKUP_ARCHIVE" | grep -q "app_db/dump.sql"
}

@test "backup: archive contains app_mongo/dump.archive" {
  tar -tzf "$BACKUP_ARCHIVE" | grep -q "app_mongo/dump.archive"
}

@test "backup: archive contains app_uploads volume files" {
  tar -tzf "$BACKUP_ARCHIVE" | grep -q "app_uploads/images/logo.png"
  tar -tzf "$BACKUP_ARCHIVE" | grep -q "app_uploads/readme.txt"
}

@test "backup: archive contains app_static directory files" {
  tar -tzf "$BACKUP_ARCHIVE" | grep -q "app_static/css/style.css"
  tar -tzf "$BACKUP_ARCHIVE" | grep -q "app_static/css/headings.css"
  tar -tzf "$BACKUP_ARCHIVE" | grep -q "app_static/index.html"
}

@test "backup: postgres dump in archive contains seed data" {
  local tmpdir
  tmpdir="$(mktemp -d)"
  tar -xzf "$BACKUP_ARCHIVE" -C "$tmpdir"
  local dump_file
  dump_file="$(find "$tmpdir" -name dump.sql)"
  grep -q "Alice Mueller" "$dump_file"
  grep -q "Bob Schmidt" "$dump_file"
  rm -rf "$tmpdir"
}

@test "backup: --file flag allows creating backup from any working directory" {
  run env HOME="$ISOLATED_HOME" "$PARBACKUP" create --local -f "$TEST_DIR/Parbackupfile" 2>&1
  [ "$status" -eq 0 ]
  [[ "$output" == *"Backup complete:"* ]]

  local archive
  archive="$(echo "$output" | grep "Backup complete:" | sed 's/.*Backup complete: //')"
  [ -f "$archive" ]
  tar -tzf "$archive" | grep -q "Parbackupfile"
  tar -tzf "$archive" | grep -q "app_db/dump.sql"
  rm -f "$archive"
}

@test "backup: archive contains parbackup.log" {
  tar -tzf "$BACKUP_ARCHIVE" | grep -q "parbackup.log"
}

@test "backup: parbackup.log contains info-level entries for each service" {
  local tmpdir
  tmpdir="$(mktemp -d)"
  tar -xzf "$BACKUP_ARCHIVE" -C "$tmpdir"
  local log_file
  log_file="$(find "$tmpdir" -name parbackup.log)"
  [ -f "$log_file" ]

  # Should contain timestamped INFO entries
  grep -qE "^[0-9]{4}-[0-9]{2}-[0-9]{2} [0-9]{2}:[0-9]{2}:[0-9]{2} \[INFO\]" "$log_file"

  # Should mention each service being processed
  grep -q "Processing service 'app_db'" "$log_file"
  grep -q "Processing service 'app_mongo'" "$log_file"
  grep -q "Processing service 'app_uploads'" "$log_file"
  grep -q "Processing service 'app_static'" "$log_file"

  # Should contain dump completion messages
  grep -q "Postgres dump saved" "$log_file"
  grep -q "MongoDB dump saved" "$log_file"

  # Should contain command output from mongodump
  grep -q "\[mongodump\]" "$log_file"

  # Should end with the packaging message
  grep -q "Packaging backup:" "$log_file"

  rm -rf "$tmpdir"
}

#
# Test: Local restore from tar.gz
#

@test "restore: round-trip from tar.gz preserves data" {
  # Modify postgres
  pg_query "DELETE FROM users; INSERT INTO users (name, email) VALUES ('INTRUDER', 'hacked@evil.com');" > /dev/null
  result="$(pg_query "SELECT name FROM users;")"
  [[ "$result" == *"INTRUDER"* ]]

  # Modify mongo
  mongo_query "db.getSiblingDB('testdb').products.deleteMany({}); db.getSiblingDB('testdb').products.insertOne({name:'FAKE_PRODUCT',price:0,stock:0});" > /dev/null
  result="$(mongo_query "db.getSiblingDB('testdb').products.find({},{name:1,_id:0}).toArray().map(d=>d.name).join('\n')")"
  [[ "$result" == *"FAKE_PRODUCT"* ]]

  # Modify uploads volume
  docker exec parbackup-test-uploads sh -c "rm -rf /app/public/uploads/* && echo 'TAMPERED' > /app/public/uploads/evil.txt"
  result="$(docker exec parbackup-test-uploads ls /app/public/uploads/)"
  [[ "$result" == *"evil.txt"* ]]
  [[ "$result" != *"readme.txt"* ]]

  # Modify local directory
  rm -rf /tmp/parbackup-test-localdir/*
  echo 'TAMPERED' > /tmp/parbackup-test-localdir/evil.html
  [ -f "/tmp/parbackup-test-localdir/evil.html" ]
  [ ! -f "/tmp/parbackup-test-localdir/index.html" ]

  # Restore from local tar.gz (--force to skip confirmation prompt)
  run env HOME="$ISOLATED_HOME" "$PARBACKUP" restore --local --force "$BACKUP_ARCHIVE"
  [ "$status" -eq 0 ]
  [[ "$output" == *"Restore complete"* ]]

  # Verify postgres
  pg_result="$(pg_query "SELECT name FROM users ORDER BY id;")"
  [[ "$pg_result" == *"Alice Mueller"* ]]
  [[ "$pg_result" == *"Bob Schmidt"* ]]
  [[ "$pg_result" == *"Charlie Weber"* ]]
  [[ "$pg_result" != *"INTRUDER"* ]]
  pg_count="$(pg_query "SELECT count(*) FROM users;")"
  [ "$pg_count" -eq 3 ]

  # Verify mongo
  mongo_result="$(mongo_query "db.getSiblingDB('testdb').products.find({},{name:1,_id:0}).sort({name:1}).toArray().map(d=>d.name).join('\n')")"
  [[ "$mongo_result" == *"Widget A"* ]]
  [[ "$mongo_result" == *"Widget B"* ]]
  [[ "$mongo_result" == *"Gadget C"* ]]
  [[ "$mongo_result" != *"FAKE_PRODUCT"* ]]
  mongo_count="$(mongo_query "db.getSiblingDB('testdb').products.countDocuments()")"
  [ "$mongo_count" -eq 3 ]

  # Verify uploads volume
  uploads_result="$(docker exec parbackup-test-uploads ls -R /app/public/uploads/)"
  [[ "$uploads_result" == *"logo.png"* ]]
  [[ "$uploads_result" == *"banner.jpg"* ]]
  [[ "$uploads_result" == *"readme.txt"* ]]
  [[ "$uploads_result" != *"evil.txt"* ]]
  readme_content="$(docker exec parbackup-test-uploads cat /app/public/uploads/readme.txt)"
  [[ "$readme_content" == *"hello world"* ]]

  # Verify local directory
  [ -f "/tmp/parbackup-test-localdir/css/style.css" ]
  [ -f "/tmp/parbackup-test-localdir/css/headings.css" ]
  [ -f "/tmp/parbackup-test-localdir/index.html" ]
  [ ! -f "/tmp/parbackup-test-localdir/evil.html" ]
  run cat /tmp/parbackup-test-localdir/css/style.css
  [[ "$output" == *"body { color: red }"* ]]
}

#
# Test: Postgres with default "postgres" database name
#

@test "restore: postgres with db named 'postgres' (drop-while-connected edge case)" {
  # Seed data into the default-db container
  pg_defaultdb_query "CREATE TABLE IF NOT EXISTS items (id SERIAL PRIMARY KEY, label TEXT NOT NULL);" > /dev/null
  pg_defaultdb_query "DELETE FROM items;" > /dev/null
  pg_defaultdb_query "INSERT INTO items (label) VALUES ('original_a'), ('original_b');" > /dev/null

  count="$(pg_defaultdb_query "SELECT count(*) FROM items;")"
  [ "$count" -eq 2 ]

  # Create backup using the defaultdb Parbackupfile
  local backup_output
  backup_output="$(cd "$TEST_DIR" && env HOME="$ISOLATED_HOME" PARBACKUPFILE=Parbackupfile.defaultdb "$PARBACKUP" create --local 2>&1)"
  local archive
  archive="$(echo "$backup_output" | grep "Backup complete:" | sed 's/.*Backup complete: //')"
  [ -f "$archive" ]

  # Modify data
  pg_defaultdb_query "DELETE FROM items; INSERT INTO items (label) VALUES ('TAMPERED');" > /dev/null
  result="$(pg_defaultdb_query "SELECT label FROM items;")"
  [[ "$result" == *"TAMPERED"* ]]

  # Restore
  run env HOME="$ISOLATED_HOME" "$PARBACKUP" restore --local --force "$archive"
  [ "$status" -eq 0 ]
  [[ "$output" == *"Restore complete"* ]]

  # Verify original data is back
  restored="$(pg_defaultdb_query "SELECT label FROM items ORDER BY id;")"
  [[ "$restored" == *"original_a"* ]]
  [[ "$restored" == *"original_b"* ]]
  [[ "$restored" != *"TAMPERED"* ]]
  restored_count="$(pg_defaultdb_query "SELECT count(*) FROM items;")"
  [ "$restored_count" -eq 2 ]
}

#
# Test: Config
#

@test "config: values with dollar signs are preserved via single-quoting" {
  local cfg_dir
  cfg_dir="$(mktemp -d /tmp/parbackup-test-cfg-XXXXXX)"
  mkdir -p "${cfg_dir}/.config/par"

  # Write a config with a dollar sign in a value (simulates save_config output)
  cat > "${cfg_dir}/.config/par/parbackup.conf" << 'EOF'
S3_SECRET_KEY='pa$$w0rd$FZ=x'
EOF

  # Source it via the script's load_config by running `parbackup config`
  run env HOME="$cfg_dir" "$PARBACKUP" config 2>&1
  [ "$status" -eq 0 ]

  # The dollar signs must survive round-trip without expansion
  [[ "$output" == *'pa$$'* ]]

  rm -rf "$cfg_dir"
}

#
# Test: Cron management
#

@test "cron: show lists no entries when crontab is empty" {
  # Clear crontab inside the cron container
  cron_exec crontab -r 2> /dev/null || true

  run cron_exec parbackup cron show 2>&1
  [ "$status" -eq 0 ]
  [[ "$output" == *"No parbackup cron entries found"* ]]
}

@test "cron: show lists parbackup entries" {
  # Clear crontab, then inject a fake entry
  cron_exec crontab -r 2> /dev/null || true

  local fake_entry="0 3 * * * /usr/local/bin/parbackup create -f /test/Parbackupfile # parbackup:test_deployment"
  cron_exec sh -c "echo '$fake_entry' | crontab -"

  run cron_exec parbackup cron show 2>&1
  [ "$status" -eq 0 ]
  [[ "$output" == *"parbackup:test_deployment"* ]]

  # Cleanup
  cron_exec crontab -r 2> /dev/null || true
}

@test "cron: add creates entry with --schedule flag" {
  cron_exec crontab -r 2> /dev/null || true

  run cron_exec parbackup cron -f /test/Parbackupfile --schedule "0 3 * * *" 2>&1
  [ "$status" -eq 0 ]
  [[ "$output" == *"Adding cron entry"* ]]

  # Verify the entry was created with the correct schedule
  local entry
  entry="$(cron_exec crontab -l)"
  [[ "$entry" == *"0 3 * * *"* ]]
  [[ "$entry" == *"parbackup:test_deployment"* ]]

  # Cleanup
  cron_exec crontab -r 2> /dev/null || true
}

@test "cron: update changes schedule of existing entry" {
  cron_exec crontab -r 2> /dev/null || true

  # Add initial entry
  cron_exec parbackup cron -f /test/Parbackupfile --schedule "0 3 * * *" 2>&1

  # Update to a different schedule
  run cron_exec parbackup cron -f /test/Parbackupfile --schedule "* * * * *" 2>&1
  [ "$status" -eq 0 ]
  [[ "$output" == *"Updating existing cron entry"* ]]

  # Verify only one entry exists with the new schedule
  local entry
  entry="$(cron_exec crontab -l)"
  [[ "$entry" == *"* * * * *"* ]]
  [[ "$entry" != *"0 3 * * *"* ]]

  # Cleanup
  cron_exec crontab -r 2> /dev/null || true
}

@test "cron: add does not clobber entries with similar prefix names" {
  cron_exec crontab -r 2> /dev/null || true

  # Pre-populate with an entry whose name is a superstring of "test"
  local existing_entry="0 3 * * * /usr/local/bin/parbackup create -f /test/Parbackupfile # parbackup:test_deployment"
  cron_exec sh -c "echo '$existing_entry' | crontab -"

  # Add a new entry for BACKUP_NAME="test" (prefix of "test_deployment")
  run cron_exec parbackup cron -f /test/Parbackupfile.prefix --schedule "0 6 * * *" 2>&1
  [ "$status" -eq 0 ]
  [[ "$output" == *"Adding cron entry"* ]]

  # Both entries must exist
  local entries
  entries="$(cron_exec crontab -l)"
  [[ "$entries" == *"parbackup:test_deployment"* ]]
  [[ "$entries" == *"parbackup:test"* ]]

  # Cleanup
  cron_exec crontab -r 2> /dev/null || true
}

@test "cron: remove does not clobber entries with similar prefix names" {
  cron_exec crontab -r 2> /dev/null || true

  # Pre-populate with two entries: "test_deployment" and "test"
  cron_exec sh -c 'echo "0 3 * * * /usr/local/bin/parbackup create -f /test/Parbackupfile # parbackup:test_deployment
0 6 * * * /usr/local/bin/parbackup create -f /test/Parbackupfile.prefix # parbackup:test" | crontab -'

  # Remove only the "test" entry
  run cron_exec parbackup cron remove -f /test/Parbackupfile.prefix 2>&1
  [ "$status" -eq 0 ]
  [[ "$output" == *"Removed cron entry"* ]]

  # "test_deployment" must still exist
  local entries
  entries="$(cron_exec crontab -l)"
  [[ "$entries" == *"parbackup:test_deployment"* ]]

  # "test" (exact) must be gone
  ! echo "$entries" | grep -q "parbackup:test$"

  # Cleanup
  cron_exec crontab -r 2> /dev/null || true
}

@test "cron: remove deletes entry by backup name" {
  # Clear crontab, then inject a fake entry
  cron_exec crontab -r 2> /dev/null || true

  local fake_entry="0 3 * * * /usr/local/bin/parbackup create -f /test/Parbackupfile # parbackup:test_deployment"
  cron_exec sh -c "echo '$fake_entry' | crontab -"

  # Verify it's there
  cron_exec crontab -l | grep -qF "parbackup:test_deployment"

  # Remove it
  run cron_exec parbackup cron remove -f /test/Parbackupfile 2>&1
  [ "$status" -eq 0 ]
  [[ "$output" == *"Removed cron entry"* ]]

  # Verify it's gone
  ! cron_exec crontab -l 2> /dev/null | grep -qF "parbackup:test_deployment"

  # Cleanup
  cron_exec crontab -r 2> /dev/null || true
}

#
# Test: S3 backend round-trip (via local MinIO)
#

@test "s3: create uploads backup to MinIO" {
  run env HOME="$TEST_CONFIG_DIR" bash -c "cd '$TEST_DIR' && '$PARBACKUP' create 2>&1"
  [ "$status" -eq 0 ]
  [[ "$output" == *"S3 upload complete"* ]]
  [[ "$output" == *"Backup complete:"* ]]

  # Extract s3 key from output for later tests
  export S3_BACKUP_ARCHIVE
  S3_BACKUP_ARCHIVE="$(echo "$output" | grep "Uploading to S3:" | sed 's/.*Uploading to S3: s3:\/\/[^/]*\///')"
  [ -n "$S3_BACKUP_ARCHIVE" ]
}

@test "s3: ls shows uploaded backup" {
  run env HOME="$TEST_CONFIG_DIR" "$PARBACKUP" ls 2>&1
  [ "$status" -eq 0 ]
  [[ "$output" == *"test_deployment"* ]]
}

@test "s3: ls with prefix filters results" {
  run env HOME="$TEST_CONFIG_DIR" "$PARBACKUP" ls test_deployment/ 2>&1
  [ "$status" -eq 0 ]
  [[ "$output" == *"test_deployment-"* ]]
}

@test "s3: ls outputs backup keys" {
  run env HOME="$TEST_CONFIG_DIR" "$PARBACKUP" ls 2>&1
  [ "$status" -eq 0 ]

  # Each backup should be listed as a key (no s3://bucket prefix)
  echo "$output" | grep -q "test_deployment/test_deployment-.*\.tar\.gz"
}

@test "s3: ls --timestamps outputs epoch and key" {
  local ts_output
  ts_output="$(env HOME="$TEST_CONFIG_DIR" "$PARBACKUP" ls --timestamps 2> /dev/null | grep $'^[0-9]')"
  [ -n "$ts_output" ]

  # Each line should be: <epoch>\t<key>
  local epoch key
  IFS=$'\t' read -r epoch key <<< "$(echo "$ts_output" | head -1)"
  [[ "$epoch" =~ ^[0-9]+$ ]]
  [[ "$key" == test_deployment/test_deployment-*.tar.gz ]]
}

@test "s3: download fetches backup archive" {
  # Determine the S3 key
  local list_output
  list_output="$(env HOME="$TEST_CONFIG_DIR" "$PARBACKUP" ls test_deployment/ 2>&1)"
  local s3_key
  s3_key="$(echo "$list_output" | grep -o "test_deployment/test_deployment-[^ ]*" | head -1)"
  [ -n "$s3_key" ]

  local expected_file="/tmp/parbackup/$(basename "$s3_key")"
  rm -f "$expected_file"

  run env HOME="$TEST_CONFIG_DIR" "$PARBACKUP" download "$s3_key" 2>&1
  [ "$status" -eq 0 ]
  [[ "$output" == *"Downloaded to $expected_file"* ]]
  [ -f "$expected_file" ]

  # The downloaded file should be a valid tar.gz containing the Parbackupfile
  tar -tzf "$expected_file" | grep -q "Parbackupfile"

  rm -f "$expected_file"
}

@test "s3: download --force overwrites existing file" {
  # Determine the S3 key
  local list_output
  list_output="$(env HOME="$TEST_CONFIG_DIR" "$PARBACKUP" ls test_deployment/ 2>&1)"
  local s3_key
  s3_key="$(echo "$list_output" | grep -o "test_deployment/test_deployment-[^ ]*" | head -1)"
  [ -n "$s3_key" ]

  local expected_file="/tmp/parbackup/$(basename "$s3_key")"

  # Create a dummy file to trigger the "already exists" path
  echo "dummy" > "$expected_file"

  run env HOME="$TEST_CONFIG_DIR" "$PARBACKUP" download --force "$s3_key" 2>&1
  [ "$status" -eq 0 ]
  [[ "$output" == *"File already exists"* ]]
  [[ "$output" == *"Downloaded to $expected_file"* ]]
  [ -f "$expected_file" ]

  # Should be a valid archive, not the dummy content
  tar -tzf "$expected_file" | grep -q "Parbackupfile"

  rm -f "$expected_file"
}

@test "s3: download fails without backup_ref" {
  run env HOME="$TEST_CONFIG_DIR" "$PARBACKUP" download 2>&1
  [ "$status" -eq 1 ]
  [[ "$output" == *"Missing required argument"* ]]
}

@test "s3: restore round-trip from MinIO preserves data" {
  # Determine the S3 key by listing — output is keys, one per line
  local list_output
  list_output="$(env HOME="$TEST_CONFIG_DIR" "$PARBACKUP" ls test_deployment/ 2>&1)"
  local s3_key
  s3_key="$(echo "$list_output" | grep -o "test_deployment/test_deployment-[^ ]*" | head -1)"
  [ -n "$s3_key" ]

  # Modify postgres
  pg_query "DELETE FROM users; INSERT INTO users (name, email) VALUES ('S3_INTRUDER', 's3hack@evil.com');" > /dev/null
  result="$(pg_query "SELECT name FROM users;")"
  [[ "$result" == *"S3_INTRUDER"* ]]

  # Modify mongo
  mongo_query "db.getSiblingDB('testdb').products.deleteMany({}); db.getSiblingDB('testdb').products.insertOne({name:'S3_FAKE',price:0,stock:0});" > /dev/null
  result="$(mongo_query "db.getSiblingDB('testdb').products.find({},{name:1,_id:0}).toArray().map(d=>d.name).join('\n')")"
  [[ "$result" == *"S3_FAKE"* ]]

  # Restore from S3 (--force to skip confirmation)
  run env HOME="$TEST_CONFIG_DIR" "$PARBACKUP" restore --force "$s3_key" 2>&1
  [ "$status" -eq 0 ]
  [[ "$output" == *"Restore complete"* ]]

  # Verify postgres
  pg_result="$(pg_query "SELECT name FROM users ORDER BY id;")"
  [[ "$pg_result" == *"Alice Mueller"* ]]
  [[ "$pg_result" == *"Bob Schmidt"* ]]
  [[ "$pg_result" == *"Charlie Weber"* ]]
  [[ "$pg_result" != *"S3_INTRUDER"* ]]
  pg_count="$(pg_query "SELECT count(*) FROM users;")"
  [ "$pg_count" -eq 3 ]

  # Verify mongo
  mongo_result="$(mongo_query "db.getSiblingDB('testdb').products.find({},{name:1,_id:0}).sort({name:1}).toArray().map(d=>d.name).join('\n')")"
  [[ "$mongo_result" == *"Widget A"* ]]
  [[ "$mongo_result" == *"Widget B"* ]]
  [[ "$mongo_result" == *"Gadget C"* ]]
  [[ "$mongo_result" != *"S3_FAKE"* ]]
  mongo_count="$(mongo_query "db.getSiblingDB('testdb').products.countDocuments()")"
  [ "$mongo_count" -eq 3 ]
}

@test "s3: restore --pick rejects --local" {
  run env HOME="$TEST_CONFIG_DIR" "$PARBACKUP" restore --pick --local 2>&1
  [ "$status" -eq 1 ]
  [[ "$output" == *"--pick and --local cannot be used together"* ]]
}

@test "s3: restore --pick rejects extra backup_ref argument" {
  run env HOME="$TEST_CONFIG_DIR" "$PARBACKUP" restore --pick some_key 2>&1
  [ "$status" -eq 1 ]
  [[ "$output" == *"--pick does not accept a backup reference argument"* ]]
}

#
# Test: Backup cleanup / retention (S3 + local temp files)
#

@test "cleanup: --dry-run lists old backups and temp files without deleting" {
  # Confirm the backup from earlier tests still exists
  run env HOME="$TEST_CONFIG_DIR" "$PARBACKUP" ls 2>&1
  [ "$status" -eq 0 ]
  [[ "$output" == *"test_deployment-"* ]]

  # Create old temp files and run logs in the working directory
  local old_archive="/tmp/parbackup/test_deployment-old.tar.gz"
  local old_runlog="/tmp/parbackup/runs/run-old.log"
  mkdir -p /tmp/parbackup/runs
  echo "old-archive" > "$old_archive"
  echo "old-runlog" > "$old_runlog"
  # Backdate mtime to 30 days ago
  touch -d "30 days ago" "$old_archive" "$old_runlog"

  # Dry-run cleanup with _NOW set 30 days in the future
  echo 'RETENTION_DAYS="7"' >> "${TEST_CONFIG_DIR}/.config/par/parbackup.conf"
  local future_now=$(($( date +%s) + 30 * 86400))
  run env HOME="$TEST_CONFIG_DIR" _NOW="$future_now" "$PARBACKUP" cleanup --dry-run 2>&1
  [ "$status" -eq 0 ]
  [[ "$output" == *"Would delete"* ]]
  [[ "$output" == *"Would delete temp:"* ]]
  [[ "$output" == *"Would delete run log:"* ]]

  # Verify the S3 backup still exists (not actually deleted)
  run env HOME="$TEST_CONFIG_DIR" "$PARBACKUP" ls 2>&1
  [ "$status" -eq 0 ]
  [[ "$output" == *"test_deployment-"* ]]

  # Verify temp files still exist (dry-run should not delete)
  [ -f "$old_archive" ]
  [ -f "$old_runlog" ]

  # Clean up fixtures
  rm -f "$old_archive" "$old_runlog"
}

@test "cleanup: deletes old backups, temp files, and run logs" {
  # Confirm the backup from earlier tests still exists
  run env HOME="$TEST_CONFIG_DIR" "$PARBACKUP" ls 2>&1
  [ "$status" -eq 0 ]
  [[ "$output" == *"test_deployment-"* ]]

  # Create old temp files and run logs in the working directory
  local old_archive="/tmp/parbackup/test_deployment-old.tar.gz"
  local old_staging="/tmp/parbackup/test_deployment-old"
  local old_runlog="/tmp/parbackup/runs/run-old.log"
  mkdir -p /tmp/parbackup/runs "$old_staging"
  echo "old-archive" > "$old_archive"
  echo "old-runlog" > "$old_runlog"
  # Backdate mtime to 30 days ago
  touch -d "30 days ago" "$old_archive" "$old_staging" "$old_runlog"

  # Run cleanup with _NOW set 30 days in the future.
  # With RETENTION_DAYS=7 the cutoff lands 23 days from now,
  # so every backup with today's timestamp looks "old".
  echo 'RETENTION_DAYS="7"' >> "${TEST_CONFIG_DIR}/.config/par/parbackup.conf"
  local future_now=$(($( date +%s) + 30 * 86400))
  run env HOME="$TEST_CONFIG_DIR" _NOW="$future_now" "$PARBACKUP" cleanup 2>&1
  [ "$status" -eq 0 ]
  [[ "$output" == *"Deleted"* ]]
  [[ "$output" == *"Deleting old temp:"* ]]
  [[ "$output" == *"Deleting old run log:"* ]]

  # Verify the S3 backup is gone
  run env HOME="$TEST_CONFIG_DIR" "$PARBACKUP" ls 2>&1
  [ "$status" -eq 0 ]
  [[ "$output" != *"test_deployment-"* ]]

  # Verify temp files and run logs are gone
  [ ! -f "$old_archive" ]
  [ ! -d "$old_staging" ]
  [ ! -f "$old_runlog" ]

  # Verify the runs directory itself still exists
  [ -d "/tmp/parbackup/runs" ]
}

#
# Test: Error notification emails
#

@test "alert: failed backup sends error notification" {
  mailpit_clear

  # Create a config with SMTP pointing to MailPit
  local email_config_dir
  email_config_dir="$(mktemp -d /tmp/parbackup-test-email-XXXXXX)"
  mkdir -p "${email_config_dir}/.config/par"
  write_alert_config "$email_config_dir"

  # Create a broken Parbackupfile that references a non-existent container
  local broken_backupfile
  broken_backupfile="$(mktemp /tmp/parbackup-test-broken-XXXXXX)"
  cat > "$broken_backupfile" << 'EOF'
BACKUP_NAME="email_test"
SERVICES="broken_db"
BROKEN_DB_TYPE="postgres"
BROKEN_DB_CONTAINER="parbackup-nonexistent-container"
BROKEN_DB_USER="testuser"
BROKEN_DB_PASSWORD="testpass"
BROKEN_DB_DB="testdb"
EOF

  # Run create — should fail because the container doesn't exist
  run env HOME="$email_config_dir" "$PARBACKUP" create --local -f "$broken_backupfile" 2>&1
  [ "$status" -ne 0 ]

  # Give MailPit a moment to process
  sleep 1

  # Verify an email was received
  local count
  count="$(mailpit_message_count)"
  [ "$count" -ge 1 ]

  # Verify the subject mentions the deployment name
  local subject
  subject="$(mailpit_latest_subject)"
  [[ "$subject" == *"email_test"* ]]
  [[ "$subject" == *"FAILED"* ]]

  # Cleanup
  rm -f "$broken_backupfile"
  rm -rf "$email_config_dir"
  rm -rf /tmp/parbackup/email_test-* 2> /dev/null || true
}

@test "alert: successful backup does not send notification" {
  mailpit_clear

  # Create a config with SMTP pointing to MailPit
  local email_config_dir
  email_config_dir="$(mktemp -d /tmp/parbackup-test-email-XXXXXX)"
  mkdir -p "${email_config_dir}/.config/par"
  write_alert_config "$email_config_dir"

  # Run a successful local backup
  run env HOME="$email_config_dir" "$PARBACKUP" create --local -f "$TEST_DIR/Parbackupfile" 2>&1
  [ "$status" -eq 0 ]
  [[ "$output" == *"Backup complete:"* ]]

  # Give MailPit a moment
  sleep 1

  # Verify no email was sent
  local count
  count="$(mailpit_message_count)"
  [ "$count" -eq 0 ]

  # Cleanup
  rm -rf "$email_config_dir"
  local archive
  archive="$(echo "$output" | grep "Backup complete:" | sed 's/.*Backup complete: //')"
  rm -f "$archive"
}

@test "alert: no email sent when SMTP is not configured" {
  mailpit_clear

  # Create a config WITHOUT SMTP settings
  local no_smtp_dir
  no_smtp_dir="$(mktemp -d /tmp/parbackup-test-nosmtp-XXXXXX)"
  mkdir -p "${no_smtp_dir}/.config/par"
  cat > "${no_smtp_dir}/.config/par/parbackup.conf" << 'EOF'
# No SMTP settings
EOF

  # Create a broken Parbackupfile
  local broken_backupfile
  broken_backupfile="$(mktemp /tmp/parbackup-test-broken-XXXXXX)"
  cat > "$broken_backupfile" << 'EOF'
BACKUP_NAME="no_smtp_test"
SERVICES="broken_db"
BROKEN_DB_TYPE="postgres"
BROKEN_DB_CONTAINER="parbackup-nonexistent-container"
BROKEN_DB_USER="testuser"
BROKEN_DB_PASSWORD="testpass"
BROKEN_DB_DB="testdb"
EOF

  # Run create — should fail
  run env HOME="$no_smtp_dir" "$PARBACKUP" create --local -f "$broken_backupfile" 2>&1
  [ "$status" -ne 0 ]

  sleep 1

  # No email should have been sent
  local count
  count="$(mailpit_message_count)"
  [ "$count" -eq 0 ]

  # Cleanup
  rm -f "$broken_backupfile"
  rm -rf "$no_smtp_dir"
  rm -rf /tmp/parbackup/no_smtp_test-* 2> /dev/null || true
}

@test "alert: SMTP password with dollar sign does not break email sending" {
  mailpit_clear

  # Create a config with SMTP credentials containing dollar signs
  local email_config_dir
  email_config_dir="$(mktemp -d /tmp/parbackup-test-email-XXXXXX)"
  mkdir -p "${email_config_dir}/.config/par"
  cat > "${email_config_dir}/.config/par/paralert.conf" << 'EOF'
ALERT_SMTP_HOST='localhost'
ALERT_SMTP_PORT='21025'
ALERT_SMTP_USER='backups@test.local'
ALERT_SMTP_PASSWORD='p@$$w0rd$FZ=x!'
ALERT_SMTP_FROM='backups@test.local'
ALERT_RECIPIENTS='admin@test.local'
EOF

  # Create a broken Parbackupfile to trigger a failure
  local broken_backupfile
  broken_backupfile="$(mktemp /tmp/parbackup-test-broken-XXXXXX)"
  cat > "$broken_backupfile" << 'EOF'
BACKUP_NAME="dollar_test"
SERVICES="broken_db"
BROKEN_DB_TYPE="postgres"
BROKEN_DB_CONTAINER="parbackup-nonexistent-container"
BROKEN_DB_USER="testuser"
BROKEN_DB_PASSWORD="testpass"
BROKEN_DB_DB="testdb"
EOF

  # Run create — should fail and send email despite $ in SMTP password
  run env HOME="$email_config_dir" "$PARBACKUP" create --local -f "$broken_backupfile" 2>&1
  [ "$status" -ne 0 ]

  sleep 1

  # Verify an email was received (proves the $ in password didn't break curl)
  local count
  count="$(mailpit_message_count)"
  [ "$count" -ge 1 ]

  local subject
  subject="$(mailpit_latest_subject)"
  [[ "$subject" == *"dollar_test"* ]]
  [[ "$subject" == *"FAILED"* ]]

  # Cleanup
  rm -f "$broken_backupfile"
  rm -rf "$email_config_dir"
  rm -rf /tmp/parbackup/dollar_test-* 2> /dev/null || true
}

@test "alert: error notification uses CRLF line endings throughout" {
  mailpit_clear

  # Create a config with SMTP pointing to MailPit
  local email_config_dir
  email_config_dir="$(mktemp -d /tmp/parbackup-test-email-XXXXXX)"
  mkdir -p "${email_config_dir}/.config/par"
  write_alert_config "$email_config_dir"

  # Create a broken Parbackupfile to trigger a failure
  local broken_backupfile
  broken_backupfile="$(mktemp /tmp/parbackup-test-broken-XXXXXX)"
  cat > "$broken_backupfile" << 'EOF'
BACKUP_NAME="crlf_test"
SERVICES="broken_db"
BROKEN_DB_TYPE="postgres"
BROKEN_DB_CONTAINER="parbackup-nonexistent-container"
BROKEN_DB_USER="testuser"
BROKEN_DB_PASSWORD="testpass"
BROKEN_DB_DB="testdb"
EOF

  # Run create — should fail and send email
  run env HOME="$email_config_dir" "$PARBACKUP" create --local -f "$broken_backupfile" 2>&1
  [ "$status" -ne 0 ]

  sleep 1

  # Fetch the raw email source (preserves original line endings)
  local raw
  raw="$(mailpit_latest_raw)"

  # The raw source must contain expected content
  [[ "$raw" == *"crlf_test"* ]]
  [[ "$raw" == *"--- Run log ---"* ]]
  [[ "$raw" == *"Host:"* ]]
  [[ "$raw" == *"Date:"* ]]

  # Extract the body (everything after the first blank line = \r\n\r\n)
  local body
  body="$(printf '%s' "$raw" | sed -n '/^\r$/,$p' | tail -n +2)"

  # Body must use CRLF: every line must end with \r\n, so count \r at end of lines.
  # Lines without \r (bare LF) would indicate broken line endings.
  local total_lines bare_lf_lines
  total_lines="$(printf '%s' "$body" | wc -l)"
  bare_lf_lines="$(printf '%s' "$body" | grep -cv $'\r$' || true)"

  # There must be multiple lines in the body
  [ "$total_lines" -ge 6 ]
  # Zero lines should have bare LF (all must end with \r)
  [ "$bare_lf_lines" -eq 0 ]

  # Cleanup
  rm -f "$broken_backupfile"
  rm -rf "$email_config_dir"
  rm -rf /tmp/parbackup/crlf_test-* 2> /dev/null || true
}

#
# Test: Run log (dual logging)
#

@test "run log: cleaned up after successful backup" {
  # Use isolated HOME so we never touch real config
  local iso_home
  iso_home="$(mktemp -d /tmp/parbackup-test-iso-XXXXXX)"
  mkdir -p "${iso_home}/.config/par"

  run env HOME="$iso_home" "$PARBACKUP" create --local -f "$TEST_DIR/Parbackupfile" 2>&1
  [ "$status" -eq 0 ]
  [[ "$output" == *"Backup complete:"* ]]

  # Extract run log path from output and verify it was cleaned up
  local run_log
  run_log="$(echo "$output" | grep "Run log:" | sed 's/.*Run log: //')"
  [ -n "$run_log" ]
  [ ! -f "$run_log" ]

  # Cleanup archive
  local archive
  archive="$(echo "$output" | grep "Backup complete:" | sed 's/.*Backup complete: //')"
  rm -f "$archive"
  rm -rf "$iso_home"
}

@test "run log: survives after failed backup" {
  # Use isolated HOME so we never touch real config
  local iso_home
  iso_home="$(mktemp -d /tmp/parbackup-test-iso-XXXXXX)"
  mkdir -p "${iso_home}/.config/par"

  local broken_backupfile
  broken_backupfile="$(mktemp /tmp/parbackup-test-broken-XXXXXX)"
  cat > "$broken_backupfile" << 'EOF'
BACKUP_NAME="runlog_fail_test"
SERVICES="broken_db"
BROKEN_DB_TYPE="postgres"
BROKEN_DB_CONTAINER="parbackup-nonexistent-container"
BROKEN_DB_USER="testuser"
BROKEN_DB_PASSWORD="testpass"
BROKEN_DB_DB="testdb"
EOF

  run env HOME="$iso_home" "$PARBACKUP" create --local -f "$broken_backupfile" 2>&1
  [ "$status" -ne 0 ]

  # Extract run log path from output
  local run_log
  run_log="$(echo "$output" | grep "Run log:" | sed 's/.*Run log: //')"
  [ -n "$run_log" ]

  # Run log should still exist on failure
  [ -f "$run_log" ]

  # Run log should contain log entries
  local content
  content="$(cat "$run_log")"
  [[ "$content" == *"[INFO]"* ]]
  [[ "$content" == *"[ERROR]"* ]]

  # Cleanup
  rm -f "$broken_backupfile" "$run_log"
  rm -rf "$iso_home"
  rm -rf /tmp/parbackup/runlog_fail_test-* 2> /dev/null || true
}

@test "run log: first entries are command and working directory" {
  # Use isolated HOME so we never touch real config
  local iso_home
  iso_home="$(mktemp -d /tmp/parbackup-test-iso-XXXXXX)"
  mkdir -p "${iso_home}/.config/par"

  local broken_backupfile
  broken_backupfile="$(mktemp /tmp/parbackup-test-broken-XXXXXX)"
  cat > "$broken_backupfile" << 'EOF'
BACKUP_NAME="runlog_header_test"
SERVICES="broken_db"
BROKEN_DB_TYPE="postgres"
BROKEN_DB_CONTAINER="parbackup-nonexistent-container"
BROKEN_DB_USER="testuser"
BROKEN_DB_PASSWORD="testpass"
BROKEN_DB_DB="testdb"
EOF

  run env HOME="$iso_home" "$PARBACKUP" create --local -f "$broken_backupfile" 2>&1
  [ "$status" -ne 0 ]

  # Extract run log path from output
  local run_log
  run_log="$(echo "$output" | grep "Run log:" | sed 's/.*Run log: //')"
  [ -n "$run_log" ]
  [ -f "$run_log" ]

  # First line must be the full command invocation
  local line1
  line1="$(sed -n '1p' "$run_log")"
  [[ "$line1" == *"[INFO] Command:"* ]]
  [[ "$line1" == *"create --local -f"* ]]

  # Second line must be the working directory
  local line2
  line2="$(sed -n '2p' "$run_log")"
  [[ "$line2" == *"[INFO] Working directory:"* ]]
  [[ "$line2" == *"/"* ]]

  # Cleanup
  rm -f "$broken_backupfile" "$run_log"
  rm -rf "$iso_home"
  rm -rf /tmp/parbackup/runlog_header_test-* 2> /dev/null || true
}

#
# Test: S3 command stderr is captured in run log and alert email
#

@test "s3 logging: upload stderr is captured in run log" {
  # Create a config pointing to a bogus S3 endpoint that s3cmd cannot reach.
  # s3cmd will emit error output on stderr and exit non-zero.
  local cfg_dir
  cfg_dir="$(mktemp -d /tmp/parbackup-test-s3log-XXXXXX)"
  mkdir -p "${cfg_dir}/.config/par"
  cat > "${cfg_dir}/.config/par/parbackup.conf" << 'EOF'
S3_ENDPOINT="http://localhost:19999"
S3_BUCKET="nonexistent"
S3_ACCESS_KEY="bogus"
S3_SECRET_KEY="bogus"
EOF

  # Run create (without --local so it attempts S3 upload)
  run env HOME="$cfg_dir" "$PARBACKUP" create -f "$TEST_DIR/Parbackupfile" 2>&1
  [ "$status" -ne 0 ]

  # Extract run log path
  local run_log
  run_log="$(echo "$output" | grep "Run log:" | sed 's/.*Run log: //')"
  [ -n "$run_log" ]
  [ -f "$run_log" ]

  # The run log must contain s3cmd stderr output tagged with [s3 upload]
  grep -q "\[s3 upload\]" "$run_log"

  # Cleanup
  rm -f "$run_log"
  rm -rf "$cfg_dir"
  rm -rf /tmp/parbackup/test_deployment-* 2> /dev/null || true
}

@test "s3 logging: upload stderr appears in alert email" {
  mailpit_clear

  # Create a config with SMTP + bogus S3 endpoint
  local cfg_dir
  cfg_dir="$(mktemp -d /tmp/parbackup-test-s3log-XXXXXX)"
  mkdir -p "${cfg_dir}/.config/par"
  cat > "${cfg_dir}/.config/par/parbackup.conf" << 'EOF'
S3_ENDPOINT="http://localhost:19999"
S3_BUCKET="nonexistent"
S3_ACCESS_KEY="bogus"
S3_SECRET_KEY="bogus"
EOF
  cat > "${cfg_dir}/.config/par/paralert.conf" << 'EOF'
ALERT_SMTP_HOST='localhost'
ALERT_SMTP_PORT='21025'
ALERT_SMTP_USER='backups@test.local'
ALERT_SMTP_PASSWORD='p@$$w0rd$FZ=x!'
ALERT_SMTP_FROM='backups@test.local'
ALERT_RECIPIENTS='admin@test.local'
EOF

  # Run create (without --local so it attempts S3 upload)
  run env HOME="$cfg_dir" "$PARBACKUP" create -f "$TEST_DIR/Parbackupfile" 2>&1
  [ "$status" -ne 0 ]

  sleep 1

  # Fetch the alert email body
  local body
  body="$(mailpit_latest_body)"

  # The email body must contain the run log, which must include s3cmd error output
  [[ "$body" == *"--- Run log ---"* ]]
  [[ "$body" == *"[s3 upload]"* ]]

  # Cleanup
  rm -rf "$cfg_dir"
  rm -rf /tmp/parbackup/test_deployment-* 2> /dev/null || true
}

@test "alert: error email includes run log content" {
  mailpit_clear

  local email_config_dir
  email_config_dir="$(mktemp -d /tmp/parbackup-test-email-XXXXXX)"
  mkdir -p "${email_config_dir}/.config/par"
  write_alert_config "$email_config_dir"

  local broken_backupfile
  broken_backupfile="$(mktemp /tmp/parbackup-test-broken-XXXXXX)"
  cat > "$broken_backupfile" << 'EOF'
BACKUP_NAME="runlog_email_test"
SERVICES="broken_db"
BROKEN_DB_TYPE="postgres"
BROKEN_DB_CONTAINER="parbackup-nonexistent-container"
BROKEN_DB_USER="testuser"
BROKEN_DB_PASSWORD="testpass"
BROKEN_DB_DB="testdb"
EOF

  run env HOME="$email_config_dir" "$PARBACKUP" create --local -f "$broken_backupfile" 2>&1
  [ "$status" -ne 0 ]

  sleep 1

  # Fetch email body
  local body
  body="$(mailpit_latest_body)"

  # Email body must contain the run log separator and actual log entries
  [[ "$body" == *"--- Run log ---"* ]]
  [[ "$body" == *"[INFO]"* ]]
  [[ "$body" == *"[ERROR]"* ]]
  [[ "$body" == *"runlog_email_test"* ]]

  # Cleanup
  rm -f "$broken_backupfile"
  rm -rf "$email_config_dir"
  # Extract and clean up run log
  local run_log
  run_log="$(echo "$output" | grep "Run log:" | sed 's/.*Run log: //')"
  rm -f "$run_log"
  rm -rf /tmp/parbackup/runlog_email_test-* 2> /dev/null || true
}
