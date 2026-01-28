#!/bin/bash
set -euo pipefail

# ====================================================
# Airflow 2.8.1 Production-ish Build Script (RHEL + systemd + Podman)
# Fixes included:
# - NEVER chown postgres_data to airflow (prevents pg_wal permission denied)
# - SELinux label (:Z + restorecon if available)
# - Auto-fix: "Skipping initialization" / missing DB by wiping volume once if needed
# - Wait for Postgres ready (no blind sleep)
# - Constraint-based pip install
# - Generate FULL airflow.cfg via Airflow CLI (not minimal template)
# - Keep "set-like" config lines by editing airflow.cfg (cfg_set) + de-dupe keys
# - Fix service name: airflow-triggerer (not airflow-trigger)
# ====================================================

AIRFLOW_HOME="/opt/airflow"
AIRFLOW_USER="airflow"
VENV_DIR="$AIRFLOW_HOME/venv"
REQUIREMENTS_FILE="$AIRFLOW_HOME/requirement.txt"
CFG_FILE="$AIRFLOW_HOME/airflow.cfg"
SYSTEMD_DIR="$AIRFLOW_HOME/systemd"
SCRIPTS_DIR="$AIRFLOW_HOME/scripts"
CONFIG_DIR="$AIRFLOW_HOME/config"
RUN_DIR="$AIRFLOW_HOME/run"
LOG_DIR="$AIRFLOW_HOME/logs"
DAGS_DIR="$AIRFLOW_HOME/dags"

MOUNT_DB_DIR="$AIRFLOW_HOME/postgres_data"

AIRFLOW_VERSION="2.8.1"
PYTHON_VERSION="3.10.14"
PYTHON_MAJOR_MINOR="3.10"
CONSTRAINT_URL="https://raw.githubusercontent.com/apache/airflow/constraints-${AIRFLOW_VERSION}/constraints-${PYTHON_MAJOR_MINOR}.txt"

# Postgres container defaults (official image often uses postgres uid/gid 999)
POSTGRES_UID="999"
POSTGRES_GID="999"

# --------------------------
# Helper: airflow.cfg handling (FULL config) + de-dupe + cfg_set
# --------------------------

# 移除任何 section 內重複 key（只保留第一次出現）=> 避免 DuplicateOptionError
dedupe_cfg_keys() {
  [ -f "$CFG_FILE" ] || return 0
  awk '
    BEGIN{sec=""; FS="="}
    /^\[/ {sec=$0; print; next}
    /^[[:space:]]*$/ {print; next}
    /^[[:space:]]*[#;]/ {print; next}
    {
      line=$0
      key=$1
      gsub(/^[ \t]+|[ \t]+$/, "", key)
      id=sec"::"key
      if (key=="") {print line; next}
      if (seen[id]++==0) print line
    }
  ' "$CFG_FILE" > "${CFG_FILE}.tmp" && mv "${CFG_FILE}.tmp" "$CFG_FILE"
}

# 生成「官方預設完整 airflow.cfg」：透過 airflow config list 觸發初始化
generate_full_cfg() {
  echo "  - 產生官方預設完整 airflow.cfg（Airflow CLI）..."
  runuser -u "$AIRFLOW_USER" -- bash -lc "
    set -euo pipefail
    source '$VENV_DIR/bin/activate'

    export AIRFLOW_HOME='$AIRFLOW_HOME'
    export AIRFLOW_CONFIG='$CFG_FILE'

    mkdir -p '$AIRFLOW_HOME'
    # 強制重新生成：避免舊檔殘留重複 key 直接把 airflow 弄死
    rm -f '$CFG_FILE'

    # 這個指令會初始化 Airflow 設定並通常寫出預設 airflow.cfg
    airflow config list >/dev/null
  "

  if [ ! -s "$CFG_FILE" ]; then
    echo "錯誤: 無法產生完整 airflow.cfg：$CFG_FILE"
    echo "請檢查："
    echo "  sudo -u $AIRFLOW_USER $VENV_DIR/bin/airflow config list"
    exit 1
  fi

  chown "$AIRFLOW_USER:$AIRFLOW_USER" "$CFG_FILE" || true
  chmod 600 "$CFG_FILE" || true

  # 清掉可能由外部原因造成的重複 key
  dedupe_cfg_keys
}

# set-like：在指定 section/key 寫值（保證不會重複 key）
cfg_set() {
  local section="$1"
  local key="$2"
  local value="$3"

  if [ ! -f "$CFG_FILE" ]; then
    echo "錯誤: 找不到 $CFG_FILE（請先 generate_full_cfg 產生完整檔）"
    return 1
  fi

  dedupe_cfg_keys

  # 確保 section 存在
  if ! grep -qE "^\[$section\]" "$CFG_FILE"; then
    printf "\n[%s]\n" "$section" >> "$CFG_FILE"
  fi

  # 如果 section 內已有 key → replace（只改 section 範圍內第一個）
  if awk -v sec="[$section]" -v k="$key" '
      $0==sec {in=1; next}
      /^\[/ {in=0}
      in && $0 ~ "^"k"[[:space:]]*=" {found=1}
      END{exit !found}
    ' "$CFG_FILE"; then
    awk -v sec="[$section]" -v k="$key" -v v="$value" '
      BEGIN{in=0; done=0}
      $0==sec {in=1; print; next}
      /^\[/ {in=0; print; next}
      in && !done && $0 ~ "^"k"[[:space:]]*=" {print k" = "v; done=1; next}
      {print}
    ' "$CFG_FILE" > "${CFG_FILE}.tmp" && mv "${CFG_FILE}.tmp" "$CFG_FILE"
  else
    # 否則 insert 在 section header 下方
    sed -i "/^\[$section\]/a ${key} = ${value}" "$CFG_FILE"
  fi

  dedupe_cfg_keys
}

echo ">>> [1/9] 檢查權限..."
if [ "${EUID}" -ne 0 ]; then
  echo "錯誤: 請使用 root (sudo) 執行此腳本"
  exit 1
fi

echo ">>> [2/9] 安裝系統依賴..."
dnf install -y \
  gcc make openssl-devel bzip2-devel libffi-devel zlib-devel xz-devel tar gzip wget git \
  podman \
  postgresql-devel libpq-devel \
  || echo "警告: 部分套件安裝失敗，嘗試繼續..."

echo ">>> 建立 airflow 使用者與目錄..."
if ! id "$AIRFLOW_USER" &>/dev/null; then
  useradd -m -d "$AIRFLOW_HOME" "$AIRFLOW_USER"
fi

# 只建立目錄，不做整棵 chown（避免把 postgres_data 一起改壞）
mkdir -p "$AIRFLOW_HOME" "$SYSTEMD_DIR" "$SCRIPTS_DIR" "$CONFIG_DIR" "$RUN_DIR" "$LOG_DIR" "$DAGS_DIR" "$MOUNT_DB_DIR"

# 只 chown airflow 需要的目錄（不包含 postgres_data）
chown -R "$AIRFLOW_USER:$AIRFLOW_USER" \
  "$SYSTEMD_DIR" "$SCRIPTS_DIR" "$CONFIG_DIR" "$RUN_DIR" "$LOG_DIR" "$DAGS_DIR" \
  || true

echo ">>> [3/9] 檢查並安裝 Python $PYTHON_VERSION..."
NEED_COMPILE=false
if command -v python3.10 &> /dev/null; then
  CURRENT_VER="$(python3.10 --version 2>&1 || true)"
  if [[ "$CURRENT_VER" == *"$PYTHON_VERSION"* ]]; then
    echo "  - 已安裝相符版本: $CURRENT_VER，跳過編譯。"
  else
    echo "  - 版本不符($CURRENT_VER)，準備編譯..."
    NEED_COMPILE=true
  fi
else
  echo "  - 未偵測到 python3.10，準備編譯..."
  NEED_COMPILE=true
fi

if [ "$NEED_COMPILE" = true ]; then
  mkdir -p /usr/local/src
  cd /usr/local/src
  if [ ! -f "Python-$PYTHON_VERSION.tgz" ]; then
    wget "https://www.python.org/ftp/python/$PYTHON_VERSION/Python-$PYTHON_VERSION.tgz"
  fi
  rm -rf "Python-$PYTHON_VERSION" 2>/dev/null || true
  tar -xf "Python-$PYTHON_VERSION.tgz"
  cd "Python-$PYTHON_VERSION"
  ./configure --enable-optimizations
  make -j"$(nproc)" altinstall
  echo "  - Python 編譯完成。"
fi

PYTHON_CMD="$(command -v python3.10 || echo "/usr/local/bin/python3.10")"
echo "  - Python command: $PYTHON_CMD"

echo ">>> [4/9] 整理檔案結構與搬移 service/scripts..."
mkdir -p "$SYSTEMD_DIR" "$SCRIPTS_DIR"

# 移動 .service
mv "$AIRFLOW_HOME"/*.service "$SYSTEMD_DIR/" 2>/dev/null || true

# 修正 typo
if [ -f "$AIRFLOW_HOME/airflow-worker@.service" ]; then
  mv "$AIRFLOW_HOME/airflow-worker@.service" "$SYSTEMD_DIR/"
fi
if [ -f "$AIRFLOW_HOME/airflow-worker@.servive" ]; then
  mv "$AIRFLOW_HOME/airflow-worker@.servive" "$SYSTEMD_DIR/airflow-worker@.service"
fi

# scripts
mv "$AIRFLOW_HOME/init_db.sh" "$SCRIPTS_DIR/" 2>/dev/null || true
mv "$AIRFLOW_HOME/manage_airflow.sh" "$SCRIPTS_DIR/" 2>/dev/null || true

# 清掉舊的 postgres/redis unit（如果你之前用 systemd 管過 container）
rm -f "$SYSTEMD_DIR/airflow-postgres.service" "$SYSTEMD_DIR/airflow-redis.service" || true
rm -f /etc/systemd/system/airflow-postgres.service /etc/systemd/system/airflow-redis.service || true
systemctl daemon-reload || true

# --------------------------
# [5/9] Postgres/Redis
# --------------------------
echo ">>> [5/9] 啟動資料庫容器 (Podman rootful + SELinux + auto-fix)..."

prepare_pg_dir() {
  # postgres_data 永遠歸 postgres uid/gid 管
  chown -R "${POSTGRES_UID}:${POSTGRES_GID}" "$MOUNT_DB_DIR"
  chmod 700 "$MOUNT_DB_DIR"

  # SELinux
  if command -v restorecon >/dev/null 2>&1; then
    restorecon -RFv "$MOUNT_DB_DIR" >/dev/null 2>&1 || true
  fi
}

start_postgres_container() {
  podman run -d --name airflow-postgres --replace \
    --restart always \
    -v "$MOUNT_DB_DIR":/var/lib/postgresql/data:Z \
    -p 5432:5432 \
    -e POSTGRES_USER=airflow \
    -e POSTGRES_PASSWORD=airflow \
    -e POSTGRES_DB=airflow \
    docker.io/library/postgres:13.4-buster \
    -c max_connections=300
}

wait_pg_ready() {
  local ready=0
  for i in {1..60}; do
    if podman exec airflow-postgres pg_isready -U airflow -d airflow >/dev/null 2>&1; then
      ready=1
      break
    fi
    sleep 2
  done
  echo "$ready"
}

fix_skipping_initialization_once() {
  echo "  - 偵測到 Skipping initialization / DB 缺失，進行一次性清空 postgres_data 並重建..."
  podman rm -f airflow-postgres 2>/dev/null || true
  rm -rf "$MOUNT_DB_DIR"
  mkdir -p "$MOUNT_DB_DIR"
  prepare_pg_dir
  start_postgres_container
}

# 清掉舊容器
podman rm -f airflow-postgres airflow-redis 2>/dev/null || true

prepare_pg_dir

echo "  - Starting Postgres (13.4-buster)..."
start_postgres_container

echo "  - Starting Redis..."
podman run -d --name airflow-redis --replace \
  --restart always \
  -p 6379:6379 \
  docker.io/library/redis:7.2-rc2-bullseye

echo "  - 等待 Postgres ready（最多 120 秒）..."
READY="$(wait_pg_ready)"

if [ "$READY" -ne 1 ]; then
  echo "  - Postgres 尚未 ready，檢查 logs..."
  if podman logs --tail 200 airflow-postgres 2>/dev/null | grep -qi "Skipping initialization"; then
    fix_skipping_initialization_once
    echo "  - 重建後再次等待 Postgres ready（最多 120 秒）..."
    READY="$(wait_pg_ready)"
  fi
fi

if [ "$READY" -ne 1 ]; then
  echo "錯誤: Postgres 在 120 秒內未 ready"
  podman logs --tail 200 airflow-postgres || true
  exit 1
fi

# 再次確認 airflow DB 真存在（避免 ready 但 DB 沒建起來）
DB_EXISTS="$(podman exec airflow-postgres psql -U airflow -d template1 -tAc "SELECT 1 FROM pg_database WHERE datname='airflow';" 2>/dev/null || true)"
if ! echo "$DB_EXISTS" | grep -q 1; then
  echo "  - Postgres ready 但 airflow DB 不存在，進行一次性重建..."
  fix_skipping_initialization_once
  READY="$(wait_pg_ready)"
  if [ "$READY" -ne 1 ]; then
    echo "錯誤: Postgres 重建後仍未 ready"
    podman logs --tail 200 airflow-postgres || true
    exit 1
  fi
  DB_EXISTS="$(podman exec airflow-postgres psql -U airflow -d template1 -tAc "SELECT 1 FROM pg_database WHERE datname='airflow';" 2>/dev/null || true)"
  if ! echo "$DB_EXISTS" | grep -q 1; then
    echo "錯誤: airflow DB 仍不存在，請檢查 Postgres logs"
    podman logs --tail 200 airflow-postgres || true
    exit 1
  fi
fi

echo "  - Postgres ready + airflow DB exists."

# --------------------------
# [6/9] venv + pip
# --------------------------
echo ">>> [6/9] 建置 Python 虛擬環境 (Venv) + 安裝套件..."

if [ -f "$AIRFLOW_HOME/requirement.txt" ]; then
  :
elif [ -f "$AIRFLOW_HOME/requirements.txt" ]; then
  cp "$AIRFLOW_HOME/requirements.txt" "$REQUIREMENTS_FILE"
elif [ -f "requirement.txt" ]; then
  cp "requirement.txt" "$REQUIREMENTS_FILE"
elif [ -f "requirements.txt" ]; then
  cp "requirements.txt" "$REQUIREMENTS_FILE"
fi

# ✅ 只 chown airflow 需要的目錄（絕對不碰 postgres_data）
chown -R "$AIRFLOW_USER:$AIRFLOW_USER" \
  "$SYSTEMD_DIR" "$SCRIPTS_DIR" "$CONFIG_DIR" "$RUN_DIR" "$LOG_DIR" "$DAGS_DIR" \
  || true

# 再保險一次：把 postgres_data 權限修回 postgres
prepare_pg_dir

runuser -u "$AIRFLOW_USER" -- bash -lc "
  set -euo pipefail
  cd '$AIRFLOW_HOME'

  rm -rf '$VENV_DIR' 2>/dev/null || true
  '$PYTHON_CMD' -m venv '$VENV_DIR'
  source '$VENV_DIR/bin/activate'
  pip install --upgrade pip

  echo '  - 使用約束文件: $CONSTRAINT_URL'
  if [ -f '$REQUIREMENTS_FILE' ]; then
    pip install -r '$REQUIREMENTS_FILE' --constraint '$CONSTRAINT_URL'
  else
    pip install 'apache-airflow[postgres,redis,celery]==$AIRFLOW_VERSION' --constraint '$CONSTRAINT_URL'
  fi
"

# --------------------------
# [7/9] airflow.cfg (FULL)
# --------------------------
echo ">>> [7/9] 產生並設定 airflow.cfg（使用 Airflow CLI 產生完整預設檔 + 保留 set 語意）..."

generate_full_cfg

# ↓↓↓ 保留你原本 set 的「內容與結構」
cfg_set core executor CeleryExecutor
cfg_set database sql_alchemy_conn 'postgresql+psycopg2://airflow:airflow@127.0.0.1:5432/airflow'
cfg_set celery broker_url 'redis://127.0.0.1:6379/0'
cfg_set celery result_backend 'db+postgresql://airflow:airflow@127.0.0.1:5432/airflow'
cfg_set core dags_folder "$AIRFLOW_HOME/dags"

chown "$AIRFLOW_USER:$AIRFLOW_USER" "$CFG_FILE" || true
chmod 600 "$CFG_FILE" || true

# --------------------------
# [8/9] init/migrate
# --------------------------
echo ">>> [8/9] 初始化資料庫..."
runuser -u "$AIRFLOW_USER" -- bash -lc "
  set -euo pipefail
  source '$VENV_DIR/bin/activate'
  export AIRFLOW_HOME='$AIRFLOW_HOME'
  export AIRFLOW_CONFIG='$CFG_FILE'

  airflow db migrate
  airflow users create \
    --username admin \
    --firstname Admin \
    --lastname User \
    --role Admin \
    --email admin@example.com \
    --password admin || true
"

# --------------------------
# [9/9] systemd
# --------------------------
echo ">>> [9/9] 安裝 systemd unit 並啟動 Airflow..."

for SVC_FILE in "$SYSTEMD_DIR"/*.service; do
  [ -f "$SVC_FILE" ] || continue
  sed -i 's/airflow-postgres.service//g' "$SVC_FILE" || true
  sed -i 's/airflow-redis.service//g' "$SVC_FILE" || true
  sed -i 's/postgresql.service//g' "$SVC_FILE" || true
  sed -i 's/redis.service//g' "$SVC_FILE" || true
done

MANAGE_SCRIPT="$SCRIPTS_DIR/manage_airflow.sh"
if [ -f "$MANAGE_SCRIPT" ]; then
  sed -i '/airflow-postgres.service/d' "$MANAGE_SCRIPT" || true
  sed -i '/airflow-redis.service/d' "$MANAGE_SCRIPT" || true
  chmod +x "$MANAGE_SCRIPT" || true
fi

cp "$SYSTEMD_DIR"/*.service /etc/systemd/system/ || true
systemctl daemon-reload

# ✅ 2.8.x 正式名稱是 airflow-triggerer
SERVICES=(airflow-scheduler airflow-webserver airflow-flower airflow-triggerer)
for SVC in "${SERVICES[@]}"; do
  systemctl enable --now "$SVC"
done

if [ -f "/etc/systemd/system/airflow-worker@.service" ] || [ -f "$SYSTEMD_DIR/airflow-worker@.service" ]; then
  systemctl enable --now airflow-worker@1
fi

echo "=================================================="
echo "Airflow $AIRFLOW_VERSION 建置完成！"
echo "- Postgres volume: uid/gid=${POSTGRES_UID}:${POSTGRES_GID} + :Z + restorecon(若存在)"
echo "- Auto-fix: 若出現 Skipping initialization / airflow DB 缺失，會清空 postgres_data 一次並重建"
echo "- airflow.cfg: 使用 Airflow CLI 產生『完整預設檔』後再覆寫必要設定"
echo "驗證："
echo "  ls -lh $CFG_FILE"
echo "  head -n 30 $CFG_FILE"
echo "  podman exec airflow-postgres psql -U airflow -d airflow -c \"\\dt\""
echo "  systemctl status airflow-scheduler -l --no-pager"
echo "=================================================="

