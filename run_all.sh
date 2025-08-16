#!/usr/bin/env bash
set -euo pipefail

# ===== FLAGS =====
FORCE_CONFIG=0
AUTO=0
SKIP_VENV=0
while [[ $# -gt 0 ]]; do
  case "$1" in
    --force-config) FORCE_CONFIG=1; shift ;;
    --auto)         AUTO=1;         shift ;;
    --skip-venv)    SKIP_VENV=1;    shift ;;
    *) echo "Unknown flag: $1"; exit 1 ;;
  esac
done

# ===== SETTINGS =====
REPO_NAME="PROG8850-Group3-DB-Automation"
SIG_NOZ_DIR="monitoring/signoz"
MYSQL_HOST="127.0.0.1"
MYSQL_PORT="3307"
MYSQL_USER="root"
MYSQL_PASS="Secret5555"
MYSQL_DB="project_db"

# ===== UTIL =====
say()  { echo -e "\033[1;32m$*\033[0m"; }
warn() { echo -e "\033[1;33m$*\033[0m"; }
die()  { echo -e "\033[1;31m$*\033[0m"; exit 1; }

wait_mysql_ready() {
  say "=== [*] Waiting for MySQL readiness ==="
  for i in {1..90}; do
    if mysqladmin --host="$MYSQL_HOST" --port="$MYSQL_PORT" --user="$MYSQL_USER" --password="$MYSQL_PASS" --protocol=TCP ping --silent; then
      echo "MySQL ready."
      return 0
    fi
    echo "…waiting ($i)"; sleep 2
  done
  die "MySQL did not become ready in time."
}

# ===== SCAFFOLD (create missing files so script works from scratch) =====
ensure_dirs_and_files() {
  say "[BOOT] Ensuring folder structure & base files…"
  mkdir -p sql scripts .secrets .github/workflows monitoring/{mysql,otel}

  # docker-compose for MySQL (mount logging config)
  if [[ $FORCE_CONFIG -eq 1 || ! -f monitoring/mysql/docker-compose.mysql.yaml ]]; then
    cat > monitoring/mysql/docker-compose.mysql.yaml <<'YAML'
services:
  automated-mysql-server:
    image: mysql:8.0
    container_name: automated-mysql-server
    restart: unless-stopped
    environment:
      MYSQL_ROOT_PASSWORD: Secret5555
      MYSQL_DATABASE: project_db
    ports:
      - "3307:3306"
    command: >
      --general_log=1
      --general_log_file=/var/lib/mysql/mysql-general.log
      --log_error_verbosity=3
      --slow_query_log=1
      --slow_query_log_file=/var/lib/mysql/mysql-slow.log
      --long_query_time=0.2
      --log_queries_not_using_indexes=1
    volumes:
      - dbdata:/var/lib/mysql
      - ./monitoring/mysql/my.cnf:/etc/mysql/conf.d/zz-logging.cnf:ro
volumes:
  dbdata:
YAML
    say "[CFG] Wrote monitoring/mysql/docker-compose.mysql.yaml"
  fi

  # MySQL client conf for local CLI & Python
  if [[ $FORCE_CONFIG -eq 1 || ! -f .secrets/mysql.cnf ]]; then
    cat > .secrets/mysql.cnf <<EOF
[client]
host=${MYSQL_HOST}
user=${MYSQL_USER}
password=${MYSQL_PASS}
port=${MYSQL_PORT}

[mysql]
database=${MYSQL_DB}
EOF
    chmod 600 .secrets/mysql.cnf
    say "[CFG] Wrote .secrets/mysql.cnf"
  fi

  # SQL: Create table as spec
  if [[ $FORCE_CONFIG -eq 1 || ! -f sql/01_create_climatedata.sql ]]; then
    cat > sql/01_create_climatedata.sql <<'SQL'
CREATE DATABASE IF NOT EXISTS project_db;

CREATE TABLE IF NOT EXISTS project_db.ClimateData (
  record_id INT PRIMARY KEY AUTO_INCREMENT,
  location VARCHAR(100) NOT NULL,
  record_date DATE NOT NULL,
  temperature FLOAT NOT NULL,
  precipitation FLOAT NOT NULL
) ENGINE=InnoDB;
SQL
    say "[CFG] Wrote sql/01_create_climatedata.sql"
  fi

  # SQL: Add humidity column (NOT NULL)
  if [[ $FORCE_CONFIG -eq 1 || ! -f sql/02_add_humidity.sql ]]; then
    cat > sql/02_add_humidity.sql <<'SQL'
ALTER TABLE project_db.ClimateData
  ADD COLUMN IF NOT EXISTS humidity FLOAT NOT NULL DEFAULT 50.0;
SQL
    say "[CFG] Wrote sql/02_add_humidity.sql"
  fi

  # SQL: Seed data
  if [[ $FORCE_CONFIG -eq 1 || ! -f sql/03_seed_data.sql ]]; then
    cat > sql/03_seed_data.sql <<'SQL'
INSERT INTO project_db.ClimateData (location, record_date, temperature, precipitation, humidity) VALUES
('Toronto',   '2025-07-01', 22.5,  5.0, 60.0),
('Toronto',   '2025-07-02', 24.1,  2.2, 58.0),
('Ottawa',    '2025-07-01', 21.0,  1.5, 55.0),
('Ottawa',    '2025-07-03', 27.3,  0.0, 52.0),
('Montreal',  '2025-07-02', 26.8,  3.1, 65.0),
('Montreal',  '2025-07-04', 28.2,  1.0, 62.0),
('Vancouver', '2025-07-01', 19.4,  7.8, 72.0),
('Vancouver', '2025-07-02', 20.2, 10.1, 75.0),
('Calgary',   '2025-07-01', 23.0,  0.0, 48.0),
('Calgary',   '2025-07-02', 25.7,  0.3, 46.0),
('Toronto',   '2025-07-05', 29.1,  0.0, 54.0),
('Ottawa',    '2025-07-05', 30.2,  0.0, 49.0),
('Montreal',  '2025-07-05', 31.4,  0.0, 51.0),
('Vancouver', '2025-07-05', 22.0,  2.0, 69.0),
('Calgary',   '2025-07-05', 27.5,  0.0, 44.0);
SQL
    say "[CFG] Wrote sql/03_seed_data.sql"
  fi

  # SQL: Validation bundle
  if [[ $FORCE_CONFIG -eq 1 || ! -f sql/99_validate.sql ]]; then
    cat > sql/99_validate.sql <<'SQL'
SELECT '== SHOW CREATE TABLE ==' AS info;
SHOW CREATE TABLE project_db.ClimateData;

SELECT '== HUMIDITY COLUMN ==' AS info;
SHOW COLUMNS FROM project_db.ClimateData LIKE 'humidity';

SELECT '== TOTAL ROWS ==' AS info;
SELECT COUNT(*) AS total_rows FROM project_db.ClimateData;

SELECT '== SAMPLE HOT ROWS (temp>20) ==' AS info;
SELECT location, record_date, temperature, humidity
FROM project_db.ClimateData
WHERE temperature > 20
ORDER BY record_date DESC
LIMIT 10;
SQL
    say "[CFG] Wrote sql/99_validate.sql"
  fi

  # Python script: concurrent queries
  if [[ $FORCE_CONFIG -eq 1 || ! -f scripts/multi_thread_queries.py ]]; then
    cat > scripts/multi_thread_queries.py <<'PY'
import argparse, configparser, random, threading, time
from datetime import date, timedelta
import mysql.connector

def load_config(path):
    cfg = configparser.ConfigParser()
    cfg.read(path)
    c = cfg["client"]
    return {
        "host": c.get("host", "127.0.0.1"),
        "user": c.get("user", "root"),
        "password": c.get("password", ""),
        "port": c.getint("port", 3307),
        "database": cfg.get("mysql","database",fallback="project_db"),
    }

def get_conn(params):
    return mysql.connector.connect(
        host=params["host"],
        user=params["user"],
        password=params["password"],
        port=params["port"],
        database=params["database"],
        autocommit=True,
        connection_timeout=10,
    )

LOCATIONS = ["Toronto","Ottawa","Montreal","Vancouver","Calgary"]

ins_count = 0
sel_count = 0
upd_count = 0
lock = threading.Lock()

def insert_worker(params, n=50):
    global ins_count
    conn = get_conn(params); cur = conn.cursor()
    start = date.today() - timedelta(days=30)
    for _ in range(n):
        loc = random.choice(LOCATIONS)
        d = start + timedelta(days=random.randint(0,30))
        temp = round(random.uniform(10, 35), 1)
        precip = round(random.uniform(0, 15), 1)
        hum = round(random.uniform(35, 85), 1)
        cur.execute(
            "INSERT INTO ClimateData (location, record_date, temperature, precipitation, humidity) VALUES (%s,%s,%s,%s,%s)",
            (loc, d, temp, precip, hum),
        )
        with lock: ins_count += 1
    cur.close(); conn.close()

def select_worker(params, n=80):
    global sel_count
    conn = get_conn(params); cur = conn.cursor(dictionary=True)
    for _ in range(n):
        cur.execute("SELECT record_id FROM ClimateData WHERE temperature > 20 ORDER BY record_date DESC LIMIT 50")
        _ = cur.fetchall()
        with lock: sel_count += 1
        time.sleep(0.02)
    cur.close(); conn.close()

def update_worker(params, n=60):
    global upd_count
    conn = get_conn(params); cur = conn.cursor()
    for _ in range(n):
        loc = random.choice(LOCATIONS)
        cur.execute("UPDATE ClimateData SET humidity = LEAST(100, humidity + 2.5) WHERE location = %s", (loc,))
        with lock: upd_count += cur.rowcount if cur.rowcount > 0 else 1
        time.sleep(0.02)
    cur.close(); conn.close()

if __name__ == "__main__":
    ap = argparse.ArgumentParser()
    ap.add_argument("--config", default=".secrets/mysql.cnf")
    args = ap.parse_args()

    params = load_config(args.config)

    # Warm-up
    conn = get_conn(params); cur = conn.cursor()
    cur.execute("SELECT 1 FROM ClimateData LIMIT 1")
    list(cur)
    cur.close(); conn.close()

    threads = []
    for _ in range(3): threads.append(threading.Thread(target=insert_worker, args=(params,)))
    for _ in range(3): threads.append(threading.Thread(target=select_worker, args=(params,)))
    for _ in range(3): threads.append(threading.Thread(target=update_worker, args=(params,)))

    [t.start() for t in threads]
    [t.join() for t in threads]

    print({"inserts": ins_count, "selects": sel_count, "updates": upd_count})
PY
    say "[CFG] Wrote scripts/multi_thread_queries.py"
  fi
}

# ===== LOGGING CONFIG =====
ensure_mysql_logging_files() {
  mkdir -p monitoring/mysql
  if [[ $FORCE_CONFIG -eq 1 || ! -f monitoring/mysql/my.cnf ]]; then
    cat > monitoring/mysql/my.cnf <<'EOF'
[mysqld]
log_output=FILE
general_log=1
general_log_file=/var/lib/mysql/mysql-general.log
slow_query_log=1
slow_query_log_file=/var/lib/mysql/mysql-slow.log
long_query_time=0.2
log_queries_not_using_indexes=1
EOF
    say "[CFG] Wrote monitoring/mysql/my.cnf"
    # if container is up, restart to apply mounted conf, then re-wait
    if docker ps --format '{{.Names}}' | grep -q '^automated-mysql-server$'; then
      docker compose -f monitoring/mysql/docker-compose.mysql.yaml restart automated-mysql-server || true
      wait_mysql_ready
    fi
  else
    warn "[CFG] Using existing monitoring/mysql/my.cnf (no overwrite)."
  fi
}

ensure_mysql_logging_runtime() {
  say "[LOG] Applying runtime MySQL logging switches…"
  mysql --defaults-extra-file=.secrets/mysql.cnf --protocol=TCP -e "
    SET GLOBAL log_output='FILE';
    SET GLOBAL general_log=ON;
    SET GLOBAL general_log_file='/var/lib/mysql/mysql-general.log';
    SET GLOBAL slow_query_log=ON;
    SET GLOBAL slow_query_log_file='/var/lib/mysql/mysql-slow.log';
    SET GLOBAL long_query_time=0.2;
    SET GLOBAL log_queries_not_using_indexes=ON;
    FLUSH LOGS;
  " || warn "[LOG] Runtime logging tweaks failed (OK if already set)."
}

# ===== SIGNOZ HELPERS =====
detect_signoz_network() {
  docker network ls --format '{{.Name}}' | grep -i signoz | head -n1 || true
}

start_signoz() {
  say "=== [S1] Starting SigNoz backend ==="
  if [[ ! -d "$SIG_NOZ_DIR" ]]; then
    mkdir -p monitoring
    command -v git >/dev/null 2>&1 || { sudo apt-get update && sudo apt-get install -y git; }
    git clone https://github.com/SigNoz/signoz.git "$SIG_NOZ_DIR"
  fi
  pushd "$SIG_NOZ_DIR/deploy/docker" >/dev/null
  docker compose up -d
  popd >/dev/null
  say "SigNoz UI: port 3301 (Codespaces may port-forward it)."
}

start_mysql_log_collector() {
  say "=== [S2] Starting OTEL collector (MySQL logs -> SigNoz) ==="
  # ensure config exists
  mkdir -p monitoring/otel
  if [[ $FORCE_CONFIG -eq 1 || ! -f monitoring/otel/otel-collector-config.yaml ]]; then
    cat > monitoring/otel/otel-collector-config.yaml <<'EOF'
receivers:
  filelog:
    include:
      - /var/lib/mysql/mysql-general.log
      - /var/lib/mysql/mysql-slow.log
    start_at: beginning

processors:
  resource:
    attributes:
      - key: service.name
        action: upsert
        value: automated-mysql-server
  batch:

exporters:
  otlp:
    endpoint: signoz-otel-collector:4317
    tls:
      insecure: true
  logging:
    verbosity: detailed

service:
  pipelines:
    logs:
      receivers: [filelog]
      processors: [resource, batch]
      exporters: [logging, otlp]
EOF
  fi

  local VOL
  VOL=$(docker inspect -f '{{range .Mounts}}{{if eq .Destination "/var/lib/mysql"}}{{.Name}}{{end}}{{end}}' automated-mysql-server || true)
  [[ -z "$VOL" ]] && die "Cannot find MySQL volume. Is the DB container up?"

  local NET
  NET=$(detect_signoz_network)
  [[ -z "$NET" ]] && die "Cannot detect SigNoz docker network. Start SigNoz first."
  say "[INFO] Using SigNoz network: $NET"

  docker exec -it automated-mysql-server sh -lc 'chmod 644 /var/lib/mysql/mysql-*.log || true' >/dev/null 2>&1 || true

  docker rm -f otelcol-mysql-logs >/dev/null 2>&1 || true
  docker run -d --name otelcol-mysql-logs \
    --user 0:0 \
    --network "$NET" \
    -v "$VOL":/var/lib/mysql:ro \
    -v "$(pwd)/monitoring/otel/otel-collector-config.yaml":/etc/otelcol/config.yaml:ro \
    --restart unless-stopped \
    otel/opentelemetry-collector-contrib:0.108.0 \
    --config=/etc/otelcol/config.yaml

  say "[OK] MySQL logs collector started. Tail: docker logs --tail=80 otelcol-mysql-logs"
}

start_docker_metrics_collector() {
  say "=== [S3] Starting OTEL collector (Docker metrics -> SigNoz) ==="
  mkdir -p monitoring/otel
  if [[ $FORCE_CONFIG -eq 1 || ! -f monitoring/otel/docker-metrics-collector.yaml ]]; then
    cat > monitoring/otel/docker-metrics-collector.yaml <<'EOF'
receivers:
  docker_stats:
    endpoint: unix:///var/run/docker.sock
    collection_interval: 10s

processors:
  batch:

exporters:
  otlp:
    endpoint: signoz-otel-collector:4317
    tls:
      insecure: true

service:
  pipelines:
    metrics:
      receivers: [docker_stats]
      processors: [batch]
      exporters: [otlp]
EOF
  fi

  local NET
  NET=$(detect_signoz_network)
  [[ -z "$NET" ]] && die "Cannot detect SigNoz docker network. Start SigNoz first."
  say "[INFO] Using SigNoz network: $NET"

  docker rm -f otelcol-docker-metrics >/dev/null 2>&1 || true
  docker run -d --name otelcol-docker-metrics \
    --user 0:0 \
    --network "$NET" \
    -v /var/run/docker.sock:/var/run/docker.sock \
    -v "$(pwd)/monitoring/otel/docker-metrics-collector.yaml":/etc/otelcol/config.yaml:ro \
    --restart unless-stopped \
    otel/opentelemetry-collector-contrib:0.108.0 \
    --config=/etc/otelcol/config.yaml

  say "[OK] Docker metrics collector started. Tail: docker logs --tail=80 otelcol-docker-metrics"
}

ask_or_auto() {
  local prompt=$1 fn=$2
  if [[ $AUTO -eq 1 ]]; then
    $fn
  else
    read -p "$prompt (y/n): " ans
    [[ "$ans" =~ ^[Yy]$ ]] && $fn || say "Skipped."
  fi
}

# ===== MAIN =====
say "=== [1] Repo root ==="
if [[ ! -d "/workspaces/$REPO_NAME" ]]; then
  warn "Expected Codespaces path /workspaces/$REPO_NAME not found. Using current dir: $(pwd)"
else
  cd "/workspaces/$REPO_NAME"
fi

ensure_dirs_and_files

if [[ $SKIP_VENV -eq 1 ]]; then
  say "=== [2] Skipping venv recreation (flag --skip-venv) ==="
else
  say "=== [2] Python venv ==="
  deactivate 2>/dev/null || true
  rm -rf .venv
  python3 -m venv .venv
  source .venv/bin/activate
  python -m pip install --upgrade pip setuptools wheel
  python - <<'PY'
import sys, subprocess
subprocess.check_call([sys.executable,"-m","pip","install","mysql-connector-python==9.0.0"])
PY
fi

say "=== [3] MySQL client ==="
command -v mysql >/dev/null 2>&1 || { sudo apt-get update && sudo apt-get install -y mysql-client; }

say "=== [4] MySQL container ==="
docker compose -f monitoring/mysql/docker-compose.mysql.yaml up -d

say "=== [5] Wait for MySQL ==="
wait_mysql_ready

say "=== [6] Ensure logging ==="
ensure_mysql_logging_files
ensure_mysql_logging_runtime

say "=== [7] Schema & seed ==="
# Always ensure DB & base table exist
mysql --defaults-extra-file=.secrets/mysql.cnf --protocol=TCP < sql/01_create_climatedata.sql

# Add humidity only if missing (idempotent)
HAS_HUM=$(mysql --defaults-extra-file=.secrets/mysql.cnf --protocol=TCP -N -e \
  "SELECT COUNT(*) FROM INFORMATION_SCHEMA.COLUMNS
   WHERE TABLE_SCHEMA='project_db'
     AND TABLE_NAME='ClimateData'
     AND COLUMN_NAME='humidity';")
if [[ "$HAS_HUM" -eq 0 ]]; then
  mysql --defaults-extra-file=.secrets/mysql.cnf --protocol=TCP < sql/02_add_humidity.sql
else
  echo "[SKIP] 'humidity' already exists."
fi

# Seed data (safe to rerun; duplicates are OK for this project spec)
mysql --defaults-extra-file=.secrets/mysql.cnf --protocol=TCP < sql/03_seed_data.sql

say "=== [8] Workload (concurrent queries) ==="
python scripts/multi_thread_queries.py --config .secrets/mysql.cnf

say "=== [9] Validate ==="
mysql --defaults-extra-file=.secrets/mysql.cnf --protocol=TCP < sql/99_validate.sql

# Optional: SigNoz + collectors
ask_or_auto "Start SigNoz backend locally now?" start_signoz
ask_or_auto "Start OTEL collector to ship MySQL logs to SigNoz?" start_mysql_log_collector
ask_or_auto "Start OTEL collector to ship Docker metrics to SigNoz?" start_docker_metrics_collector

say "=== DONE ==="

