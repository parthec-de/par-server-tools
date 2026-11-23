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

TEST_S3_ENDPOINT="http://localhost:29000"
TEST_S3_ACCESS_KEY="testaccess"
TEST_S3_SECRET_KEY="testsecret"
TEST_S3_BUCKET="parbackup-test"
TEST_S3_REGION="us-east-1"

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

mysql_query() {
  docker exec -e MYSQL_PWD=testpass parbackup-test-mysql \
    mysql -u testuser -D testdb -N -B -e "$1"
}

wait_for_dbs() {
  # 60 attempts: MySQL 8 cold-starts (data dir init + seed) can take a while.
  for i in $(seq 1 60); do
    if docker exec parbackup-test-postgres pg_isready -q 2> /dev/null \
      && docker exec parbackup-test-postgres-defaultdb pg_isready -q 2> /dev/null \
      && docker exec parbackup-test-mongo mongosh -u testuser -p testpass \
           --authenticationDatabase admin --quiet \
           --eval "db.getSiblingDB('testdb').products.countDocuments()" 2> /dev/null \
         | grep -q "3" \
      && docker exec -e MYSQL_PWD=testpass parbackup-test-mysql \
           mysql -u testuser -D testdb -N -B -e "SELECT count(*) FROM users;" 2> /dev/null \
         | grep -q "^3$"; then
      return 0
    fi
    sleep 1
  done
  return 1
}

wait_for_s3() {
  for i in $(seq 1 30); do
    if curl -sf "${TEST_S3_ENDPOINT}/health" > /dev/null 2>&1; then
      return 0
    fi
    sleep 1
  done
  return 1
}

setup_s3() {
  wait_for_s3

  # Create test bucket via s3cmd
  local host
  host="$(echo "$TEST_S3_ENDPOINT" | sed 's|https\?://||')"

  s3cmd \
    --access_key="$TEST_S3_ACCESS_KEY" \
    --secret_key="$TEST_S3_SECRET_KEY" \
    --host="$host" \
    --host-bucket="$host/%(bucket)" \
    --region="$TEST_S3_REGION" \
    --no-ssl \
    mb "s3://${TEST_S3_BUCKET}" 2> /dev/null || true

  # Write parbackup config pointing to the test S3 server
  export TEST_CONFIG_DIR
  TEST_CONFIG_DIR="$(mktemp -d /tmp/parbackup-test-config-XXXXXX)"
  mkdir -p "${TEST_CONFIG_DIR}/.config/par"
  cat > "${TEST_CONFIG_DIR}/.config/par/parbackup.conf" << EOF
S3_ENDPOINT="${TEST_S3_ENDPOINT}"
S3_BUCKET="${TEST_S3_BUCKET}"
S3_ACCESS_KEY="${TEST_S3_ACCESS_KEY}"
S3_SECRET_KEY="${TEST_S3_SECRET_KEY}"
S3_REGION="${TEST_S3_REGION}"
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
ALERT_SMTP_INSECURE='true'
ALERT_RECIPIENTS='admin@test.local'
CONF
}

seed_uploads() {
  docker exec parbackup-test-uploads sh -c "
    mkdir -p /app/public/uploads/images
    echo 'fake-image-data-1' > /app/public/uploads/images/logo.png
    echo 'fake-image-data-2' > /app/public/uploads/images/banner.jpg
    echo 'hello world' > /app/public/uploads/readme.txt
    chown -R 1000:82 /app/public/uploads/images
    chmod 660 /app/public/uploads/readme.txt
  "
}

# Write a Parbackupfile that backs up the seeded local dir under the given BACKUP_NAME.
# Usage: write_scoped_parbackupfile <path> <backup_name> [retention_days]
write_scoped_parbackupfile() {
  local path="$1"
  local name="$2"
  local retention="${3:-}"
  {
    echo "BACKUP_NAME=\"${name}\""
    [[ -n "$retention" ]] && echo "RETENTION_DAYS=\"${retention}\""
    echo 'SERVICES="static"'
    echo 'STATIC_TYPE="dir"'
    echo 'STATIC_PATH="/tmp/parbackup-test-localdir"'
  } > "$path"
}

s3_backup_count() {
  env HOME="$TEST_CONFIG_DIR" "$PARBACKUP" ls "$1/" 2> /dev/null | grep -c "^$1/" || true
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

  # restic staging and cache live outside /var/cache, the tests do not run as root
  export PARBACKUP_STAGING_ROOT
  PARBACKUP_STAGING_ROOT="$(mktemp -d /tmp/parbackup-test-staging-XXXXXX)"
  export RESTIC_CONFIG_DIR
  RESTIC_CONFIG_DIR="$(mktemp -d /tmp/parbackup-test-restic-XXXXXX)"
  export RESTIC_CACHE_DIR
  RESTIC_CACHE_DIR="$(mktemp -d /tmp/parbackup-test-restic-cache-XXXXXX)"
  export RESTIC_SECRET
  RESTIC_SECRET="${RESTIC_CONFIG_DIR}/restic-secret"

  # Host directory of the bind mount, created before compose so the container
  # keeps it owned by the test user
  export PARBACKUP_TEST_BIND
  PARBACKUP_TEST_BIND="$(mktemp -d /tmp/parbackup-test-bind-XXXXXX)"
  echo 'bind-data' > "${PARBACKUP_TEST_BIND}/hello.txt"
  chmod 640 "${PARBACKUP_TEST_BIND}/hello.txt"

  # Clean previous state
  docker compose -f "$COMPOSE_FILE" down -v --remove-orphans 2> /dev/null || true
  rm -rf /tmp/parbackup/test_deployment-* 2> /dev/null || true

  # Start stack
  docker compose -f "$COMPOSE_FILE" up -d
  wait_for_dbs
  setup_s3
  wait_for_mailpit
  seed_uploads
  seed_local_dir
  wait_for_cron

  setup_restic_config

  # Create local backup (--local to skip S3)
  BACKUP_OUTPUT="$(cd "$TEST_DIR" && env HOME="$ISOLATED_HOME" "$PARBACKUP" create --local 2>&1)"
  export BACKUP_ARCHIVE
  BACKUP_ARCHIVE="$(echo "$BACKUP_OUTPUT" | grep "Backup complete:" | sed 's/.*Backup complete: //')"
}

# Config for the restic backend, kept apart from the builtin test config.
setup_restic_config() {
  printf 'testsecret\n' > "$RESTIC_SECRET"
  chmod 600 "$RESTIC_SECRET"

  mkdir -p "${RESTIC_CONFIG_DIR}/.config/par"
  cat > "${RESTIC_CONFIG_DIR}/.config/par/parbackup.conf" << EOF
BACKUP_BACKEND="restic"
S3_ENDPOINT="${TEST_S3_ENDPOINT}"
S3_BUCKET="${TEST_S3_BUCKET}"
S3_ACCESS_KEY="${TEST_S3_ACCESS_KEY}"
S3_SECRET_KEY="${TEST_S3_SECRET_KEY}"
S3_REGION="${TEST_S3_REGION}"
RESTIC_SECRET_FILE="${RESTIC_SECRET}"
RESTIC_CACHE_DIR="${RESTIC_CACHE_DIR}"
RETENTION_DAYS="7"
EOF
}

teardown_file() {
  docker compose -f "$COMPOSE_FILE" down -v --remove-orphans 2> /dev/null || true
  rm -rf /tmp/parbackup/test_deployment-* 2> /dev/null || true
  rm -rf /tmp/parbackup/test_defaultdb-* 2> /dev/null || true
  rm -rf /tmp/parbackup/test_mysql-* 2> /dev/null || true
  rm -rf /tmp/parbackup/test_scope* 2> /dev/null || true
  rm -rf /tmp/parbackup/restore-* 2> /dev/null || true
  rm -rf /tmp/parbackup-test-localdir 2> /dev/null || true
  rm -rf "${PARBACKUP_TEST_BIND:-}" 2> /dev/null || true
  rm -rf "${TEST_CONFIG_DIR:-}" 2> /dev/null || true
  rm -rf "${ISOLATED_HOME:-}" 2> /dev/null || true
  rm -rf "${PARBACKUP_STAGING_ROOT:-}" 2> /dev/null || true
  rm -rf "${RESTIC_CONFIG_DIR:-}" 2> /dev/null || true
  rm -rf "${RESTIC_CACHE_DIR:-}" 2> /dev/null || true
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

@test "backup: archive contains app_uploads volume as tar stream with owners" {
  local tmpdir
  tmpdir="$(mktemp -d)"
  tar -xzf "$BACKUP_ARCHIVE" -C "$tmpdir"
  local volume_tar
  volume_tar="$(find "$tmpdir" -path "*/app_uploads/volume.tar")"
  [ -f "$volume_tar" ]

  local listing
  listing="$(tar -tvf "$volume_tar" --numeric-owner)"
  echo "$listing" | grep -qE '^-.* 1000/82 .*images/logo\.png$'
  echo "$listing" | grep -qE '^-rw-rw---- 0/0 .*readme\.txt$'
  rm -rf "$tmpdir"
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
  [[ "$output" == *"contains:"* ]]
  [[ "$output" == *"dumps: app_db (postgres), app_mongo (mongo)"* ]]
  [[ "$output" == *"volume: app_uploads"* ]]
  [[ "$output" == *"dir: app_static"* ]]

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

@test "restore: volume keeps owner and mode" {
  run docker exec parbackup-test-uploads \
    stat -c '%n %u:%g %a' /app/public/uploads/images/logo.png /app/public/uploads/readme.txt
  [ "$status" -eq 0 ]
  [[ "$output" == *"logo.png 1000:82 644"* ]]
  [[ "$output" == *"readme.txt 0:0 660"* ]]
}

@test "restore: archive without volume.tar restores plain volume files" {
  local tmpdir
  tmpdir="$(mktemp -d)"
  tar -xzf "$BACKUP_ARCHIVE" -C "$tmpdir"
  local name
  name="$(basename "$(find "$tmpdir" -mindepth 1 -maxdepth 1 -type d)")"
  local svc_dir="$tmpdir/$name/app_uploads"
  tar -xf "$svc_dir/volume.tar" -C "$svc_dir"
  rm "$svc_dir/volume.tar"
  local legacy_archive="/tmp/parbackup/${name}-legacy.tar.gz"
  tar -czf "$legacy_archive" -C "$tmpdir" "$name"

  docker exec parbackup-test-uploads sh -c "rm -rf /app/public/uploads/*"

  run env HOME="$ISOLATED_HOME" "$PARBACKUP" restore --local --force "$legacy_archive"
  [ "$status" -eq 0 ]
  [[ "$output" == *"No volume.tar found"* ]]
  run docker exec parbackup-test-uploads cat /app/public/uploads/readme.txt
  [[ "$output" == *"hello world"* ]]

  rm -rf "$tmpdir" "$legacy_archive"
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
# Test: MySQL backup/restore
#

@test "mysql seed: Alice, Bob, Charlie exist" {
  local result
  result="$(mysql_query "SELECT name FROM users ORDER BY id;")"
  [[ "$result" == *"Alice Mueller"* ]]
  [[ "$result" == *"Bob Schmidt"* ]]
  [[ "$result" == *"Charlie Weber"* ]]
}

@test "backup: mysql dump in archive contains seed data" {
  local backup_output archive
  backup_output="$(cd "$TEST_DIR" && env HOME="$ISOLATED_HOME" PARBACKUPFILE=Parbackupfile.mysql "$PARBACKUP" create --local 2>&1)"
  archive="$(echo "$backup_output" | grep "Backup complete:" | sed 's/.*Backup complete: //')"
  [ -f "$archive" ]

  local tmpdir dump_file
  tmpdir="$(mktemp -d)"
  tar -xzf "$archive" -C "$tmpdir"
  dump_file="$(find "$tmpdir" -path '*app_mysql/dump.sql')"
  [ -n "$dump_file" ]
  grep -q "Alice Mueller" "$dump_file"
  grep -q "Bob Schmidt" "$dump_file"

  rm -rf "$tmpdir" "$archive"
  rm -rf /tmp/parbackup/test_mysql-* 2> /dev/null || true
}

@test "restore: mysql round-trip preserves data" {
  local count
  count="$(mysql_query "SELECT count(*) FROM users;")"
  [ "$count" -eq 3 ]

  # Create backup using the mysql Parbackupfile
  local backup_output archive
  backup_output="$(cd "$TEST_DIR" && env HOME="$ISOLATED_HOME" PARBACKUPFILE=Parbackupfile.mysql "$PARBACKUP" create --local 2>&1)"
  archive="$(echo "$backup_output" | grep "Backup complete:" | sed 's/.*Backup complete: //')"
  [ -f "$archive" ]

  # Tamper with the data
  mysql_query "DELETE FROM users; INSERT INTO users (name, email) VALUES ('INTRUDER', 'hacked@evil.com');"
  local result
  result="$(mysql_query "SELECT name FROM users;")"
  [[ "$result" == *"INTRUDER"* ]]

  # Restore
  run env HOME="$ISOLATED_HOME" "$PARBACKUP" restore --local --force "$archive"
  [ "$status" -eq 0 ]
  [[ "$output" == *"Restore complete"* ]]

  # Verify original data is back
  local restored restored_count
  restored="$(mysql_query "SELECT name FROM users ORDER BY id;")"
  [[ "$restored" == *"Alice Mueller"* ]]
  [[ "$restored" == *"Bob Schmidt"* ]]
  [[ "$restored" == *"Charlie Weber"* ]]
  [[ "$restored" != *"INTRUDER"* ]]
  restored_count="$(mysql_query "SELECT count(*) FROM users;")"
  [ "$restored_count" -eq 3 ]

  rm -f "$archive"
  rm -rf /tmp/parbackup/test_mysql-* 2> /dev/null || true
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
# Test: S3 backend round-trip (via local RustFS)
#

@test "s3: create uploads backup to S3" {
  run env HOME="$TEST_CONFIG_DIR" bash -c "cd '$TEST_DIR' && '$PARBACKUP' create 2>&1"
  [ "$status" -eq 0 ]
  [[ "$output" == *"S3 upload complete"* ]]
  [[ "$output" == *"Backup complete:"* ]]

  # Extract s3 key from output for later tests
  export S3_BACKUP_ARCHIVE
  S3_BACKUP_ARCHIVE="$(echo "$output" | grep "Uploading to S3:" | sed 's/.*Uploading to S3: s3:\/\/[^/]*\///')"
  [ -n "$S3_BACKUP_ARCHIVE" ]

  # The local archive is removed after the upload
  [[ "$output" == *"Backup complete: s3://${TEST_S3_BUCKET}/${S3_BACKUP_ARCHIVE}"* ]]
  [ ! -f "/tmp/parbackup/$(basename "$S3_BACKUP_ARCHIVE")" ]
}

@test "s3: create --keep-local keeps the local archive" {
  run env HOME="$TEST_CONFIG_DIR" "$PARBACKUP" create --keep-local -f "$TEST_DIR/Parbackupfile" 2>&1
  [ "$status" -eq 0 ]
  [[ "$output" == *"S3 upload complete"* ]]
  [[ "$output" != *"Removed local archive"* ]]

  local archive
  archive="$(echo "$output" | grep "Backup complete:" | sed 's/.*Backup complete: //')"
  [ -f "$archive" ]
  rm -f "$archive"
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

@test "s3: restore stops when the download is cancelled" {
  local list_output
  list_output="$(env HOME="$TEST_CONFIG_DIR" "$PARBACKUP" ls test_deployment/ 2>&1)"
  local s3_key
  s3_key="$(echo "$list_output" | grep -o "test_deployment/test_deployment-[^ ]*" | head -1)"
  [ -n "$s3_key" ]

  local existing_file="/tmp/parbackup/$(basename "$s3_key")"
  echo "dummy" > "$existing_file"

  # setsid detaches from the terminal, so the "Overwrite?" prompt fails and counts as "no"
  run setsid -w env HOME="$TEST_CONFIG_DIR" "$PARBACKUP" restore "$s3_key" < /dev/null 2>&1
  [ "$status" -eq 0 ]
  [[ "$output" == *"Download cancelled"* ]]
  [[ "$output" != *"Extracting"* ]]
  [ "$(cat "$existing_file")" = "dummy" ]

  rm -f "$existing_file"
}

@test "s3: restore --pick stops when no backup is selected" {
  # setsid detaches from the terminal, so the picker returns no selection, like Ctrl+C
  run setsid -w env HOME="$TEST_CONFIG_DIR" "$PARBACKUP" restore --pick < /dev/null 2>&1
  [ "$status" -eq 0 ]
  [[ "$output" == *"No backup selected"* ]]
  [[ "$output" != *"Extracting"* ]]
}

@test "s3: download fails without backup_ref" {
  run env HOME="$TEST_CONFIG_DIR" "$PARBACKUP" download 2>&1
  [ "$status" -eq 1 ]
  [[ "$output" == *"Missing required argument"* ]]
}

@test "s3: restore round-trip from S3 preserves data" {
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

@test "cleanup: create only cleans up backups of its own BACKUP_NAME" {
  local daily="${BATS_TEST_TMPDIR}/Parbackupfile.daily"
  local other="${BATS_TEST_TMPDIR}/Parbackupfile.other"
  write_scoped_parbackupfile "$daily" "test_scope"
  write_scoped_parbackupfile "$other" "test_scope_assets"
  echo 'RETENTION_DAYS="7"' >> "${TEST_CONFIG_DIR}/.config/par/parbackup.conf"

  run env HOME="$TEST_CONFIG_DIR" "$PARBACKUP" create -f "$other" 2>&1
  [ "$status" -eq 0 ]
  [ "$(s3_backup_count test_scope_assets)" -eq 1 ]

  # 30 days ahead every existing backup is past the 7-day retention
  local future_now=$(($(date +%s) + 30 * 86400))
  run env HOME="$TEST_CONFIG_DIR" _NOW="$future_now" "$PARBACKUP" create -f "$daily" 2>&1
  [ "$status" -eq 0 ]
  [[ "$output" == *"Cleaning up backups of 'test_scope' older than 7 day(s)"* ]]
  [ "$(s3_backup_count test_scope_assets)" -eq 1 ]
}

@test "cleanup: RETENTION_DAYS=0 in the Parbackupfile keeps its backups" {
  local keep="${BATS_TEST_TMPDIR}/Parbackupfile.keep"
  write_scoped_parbackupfile "$keep" "test_scope_assets" "0"

  local future_now=$(($(date +%s) + 30 * 86400))
  run env HOME="$TEST_CONFIG_DIR" _NOW="$future_now" "$PARBACKUP" create -f "$keep" 2>&1
  [ "$status" -eq 0 ]
  [[ "$output" == *"Retention is disabled"* ]]
  [ "$(s3_backup_count test_scope_assets)" -eq 2 ]
}

@test "cleanup: -f uses the Parbackupfile RETENTION_DAYS and only its temp files" {
  local assets="${BATS_TEST_TMPDIR}/Parbackupfile.assets"
  local daily="${BATS_TEST_TMPDIR}/Parbackupfile.daily"
  write_scoped_parbackupfile "$assets" "test_scope_assets" "60"
  write_scoped_parbackupfile "$daily" "test_scope"
  run env HOME="$TEST_CONFIG_DIR" "$PARBACKUP" create -f "$daily" 2>&1
  [ "$status" -eq 0 ]
  [ "$(s3_backup_count test_scope)" -eq 1 ]

  local own_temp="/tmp/parbackup/test_scope_assets-2020-01-01_03-00-00.tar.gz"
  local foreign_temp="/tmp/parbackup/test_scope-2020-01-01_03-00-00.tar.gz"
  echo "old" > "$own_temp"
  echo "old" > "$foreign_temp"
  touch -d "90 days ago" "$own_temp" "$foreign_temp"

  # Within 60 days nothing is deleted, although the config says 7
  local in_30_days=$(($(date +%s) + 30 * 86400))
  run env HOME="$TEST_CONFIG_DIR" _NOW="$in_30_days" "$PARBACKUP" cleanup -f "$assets" 2>&1
  [ "$status" -eq 0 ]
  [ "$(s3_backup_count test_scope_assets)" -eq 2 ]

  local in_90_days=$(($(date +%s) + 90 * 86400))
  run env HOME="$TEST_CONFIG_DIR" _NOW="$in_90_days" "$PARBACKUP" cleanup -f "$assets" 2>&1
  [ "$status" -eq 0 ]
  [ "$(s3_backup_count test_scope_assets)" -eq 0 ]
  [ "$(s3_backup_count test_scope)" -eq 1 ]
  [ ! -f "$own_temp" ]
  [ -f "$foreign_temp" ]

  rm -f "$foreign_temp" /tmp/parbackup/test_scope-* /tmp/parbackup/test_scope_assets-*
}

@test "builtin: RETENTION_WEEKLY and RETENTION_MONTHLY warn and have no effect" {
  local backupfile="${BATS_TEST_TMPDIR}/Parbackupfile.builtin_weekly"
  cat > "$backupfile" << 'EOF'
BACKUP_NAME="test_builtin_weekly"
BACKUP_BACKEND="builtin"
RETENTION_DAYS="7"
RETENTION_WEEKLY="4"
RETENTION_MONTHLY="12"
SERVICES="static"
STATIC_TYPE="dir"
STATIC_PATH="/tmp/parbackup-test-localdir"
EOF

  run env HOME="$ISOLATED_HOME" "$PARBACKUP" create --local -f "$backupfile"
  [ "$status" -eq 0 ]
  [[ "$output" == *"RETENTION_WEEKLY has no effect with BACKUP_BACKEND=builtin"* ]]
  [[ "$output" == *"RETENTION_MONTHLY has no effect with BACKUP_BACKEND=builtin"* ]]

  # The calendar settings change nothing about the archive
  local archive
  archive="$(echo "$output" | grep "Backup complete:" | sed 's/.*Backup complete: //')"
  [ -f "$archive" ]
  tar -tzf "$archive" | grep -q "Parbackupfile"

  rm -f "$archive"
  rm -rf /tmp/parbackup/test_builtin_weekly-*
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
ALERT_SMTP_INSECURE='true'
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
ALERT_SMTP_INSECURE='true'
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

#
# Test: restic backend
#

require_restic() {
  if ! command -v restic > /dev/null; then
    skip "restic is not installed, run 'mise install'"
  fi
}

# Run parbackup with the restic test config.
restic_parbackup() {
  env HOME="$RESTIC_CONFIG_DIR" PARBACKUP_STAGING_ROOT="$PARBACKUP_STAGING_ROOT" "$PARBACKUP" "$@"
}

# Run restic itself against the repository of the given backup name.
restic_cli() {
  local name="$1"
  shift

  env \
    AWS_ACCESS_KEY_ID="$TEST_S3_ACCESS_KEY" \
    AWS_SECRET_ACCESS_KEY="$TEST_S3_SECRET_KEY" \
    AWS_DEFAULT_REGION="$TEST_S3_REGION" \
    RESTIC_REPOSITORY="s3:${TEST_S3_ENDPOINT}/${TEST_S3_BUCKET}/restic/${name}" \
    RESTIC_PASSWORD="$(cat "$RESTIC_SECRET")" \
    RESTIC_CACHE_DIR="$RESTIC_CACHE_DIR" \
    restic "$@"
}

restic_snapshot_count() {
  restic_parbackup ls --timestamps 2> /dev/null | grep -c "/" || true
}

restic_repo_size() {
  restic_cli "$1" stats --mode raw-data --json 2> /dev/null \
    | grep -o '"total_size":[0-9]*' | cut -d: -f2
}

# Oldest snapshot of a deployment, the one the download test restores.
oldest_snapshot_ref() {
  restic_parbackup ls --timestamps 2> /dev/null \
    | grep "$1/" | head -1 | cut -f2
}

# Newest snapshot of a deployment, the one a fresh create left behind.
newest_snapshot_ref() {
  restic_parbackup ls --timestamps 2> /dev/null \
    | grep "$1/" | tail -1 | cut -f2
}

write_restic_scope_parbackupfile() {
  local path="$1"
  local name="$2"
  local retention="${3:-1}"

  {
    echo "BACKUP_NAME=\"${name}\""
    echo "BACKUP_BACKEND=\"restic\""
    echo "RETENTION_DAYS=\"${retention}\""
    echo 'SERVICES="static"'
    echo 'STATIC_TYPE="dir"'
    echo 'STATIC_PATH="/tmp/parbackup-test-localdir"'
  } > "$path"
}

@test "restic: create stores dumps, volume data and the Parbackupfile in one snapshot" {
  require_restic

  run restic_parbackup create -f "$TEST_DIR/Parbackupfile"
  [ "$status" -eq 0 ]
  [[ "$output" == *"Backup complete: restic snapshot"* ]]
  [[ "$output" == *"Reading '/tmp/parbackup-test-localdir' in place"* ]]

  # An unprivileged run cannot read /var/lib/docker, it falls back to docker cp
  if [[ "$(id -u)" -ne 0 ]]; then
    [[ "$output" == *"'app_uploads' is not a volume mount, falling back to docker cp"* ]]
  fi

  local snapshot_ref snapshot_id
  snapshot_ref="$(oldest_snapshot_ref test_deployment)"
  [ -n "$snapshot_ref" ]
  snapshot_id="${snapshot_ref#*/}"

  local listing
  listing="$(restic_cli test_deployment ls "$snapshot_id" 2> /dev/null)"
  echo "$listing" | grep -q "${PARBACKUP_STAGING_ROOT}/test_deployment/Parbackupfile"
  echo "$listing" | grep -q "${PARBACKUP_STAGING_ROOT}/test_deployment/app_db/dump.sql"
  echo "$listing" | grep -q "${PARBACKUP_STAGING_ROOT}/test_deployment/app_mongo/dump.archive"
  echo "$listing" | grep -qE "(app_uploads/volume\.tar|parbackup-test_uploads/_data/images/logo\.png)"
  echo "$listing" | grep -q "/tmp/parbackup-test-localdir/css/style.css"
  echo "$listing" | grep -q "${PARBACKUP_STAGING_ROOT}/test_deployment/parbackup.manifest"
}

@test "restic: volume behind a bind mount is read in place and restored" {
  require_restic

  local backupfile="${BATS_TEST_TMPDIR}/Parbackupfile.restic_bind"
  cat > "$backupfile" << 'EOF'
BACKUP_NAME="test_restic_bind"
SERVICES="bind"
BIND_TYPE="volume"
BIND_CONTAINER="parbackup-test-uploads"
BIND_PATH="/app/public/uploads-bind"
EOF

  run restic_parbackup create -f "$backupfile"
  [ "$status" -eq 0 ]
  [[ "$output" == *"Reading '${PARBACKUP_TEST_BIND}' in place"* ]]

  local snapshot_id
  snapshot_id="$(restic_cli test_restic_bind snapshots --json 2> /dev/null | grep -o '"short_id":"[a-f0-9]*"' | head -1 | cut -d'"' -f4)"
  [ -n "$snapshot_id" ]

  local listing
  listing="$(restic_cli test_restic_bind ls "$snapshot_id" 2> /dev/null)"
  echo "$listing" | grep -q "${PARBACKUP_TEST_BIND}/hello.txt"
  echo "$listing" | grep -q "${PARBACKUP_STAGING_ROOT}/test_restic_bind/parbackup.manifest"

  rm -f "${PARBACKUP_TEST_BIND}/hello.txt"
  echo 'TAMPERED' > "${PARBACKUP_TEST_BIND}/evil.txt"

  run restic_parbackup restore --force "$(oldest_snapshot_ref test_restic_bind)"
  [ "$status" -eq 0 ]
  [[ "$output" == *"Restore complete"* ]]
  [[ "$output" == *"Copying 1 file(s)"* ]]
  [[ "$output" == *"volume: bind"* ]]

  run cat "${PARBACKUP_TEST_BIND}/hello.txt"
  [[ "$output" == *"bind-data"* ]]
  [ ! -f "${PARBACKUP_TEST_BIND}/evil.txt" ]

  run stat -c '%a' "${PARBACKUP_TEST_BIND}/hello.txt"
  [ "$output" = "640" ]
}

@test "restic: deduplication keeps unchanged data out of the repository" {
  require_restic

  # A large unchanged file makes the delta of the next snapshot measurable
  docker exec parbackup-test-uploads sh -c "dd if=/dev/urandom of=/app/public/uploads/big.bin bs=1M count=8 2> /dev/null"

  run restic_parbackup create -f "$TEST_DIR/Parbackupfile"
  [ "$status" -eq 0 ]

  local size_first
  size_first="$(restic_repo_size test_deployment)"
  [ -n "$size_first" ]

  run restic_parbackup create -f "$TEST_DIR/Parbackupfile"
  [ "$status" -eq 0 ]

  local size_second growth
  size_second="$(restic_repo_size test_deployment)"
  [ -n "$size_second" ]
  growth=$((size_second - size_first))
  growth="${growth#-}"

  # 8 MiB of unchanged data must not be stored twice
  [ "$growth" -lt 1000000 ]

  docker exec parbackup-test-uploads rm -f /app/public/uploads/big.bin
}

@test "restic: round-trip from the repository preserves data and file modes" {
  require_restic

  # Backup and restore in one test, like the builtin round-trip
  run restic_parbackup create -f "$TEST_DIR/Parbackupfile"
  [ "$status" -eq 0 ]

  local snapshot_ref
  snapshot_ref="$(newest_snapshot_ref test_deployment)"
  [ -n "$snapshot_ref" ]

  pg_query "DELETE FROM users; INSERT INTO users (name, email) VALUES ('RESTIC_INTRUDER', 'hacked@evil.com');" > /dev/null
  mongo_query "db.getSiblingDB('testdb').products.deleteMany({}); db.getSiblingDB('testdb').products.insertOne({name:'RESTIC_FAKE',price:0,stock:0});" > /dev/null
  docker exec parbackup-test-uploads sh -c "rm -rf /app/public/uploads/* && echo 'TAMPERED' > /app/public/uploads/evil.txt"
  rm -rf /tmp/parbackup-test-localdir/*
  echo 'TAMPERED' > /tmp/parbackup-test-localdir/evil.html

  run restic_parbackup restore --force "$snapshot_ref"
  [ "$status" -eq 0 ]
  [[ "$output" == *"Restore complete"* ]]
  [[ "$output" == *"contains:"*"dumps:"*"Restoring snapshot"* ]]
  [[ "$output" == *"volume: app_uploads"* ]]
  [[ "$output" == *"dir: app_static"* ]]

  local pg_result
  pg_result="$(pg_query "SELECT name FROM users ORDER BY id;")"
  [[ "$pg_result" == *"Alice Mueller"* ]]
  [[ "$pg_result" != *"RESTIC_INTRUDER"* ]]
  [ "$(pg_query "SELECT count(*) FROM users;")" -eq 3 ]

  local mongo_result
  mongo_result="$(mongo_query "db.getSiblingDB('testdb').products.find({},{name:1,_id:0}).sort({name:1}).toArray().map(d=>d.name).join('\n')")"
  [[ "$mongo_result" == *"Widget A"* ]]
  [[ "$mongo_result" != *"RESTIC_FAKE"* ]]

  local uploads_result
  uploads_result="$(docker exec parbackup-test-uploads ls -R /app/public/uploads/)"
  [[ "$uploads_result" == *"logo.png"* ]]
  [[ "$uploads_result" == *"readme.txt"* ]]
  [[ "$uploads_result" != *"evil.txt"* ]]

  [ -f "/tmp/parbackup-test-localdir/css/style.css" ]
  [ ! -f "/tmp/parbackup-test-localdir/evil.html" ]

  # Mode preservation across the snapshot is covered by the bind mount test
  run docker exec parbackup-test-uploads stat -c '%n' /app/public/uploads/readme.txt
  [ "$status" -eq 0 ]
  [[ "$output" == *"readme.txt"* ]]
}

@test "restic: ls lists snapshots as <backup_name>/<id>" {
  require_restic

  run restic_parbackup ls
  [ "$status" -eq 0 ]
  [[ "$output" == *"test_deployment/"* ]]

  run restic_parbackup ls test_deployment/
  [ "$status" -eq 0 ]
  [[ "$output" == *"test_deployment/"* ]]
  [[ "$output" != *"test_restic_scope/"* ]]

  local timestamps
  timestamps="$(restic_parbackup ls --timestamps 2> /dev/null | grep -E "test_deployment/[0-9a-f]+$" | head -1)"
  [ -n "$timestamps" ]
  [[ "$timestamps" =~ ^[0-9]+$'\t'test_deployment/[0-9a-f]+$ ]]
}

@test "restic: ls lists archives and snapshots together without repository internals" {
  require_restic

  local backupfile="${BATS_TEST_TMPDIR}/Parbackupfile.mixed_ls"
  cat > "$backupfile" << 'EOF'
BACKUP_NAME="test_mixed_ls"
RETENTION_DAYS="0"
SERVICES="static"
STATIC_TYPE="dir"
STATIC_PATH="/tmp/parbackup-test-localdir"
EOF

  run env HOME="$TEST_CONFIG_DIR" "$PARBACKUP" create -f "$backupfile"
  [ "$status" -eq 0 ]

  # The listing does not depend on the configured backend
  run restic_parbackup ls --timestamps
  [ "$status" -eq 0 ]
  [[ "$output" == *"test_mixed_ls/test_mixed_ls-"*".tar.gz"* ]]
  [[ "$output" == *"test_deployment/"* ]]

  # Repository objects never appear as backups
  [[ "$output" != *"restic/"* ]]
  [[ "$output" != *"/snapshots/"* ]]
  [[ "$output" != *"/data/"* ]]
}

@test "restic: the picker shows the backend of every backup" {
  require_restic

  local stub_dir gum_input
  stub_dir="${BATS_TEST_TMPDIR}/gum-stub"
  gum_input="${BATS_TEST_TMPDIR}/gum-input"
  mkdir -p "$stub_dir"

  # A stub replaces gum, so the picker can run without a terminal
  cat > "${stub_dir}/gum" << 'EOF'
#!/usr/bin/env bash
case "$1" in
  filter)
    cat > "${GUM_INPUT:?}"
    exit 1
    ;;
  log)
    echo "${@: -1}"
    ;;
esac
EOF
  chmod +x "${stub_dir}/gum"

  run env PATH="${stub_dir}:${PATH}" GUM_INPUT="$gum_input" HOME="$RESTIC_CONFIG_DIR" \
    "$PARBACKUP" download --pick
  [ "$status" -eq 0 ]
  [[ "$output" == *"No backup selected"* ]]

  local input
  input="$(cat "$gum_input")"
  [[ "$input" =~ test_mixed_ls/.*\.tar\.gz\ +builtin ]]
  [[ "$input" =~ test_deployment/[0-9a-f]+\ +restic ]]
}

@test "restic: download restores a snapshot into a directory" {
  require_restic

  local snapshot_ref target
  snapshot_ref="$(oldest_snapshot_ref test_deployment)"
  [ -n "$snapshot_ref" ]

  target="$(restic_parbackup download --force "$snapshot_ref" 2> /dev/null)"
  [ -n "$target" ]
  [ -d "$target" ]
  [ -f "${target}${PARBACKUP_STAGING_ROOT}/test_deployment/Parbackupfile" ]

  rm -rf "$target"
}

@test "restic: check and prune run against the repository" {
  require_restic

  # The test also runs on its own, so the repository has to exist first
  run restic_parbackup create -f "$TEST_DIR/Parbackupfile"
  [ "$status" -eq 0 ]

  run restic_parbackup restic check -f "$TEST_DIR/Parbackupfile"
  [ "$status" -eq 0 ]
  [[ "$output" == *"no errors were found"* ]]

  run restic_parbackup restic prune -f "$TEST_DIR/Parbackupfile" --dry-run
  [ "$status" -eq 0 ]
  [[ "$output" == *"unused size after prune"* ]]
}

@test "restic: retention forgets snapshots beyond keep-daily" {
  require_restic

  local scoped="${BATS_TEST_TMPDIR}/Parbackupfile.restic_scope"
  write_restic_scope_parbackupfile "$scoped" "test_restic_scope" "1"

  run restic_parbackup create -f "$scoped"
  [ "$status" -eq 0 ]
  run restic_parbackup create -f "$scoped"
  [ "$status" -eq 0 ]
  [[ "$output" == *"Forgetting snapshots beyond retention"* ]]

  run restic_parbackup ls --timestamps
  [ "$status" -eq 0 ]
  [ "$(echo "$output" | grep -c "test_restic_scope/")" -eq 1 ]

  run restic_parbackup cleanup -f "$scoped" --dry-run
  [ "$status" -eq 0 ]
}

@test "restic: --no-prune forgets without pruning" {
  require_restic

  local scoped="${BATS_TEST_TMPDIR}/Parbackupfile.restic_noprune"
  write_restic_scope_parbackupfile "$scoped" "test_restic_noprune" "1"

  run restic_parbackup create -f "$scoped"
  [ "$status" -eq 0 ]

  run restic_parbackup create -f "$scoped" --no-prune
  [ "$status" -eq 0 ]
  [[ "$output" == *"prune is disabled"* ]]
}

@test "restic: volume path outside a mount falls back to docker cp" {
  require_restic

  local backupfile="${BATS_TEST_TMPDIR}/Parbackupfile.restic_fallback"
  cat > "$backupfile" << 'EOF'
BACKUP_NAME="test_restic_fallback"
SERVICES="etc"
ETC_TYPE="volume"
ETC_CONTAINER="parbackup-test-uploads"
ETC_PATH="/etc"
EOF

  run restic_parbackup create -f "$backupfile"
  [ "$status" -eq 0 ]
  [[ "$output" == *"falling back to docker cp"* ]]

  local listing
  listing="$(restic_cli test_restic_fallback ls "$(restic_cli test_restic_fallback snapshots --json 2> /dev/null | grep -o '"short_id":"[a-f0-9]*"' | head -1 | cut -d'"' -f4)" 2> /dev/null)"
  echo "$listing" | grep -q "${PARBACKUP_STAGING_ROOT}/test_restic_fallback/etc/volume.tar"
}

@test "restic: missing secret file fails with a clear message" {
  require_restic

  local cfg_dir
  cfg_dir="$(mktemp -d /tmp/parbackup-test-restic-nosecret-XXXXXX)"
  mkdir -p "${cfg_dir}/.config/par"
  cat > "${cfg_dir}/.config/par/parbackup.conf" << EOF
BACKUP_BACKEND="restic"
S3_ENDPOINT="${TEST_S3_ENDPOINT}"
S3_BUCKET="${TEST_S3_BUCKET}"
S3_ACCESS_KEY="${TEST_S3_ACCESS_KEY}"
S3_SECRET_KEY="${TEST_S3_SECRET_KEY}"
S3_REGION="${TEST_S3_REGION}"
RESTIC_SECRET_FILE="${cfg_dir}/missing-secret"
RESTIC_CACHE_DIR="${RESTIC_CACHE_DIR}"
EOF

  run env HOME="$cfg_dir" PARBACKUP_STAGING_ROOT="$PARBACKUP_STAGING_ROOT" \
    "$PARBACKUP" create -f "$TEST_DIR/Parbackupfile"
  [ "$status" -ne 0 ]
  [[ "$output" == *"Missing restic secret file"* ]]

  rm -rf "$cfg_dir"
}

@test "restic: RESTIC_REPO_PREFIX moves the repositories inside the bucket" {
  require_restic

  local cfg_dir backupfile
  cfg_dir="$(mktemp -d /tmp/parbackup-test-restic-prefix-XXXXXX)"
  mkdir -p "${cfg_dir}/.config/par"
  cat > "${cfg_dir}/.config/par/parbackup.conf" << EOF
BACKUP_BACKEND="restic"
S3_ENDPOINT="${TEST_S3_ENDPOINT}"
S3_BUCKET="${TEST_S3_BUCKET}"
S3_ACCESS_KEY="${TEST_S3_ACCESS_KEY}"
S3_SECRET_KEY="${TEST_S3_SECRET_KEY}"
S3_REGION="${TEST_S3_REGION}"
RESTIC_REPO_PREFIX="custom-prefix"
RESTIC_SECRET_FILE="${RESTIC_SECRET}"
RESTIC_CACHE_DIR="${RESTIC_CACHE_DIR}"
RETENTION_DAYS="7"
EOF

  backupfile="${BATS_TEST_TMPDIR}/Parbackupfile.repo_prefix"
  cat > "$backupfile" << 'EOF'
BACKUP_NAME="test_repo_prefix"
SERVICES="static"
STATIC_TYPE="dir"
STATIC_PATH="/tmp/parbackup-test-localdir"
EOF

  run env HOME="$cfg_dir" PARBACKUP_STAGING_ROOT="$PARBACKUP_STAGING_ROOT" \
    "$PARBACKUP" create -f "$backupfile"
  [ "$status" -eq 0 ]
  [[ "$output" == *"s3:${TEST_S3_ENDPOINT}/${TEST_S3_BUCKET}/custom-prefix/test_repo_prefix"* ]]

  run env HOME="$cfg_dir" PARBACKUP_STAGING_ROOT="$PARBACKUP_STAGING_ROOT" "$PARBACKUP" ls
  [ "$status" -eq 0 ]
  [[ "$output" == *"test_repo_prefix/"* ]]

  rm -rf "$cfg_dir"
}

@test "restic: init refuses a Parbackupfile with the builtin backend" {
  require_restic

  local backupfile="${BATS_TEST_TMPDIR}/Parbackupfile.init_builtin"
  cat > "$backupfile" << 'EOF'
BACKUP_NAME="test_init_builtin"
BACKUP_BACKEND="builtin"
SERVICES="static"
STATIC_TYPE="dir"
STATIC_PATH="/tmp/parbackup-test-localdir"
EOF

  run restic_parbackup restic init -f "$backupfile"
  [ "$status" -eq 1 ]
  [[ "$output" == *"BACKUP_BACKEND is 'builtin', there is no restic repository to initialize"* ]]
}

@test "restic: prune and check skip a builtin Parbackupfile without a repository" {
  require_restic

  local backupfile="${BATS_TEST_TMPDIR}/Parbackupfile.prune_builtin"
  cat > "$backupfile" << 'EOF'
BACKUP_NAME="test_prune_builtin"
BACKUP_BACKEND="builtin"
SERVICES="static"
STATIC_TYPE="dir"
STATIC_PATH="/tmp/parbackup-test-localdir"
EOF

  run restic_parbackup restic prune -f "$backupfile" --dry-run
  [ "$status" -eq 0 ]
  [[ "$output" == *"Loading $backupfile"* ]]
  [[ "$output" == *"No restic repository at"* ]]
  [[ "$output" == *"test_prune_builtin"* ]]

  run restic_parbackup restic check -f "$backupfile"
  [ "$status" -eq 0 ]
  [[ "$output" == *"No restic repository at"* ]]
}

@test "restic: cleanup --backend builtin removes old archives" {
  require_restic

  local backupfile="${BATS_TEST_TMPDIR}/Parbackupfile.migration"
  cat > "$backupfile" << 'EOF'
BACKUP_NAME="test_migration"
RETENTION_DAYS="7"
SERVICES="static"
STATIC_TYPE="dir"
STATIC_PATH="/tmp/parbackup-test-localdir"
EOF

  # Upload with the builtin config, clean up with the restic config and --backend
  run env HOME="$TEST_CONFIG_DIR" "$PARBACKUP" create -f "$backupfile"
  [ "$status" -eq 0 ]
  [[ "$output" == *"S3 upload complete"* ]]

  local future_now
  future_now=$(($(date +%s) + 30 * 86400))

  run env HOME="$RESTIC_CONFIG_DIR" PARBACKUP_STAGING_ROOT="$PARBACKUP_STAGING_ROOT" _NOW="$future_now" \
    "$PARBACKUP" cleanup --backend builtin -f "$backupfile" --dry-run
  [ "$status" -eq 0 ]
  [[ "$output" == *"Would delete: test_migration/"* ]]

  run env HOME="$RESTIC_CONFIG_DIR" PARBACKUP_STAGING_ROOT="$PARBACKUP_STAGING_ROOT" _NOW="$future_now" \
    "$PARBACKUP" cleanup --backend builtin -f "$backupfile"
  [ "$status" -eq 0 ]
  [[ "$output" == *"Deleted 1 old remote backup"* ]]
}
