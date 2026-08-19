#!/usr/bin/env bash
set -Eeuo pipefail

# Agent two-file installer.
# Required files in the same directory: a completed .env and this install.sh.

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR"

ENV_FILE="$SCRIPT_DIR/.env"
COMPOSE_FILE="$SCRIPT_DIR/docker-compose.yml"
RUNTIME_DIR="$SCRIPT_DIR/.agent-runtime"
SCHEMA_FILE="$RUNTIME_DIR/init_db.sql"
DEFAULT_IMAGE_TAG="1.2.6"

log() {
  printf '\n[%s] %s\n' "$(date '+%H:%M:%S')" "$*"
}

fail() {
  printf '\nERROR: %s\n' "$*" >&2
  exit 1
}

on_error() {
  local exit_code=$?
  printf '\n安裝未完成（exit=%s）。最近容器狀態：\n' "$exit_code" >&2
  if command -v docker >/dev/null 2>&1 && docker compose version >/dev/null 2>&1; then
    docker compose --env-file "$ENV_FILE" -f "$COMPOSE_FILE" ps 2>/dev/null || true
  fi
  exit "$exit_code"
}
trap on_error ERR

env_value() {
  local key="$1" line value
  line="$(grep -m1 -E "^[[:space:]]*${key}=" "$ENV_FILE" 2>/dev/null || true)"
  value="${line#*=}"
  value="${value%$'\r'}"
  if [[ "$value" == \"*\" && "$value" == *\" ]]; then
    value="${value:1:${#value}-2}"
  elif [[ "$value" == \'*\' && "$value" == *\' ]]; then
    value="${value:1:${#value}-2}"
  fi
  printf '%s' "$value"
}

require_env() {
  local key="$1" value
  value="$(env_value "$key")"
  [ -n "$value" ] || fail ".env 缺少 ${key}"
  case "$value" in
    YOUR_*|CHANGE_ME*|change-me*|example*|請填寫*|請產生*)
      fail ".env 的 ${key} 仍是範例值"
      ;;
  esac
}

install_curl() {
  command -v curl >/dev/null 2>&1 && return
  log "安裝下載工具"
  if command -v apt-get >/dev/null 2>&1; then
    apt-get update
    apt-get install -y ca-certificates curl
  elif command -v dnf >/dev/null 2>&1; then
    dnf install -y ca-certificates curl
  elif command -v yum >/dev/null 2>&1; then
    yum install -y ca-certificates curl
  else
    fail "找不到 apt-get、dnf 或 yum，無法自動安裝 curl"
  fi
}

install_docker() {
  command -v docker >/dev/null 2>&1 && return
  [ "$(id -u)" -eq 0 ] || fail "自動安裝 Docker 需要 root 權限"
  install_curl
  log "安裝 Docker Engine 與 Compose"
  local installer
  installer="$(mktemp)"
  curl -fsSL https://get.docker.com -o "$installer"
  sh "$installer"
  rm -f "$installer"
}

ensure_docker_ready() {
  install_docker
  if ! docker info >/dev/null 2>&1 && command -v systemctl >/dev/null 2>&1; then
    systemctl enable --now docker
  fi
  docker info >/dev/null 2>&1 || fail "Docker daemon 尚未啟動"
  docker compose version >/dev/null 2>&1 || fail "缺少 Docker Compose v2 插件"
}

pull_images() {
  local pull_failed=0
  log "拉取代理映像 ${IMAGE_TAG}"
  docker pull "$APP_IMAGE" || pull_failed=1
  if [ "$pull_failed" -eq 0 ]; then
    docker pull "$ADMIN_IMAGE" || pull_failed=1
  fi
  [ "$pull_failed" -eq 0 ] && return

  [ -t 0 ] || fail "無法拉取私人映像，請先執行 docker login ghcr.io"
  printf '\nGHCR 映像需要登入。Token 只用於本次拉取，不會寫入 .env。\n'
  local ghcr_user ghcr_token temporary_docker_config
  read -rp "GitHub 使用者名稱 [iosvip8888]: " ghcr_user
  ghcr_user="${ghcr_user:-iosvip8888}"
  read -rsp "GitHub Package read token: " ghcr_token
  printf '\n'
  [ -n "$ghcr_token" ] || fail "未輸入 GitHub Token"
  temporary_docker_config="$(mktemp -d)"
  printf '%s' "$ghcr_token" \
    | DOCKER_CONFIG="$temporary_docker_config" docker login ghcr.io -u "$ghcr_user" --password-stdin
  ghcr_token=""
  DOCKER_CONFIG="$temporary_docker_config" docker pull "$APP_IMAGE"
  DOCKER_CONFIG="$temporary_docker_config" docker pull "$ADMIN_IMAGE"
  rm -rf "$temporary_docker_config"
}

extract_clean_schema() {
  log "準備乾淨的資料庫結構"
  mkdir -p "$RUNTIME_DIR"
  local container_id raw_schema
  raw_schema="$RUNTIME_DIR/init_db.raw.sql"
  container_id="$(docker create "$APP_IMAGE")"
  docker cp "${container_id}:/app/init_db.sql" "$raw_schema"
  docker rm "$container_id" >/dev/null

  # Keep table definitions only. Never copy development users, UDIDs,
  # purchases, apps or logs to a new agent database.
  awk '
    /^-- Dumping data for table / { skipping = 1; next }
    skipping && /^UNLOCK TABLES;/ { skipping = 0; next }
    !skipping { print }
  ' "$raw_schema" > "$SCHEMA_FILE"
  rm -f "$raw_schema"
  if grep -q '^INSERT INTO' "$SCHEMA_FILE"; then
    fail "資料庫初始化檔仍包含既有資料，已停止部署"
  fi
  grep -q 'CREATE TABLE `unlock_codes`' "$SCHEMA_FILE" || fail "映像中的資料庫結構不完整"
  # MySQL initializes as its own container user and must be able to read it.
  chmod 644 "$SCHEMA_FILE"
}

write_compose_file() {
  log "產生 Docker Compose 設定"
  cat > "$COMPOSE_FILE" <<'COMPOSE'
services:
  mysql:
    image: mysql:8.0
    container_name: agent_mysql
    restart: unless-stopped
    environment:
      MYSQL_ROOT_PASSWORD: "${MYSQL_ROOT_PASSWORD:?MYSQL_ROOT_PASSWORD is required}"
      MYSQL_DATABASE: "${DB_NAME:-agent_db}"
      MYSQL_USER: "${DB_USER:-agent_user}"
      MYSQL_PASSWORD: "${DB_PASSWORD:?DB_PASSWORD is required}"
    volumes:
      - ./mysql_data:/var/lib/mysql
      - ./.agent-runtime/init_db.sql:/docker-entrypoint-initdb.d/001-schema.sql:ro
    healthcheck:
      test: ["CMD-SHELL", "mysqladmin ping -h 127.0.0.1 -uroot -p$$MYSQL_ROOT_PASSWORD --silent"]
      interval: 10s
      timeout: 5s
      retries: 30
      start_period: 30s
    networks: [agent_network]

  redis:
    image: redis:7-alpine
    container_name: agent_redis
    restart: unless-stopped
    healthcheck:
      test: ["CMD", "redis-cli", "ping"]
      interval: 10s
      timeout: 3s
      retries: 20
    networks: [agent_network]

  app:
    image: "ghcr.io/iosvip8888/agent_app:${AGENT_DOCKER_TAG:-1.2.6}"
    container_name: agent_app
    env_file: [.env]
    environment:
      PYTHONUNBUFFERED: "1"
      AGENT_TOKEN_CACHE_PATH: /app/data/.agent_short_token
      REVOKE_FLAG_PATH: /tmp/license_revoked
      PRIVATE_CERT_DIR: /app/private_certs
      PUBLIC_BASE_URL: "${DOMAIN:?DOMAIN is required}/uploads"
      PLIST_PUBLIC_BASE_URL: "${DOMAIN:?DOMAIN is required}/plists"
    ports:
      - "${APP_PORT:-1235}:1234"
      - "${AGENT_API_PORT:-7879}:7879"
    volumes:
      - ./worker.log:/app/worker.log
      - ./data:/app/data
      - ./logs:/app/logs
      - ./private_certs:/app/private_certs
      - ./firmcert:/app/firmcert
      - ./signed:/app/signed
      - ./apps:/app/apps
      - ./inject_plugins:/app/inject_plugins
      - ./fenfa:/app/fenfa
      - ./plists:/app/plists
      - ./uploads:/app/uploads
    restart: unless-stopped
    depends_on:
      mysql:
        condition: service_healthy
      redis:
        condition: service_healthy
    networks: [agent_network]

  admin:
    image: "ghcr.io/iosvip8888/agent_admin:${AGENT_DOCKER_TAG:-1.2.6}"
    container_name: agent_admin
    env_file: [.env]
    environment:
      PUBLIC_BASE_URL: "${DOMAIN:?DOMAIN is required}/uploads"
      PLIST_PUBLIC_BASE_URL: "${DOMAIN:?DOMAIN is required}/plists"
    ports:
      - "${ADMIN_PORT:-8001}:8000"
    command:
      - gunicorn
      - --bind
      - 0.0.0.0:8000
      - --workers
      - "2"
      - --threads
      - "2"
      - --timeout
      - "120"
      - --access-logfile
      - "-"
      - --error-logfile
      - "-"
      - admin_agent:app
    volumes:
      - ./worker.log:/app/worker.log:ro
      - ./data:/app/data
      - ./logs:/app/logs
      - ./private_certs:/app/private_certs
      - ./firmcert:/app/firmcert
      - ./apps:/app/apps
      - ./inject_plugins:/app/inject_plugins
      - ./fenfa:/app/fenfa
      - ./tmp:/app/tmp
      - ./uploads:/app/uploads
    restart: unless-stopped
    depends_on:
      mysql:
        condition: service_healthy
      redis:
        condition: service_healthy
    healthcheck:
      test: ["CMD-SHELL", "curl -fsS http://127.0.0.1:8000/admin/login >/dev/null || exit 1"]
      interval: 20s
      timeout: 10s
      retries: 15
      start_period: 40s
    networks: [agent_network]

networks:
  agent_network:
    driver: bridge
COMPOSE
  chmod 600 "$COMPOSE_FILE"
}

prepare_directories() {
  log "建立持久化資料目錄"
  mkdir -p mysql_data data logs private_certs firmcert signed apps \
    inject_plugins fenfa plists uploads tmp
  touch worker.log

  local app_uid app_gid
  app_uid="$(docker run --rm --entrypoint id "$APP_IMAGE" -u)"
  app_gid="$(docker run --rm --entrypoint id "$APP_IMAGE" -g)"
  if [ "$(id -u)" -eq 0 ]; then
    chown -R "${app_uid}:${app_gid}" data logs private_certs firmcert signed \
      apps inject_plugins fenfa plists uploads tmp worker.log
  fi
  chmod 775 data logs private_certs firmcert signed apps inject_plugins \
    fenfa plists uploads tmp
  chmod 664 worker.log
}

wait_for_service() {
  local service="$1" expected="$2" attempts=60 status
  while [ "$attempts" -gt 0 ]; do
    status="$(docker inspect -f '{{if .State.Health}}{{.State.Health.Status}}{{else}}{{.State.Status}}{{end}}' "$service" 2>/dev/null || true)"
    [ "$status" = "$expected" ] && return
    [ "$status" = "unhealthy" ] && break
    attempts=$((attempts - 1))
    sleep 5
  done
  docker compose --env-file "$ENV_FILE" -f "$COMPOSE_FILE" logs --tail=100 "$service" || true
  fail "${service} 未能進入 ${expected} 狀態"
}

ensure_database_admin() {
  log "確認代理後台管理員"
  local admin_user admin_password admin_hash
  admin_user="$(env_value ADMIN_USERNAME)"
  admin_password="$(env_value ADMIN_PASSWORD)"
  [[ "$admin_user" =~ ^[A-Za-z0-9_.-]{1,50}$ ]] || fail "ADMIN_USERNAME 僅可使用英數字、點、底線及連字號"
  [ ${#admin_password} -ge 10 ] || fail "ADMIN_PASSWORD 至少需要 10 個字元"
  admin_hash="$(printf '%s' "$admin_password" | sha256sum | awk '{print $1}')"

  # Existing installations keep their current account and password.
  printf "INSERT INTO agent_admin (username,password_hash,role) SELECT '%s','%s','superadmin' WHERE NOT EXISTS (SELECT 1 FROM agent_admin);\n" \
    "$admin_user" "$admin_hash" \
    | docker compose --env-file "$ENV_FILE" -f "$COMPOSE_FILE" exec -T mysql \
        sh -lc 'MYSQL_PWD="$MYSQL_ROOT_PASSWORD" mysql -uroot "$MYSQL_DATABASE"'
}

base64_value() {
  printf '%s' "$1" | base64 | tr -d '\r\n'
}

ensure_system_defaults() {
  log "補齊代理網站必要預設設定"
  local official_url line_url telegram_url youtube_url intro_url
  local discord_webhook telegram_token telegram_chat
  official_url="$(env_value OFFICIAL_URL)"
  line_url="$(env_value LINE_URL)"
  telegram_url="$(env_value TELEGRAM_URL)"
  youtube_url="$(env_value YOUTUBE_URL)"
  intro_url="$(env_value INTRO_URL)"
  discord_webhook="$(env_value DISCORD_WEBHOOK_URL)"
  telegram_token="$(env_value TELEGRAM_TOKEN)"
  telegram_chat="$(env_value TELEGRAM_CHAT)"
  official_url="${official_url:-https://introduce.httopp12.xyz/}"
  line_url="${line_url:-https://lin.ee/rPonyjK}"
  telegram_url="${telegram_url:-https://t.me/ios_vip8888}"
  intro_url="${intro_url:-https://introduce.httopp12.xyz/}"

  # Values are encoded before entering SQL so URLs and special characters
  # cannot alter the statement. Existing non-empty settings are preserved.
  docker compose --env-file "$ENV_FILE" -f "$COMPOSE_FILE" exec -T mysql \
    sh -lc 'MYSQL_PWD="$MYSQL_ROOT_PASSWORD" mysql -uroot "$MYSQL_DATABASE"' <<SQL
INSERT INTO agent_config (config_key, config_value, description) VALUES
  ('OFFICIAL_URL', CONVERT(FROM_BASE64('$(base64_value "$official_url")') USING utf8mb4), 'Official website'),
  ('LINE_URL', CONVERT(FROM_BASE64('$(base64_value "$line_url")') USING utf8mb4), 'LINE'),
  ('TELEGRAM_URL', CONVERT(FROM_BASE64('$(base64_value "$telegram_url")') USING utf8mb4), 'Telegram'),
  ('YOUTUBE_URL', CONVERT(FROM_BASE64('$(base64_value "$youtube_url")') USING utf8mb4), 'YouTube'),
  ('INTRO_URL', CONVERT(FROM_BASE64('$(base64_value "$intro_url")') USING utf8mb4), 'Introduction'),
  ('DISCORD_WEBHOOK_URL', CONVERT(FROM_BASE64('$(base64_value "$discord_webhook")') USING utf8mb4), 'Discord webhook'),
  ('TELEGRAM_TOKEN', CONVERT(FROM_BASE64('$(base64_value "$telegram_token")') USING utf8mb4), 'Telegram Bot API token'),
  ('TELEGRAM_CHAT', CONVERT(FROM_BASE64('$(base64_value "$telegram_chat")') USING utf8mb4), 'Telegram channel ID')
ON DUPLICATE KEY UPDATE
  config_value = IF(agent_config.config_value IS NULL OR agent_config.config_value = '', VALUES(config_value), agent_config.config_value),
  description = VALUES(description);
SQL
}

[ -f "$ENV_FILE" ] || fail "請將填寫完成的 .env 放在 install.sh 同一個目錄"
chmod 600 "$ENV_FILE"

for required_name in LICENSE_KEY SECRET_KEY DOMAIN AGENT_CODE \
  MYSQL_ROOT_PASSWORD DB_PASSWORD ADMIN_USERNAME ADMIN_PASSWORD; do
  require_env "$required_name"
done

DOMAIN_VALUE="$(env_value DOMAIN)"
[[ "$DOMAIN_VALUE" =~ ^https://[A-Za-z0-9.-]+(:[0-9]+)?$ ]] \
  || fail "DOMAIN 必須是完整 HTTPS 網址且不要帶結尾斜線，例如 https://agent.example.com"
[[ "$DOMAIN_VALUE" != *".example.com"* ]] || fail "DOMAIN 仍是範例網域"

AGENT_CODE_VALUE="$(env_value AGENT_CODE)"
[[ "$AGENT_CODE_VALUE" =~ ^AG[A-Za-z0-9_-]+$ ]] || fail "AGENT_CODE 格式不正確"
[ ${#AGENT_CODE_VALUE} -le 32 ] || fail "AGENT_CODE 不可超過 32 個字元"
SECRET_KEY_VALUE="$(env_value SECRET_KEY)"
DB_PASSWORD_VALUE="$(env_value DB_PASSWORD)"
MYSQL_ROOT_PASSWORD_VALUE="$(env_value MYSQL_ROOT_PASSWORD)"
ADMIN_PASSWORD_VALUE="$(env_value ADMIN_PASSWORD)"
[ ${#SECRET_KEY_VALUE} -ge 32 ] || fail "SECRET_KEY 至少需要 32 個字元"
[ ${#DB_PASSWORD_VALUE} -ge 12 ] || fail "DB_PASSWORD 至少需要 12 個字元"
[ ${#MYSQL_ROOT_PASSWORD_VALUE} -ge 12 ] || fail "MYSQL_ROOT_PASSWORD 至少需要 12 個字元"
[ ${#ADMIN_PASSWORD_VALUE} -ge 10 ] || fail "ADMIN_PASSWORD 至少需要 10 個字元"

IMAGE_TAG="$(env_value AGENT_DOCKER_TAG)"
IMAGE_TAG="${IMAGE_TAG:-$DEFAULT_IMAGE_TAG}"
[[ "$IMAGE_TAG" =~ ^[A-Za-z0-9._-]+$ ]] || fail "AGENT_DOCKER_TAG 格式不正確"
APP_IMAGE="ghcr.io/iosvip8888/agent_app:${IMAGE_TAG}"
ADMIN_IMAGE="ghcr.io/iosvip8888/agent_admin:${IMAGE_TAG}"

ensure_docker_ready
pull_images
extract_clean_schema
write_compose_file
prepare_directories
docker compose --env-file "$ENV_FILE" -f "$COMPOSE_FILE" config --quiet

log "啟動代理服務"
docker compose --env-file "$ENV_FILE" -f "$COMPOSE_FILE" pull mysql redis
docker compose --env-file "$ENV_FILE" -f "$COMPOSE_FILE" up -d --remove-orphans

wait_for_service agent_mysql healthy
ensure_database_admin
ensure_system_defaults
wait_for_service agent_admin healthy
wait_for_service agent_app healthy

trap - ERR
log "部署完成"
docker compose --env-file "$ENV_FILE" -f "$COMPOSE_FILE" ps
APP_PORT_VALUE="$(env_value APP_PORT)"
ADMIN_PORT_VALUE="$(env_value ADMIN_PORT)"
printf '\n網站容器：http://127.0.0.1:%s\n' "${APP_PORT_VALUE:-1235}"
printf '管理後台：http://127.0.0.1:%s/admin/\n' "${ADMIN_PORT_VALUE:-8001}"
printf '請將 Nginx 主站反向代理到網站容器，/admin/ 反向代理到管理後台。\n'
printf '日後更新只需修改 AGENT_DOCKER_TAG，再重新執行 ./install.sh。\n'
