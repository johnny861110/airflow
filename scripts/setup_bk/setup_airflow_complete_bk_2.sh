#!/bin/bash
set -euo pipefail

# ====================================================
# Airflow 2.8.1 Production-ish Build Script (RHEL + systemd + Podman)
# Fixes included:
# - Postgres volume permissions (avoid chown airflow -> PG breaks)
# - SELinux label (:Z + restorecon)
# - Wait for Postgres ready (no blind sleep)
# - Constraint-based pip install
# - Robust airflow.cfg edits via `airflow config set` (not fragile sed)
# - Fix typo: airflow-worker@.service (not .servive)
# - DO NOT delete airflow-worker@.service before restarting
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

MOUNT_DB_DIR="$AIRFLOW_HOME/postgres_data"

AIRFLOW_VERSION="2.8.1"
PYTHON_VERSION="3.10.14"
PYTHON_MAJOR_MINOR="3.10"
CONSTRAINT_URL="https://raw.githubusercontent.com/apache/airflow/constraints-${AIRFLOW_VERSION}/constraints-${PYTHON_MAJOR_MINOR}.txt"

# Postgres container defaults (official image uses postgres user, commonly uid=999)
POSTGRES_UID="999"
POSTGRES_GID="999"

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

mkdir -p "$AIRFLOW_HOME" "$SYSTEMD_DIR" "$SCRIPTS_DIR" "$CONFIG_DIR" "$RUN_DIR" "$LOG_DIR"
# NOTE: 只 chown Airflow 相關目錄，避免把 postgres_data 也 chown 成 airflow
chown -R "$AIRFLOW_USER:$AIRFLOW_USER" "$AIRFLOW_HOME"
# 等下會把 postgres_data 再改回 PG uid

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

# 搬移 service 檔
mv "$AIRFLOW_HOME"/*.service "$SYSTEMD_DIR/" 2>/dev/null || true

# 修正 typo: airflow-worker@.service
if [ -f "$AIRFLOW_HOME/airflow-worker@.service" ]; then
  mv "$AIRFLOW_HOME/airflow-worker@.service" "$SYSTEMD_DIR/"
fi
# 若有人以前拼錯 servive，順便兼容搬一次
if [ -f "$AIRFLOW_HOME/airflow-worker@.servive" ]; then
  mv "$AIRFLOW_HOME/airflow-worker@.servive" "$SYSTEMD_DIR/airflow-worker@.service"
fi

mv "$AIRFLOW_HOME/init_db.sh" "$SCRIPTS_DIR/" 2>/dev/null || true
mv "$AIRFLOW_HOME/manage_airflow.sh" "$SCRIPTS_DIR/" 2>/dev/null || true

# 清理舊 DB 依賴 unit（你已改成 podman，不需要 airflow-postgres.service/airflow-redis.service）
rm -f "$SYSTEMD_DIR/airflow-postgres.service" "$SYSTEMD_DIR/airflow-redis.service"
rm -f /etc/systemd/system/airflow-postgres.service /etc/systemd/system/airflow-redis.service
systemctl daemon-reload

echo ">>> [5/9] 啟動資料庫容器 (Podman rootful + SELinux)..."
mkdir -p "$MOUNT_DB_DIR"

# ⚠️ 關鍵：postgres_data 必須讓容器內 postgres(uid=999) 可寫
chown -R "${POSTGRES_UID}:${POSTGRES_GID}" "$MOUNT_DB_DIR"
chmod 700 "$MOUNT_DB_DIR"

# SELinux context（RHEL 建議補）
restorecon -RFv "$MOUNT_DB_DIR" 2>/dev/null || true

# 停止舊容器（rootful）
podman rm -f airflow-postgres airflow-redis 2>/dev/null || true

echo "  - Starting Postgres (13.4-buster)..."
podman run -d --name airflow-postgres --replace \
  --restart always \
  -v "$MOUNT_DB_DIR":/var/lib/postgresql/data:Z \
  -p 5432:5432 \
  -e POSTGRES_USER=airflow \
  -e POSTGRES_PASSWORD=airflow \
  -e POSTGRES_DB=airflow \
  docker.io/library/postgres:13.4-buster

echo "  - Starting Redis (7.2-rc2-bullseye)..."
podman run -d --name airflow-redis --replace \
  --restart always \
  -p 6379:6379 \
  docker.io/library/redis:7.2-rc2-bullseye

echo "  - 等待 Postgres ready（最多 120 秒）..."
READY=0
for i in {1..60}; do
  if podman exec airflow-postgres pg_isready -U airflow -d airflow >/dev/null 2>&1; then
    READY=1
    break
  fi
  sleep 2
done
if [ "$READY" -ne 1 ]; then
  echo "錯誤: Postgres 在 120 秒內未 ready"
  podman logs --tail 200 airflow-postgres || true
  exit 1
fi
echo "  - Postgres ready."

echo ">>> [6/9] 建置 Python 虛擬環境 (Venv) + 安裝套件..."
# 複製 requirements
if [ -f "$AIRFLOW_HOME/requirement.txt" ]; then
  # already exists
  :
elif [ -f "requirement.txt" ]; then
  cp "requirement.txt" "$REQUIREMENTS_FILE"
elif [ -f "requirements.txt" ]; then
  cp "requirements.txt" "$REQUIREMENTS_FILE"
fi

# 只 chown airflow 需要的目錄（避免 postgres_data 被改壞）
chown -R "$AIRFLOW_USER:$AIRFLOW_USER" "$AIRFLOW_HOME"
chown -R "${POSTGRES_UID}:${POSTGRES_GID}" "$MOUNT_DB_DIR"
chmod 700 "$MOUNT_DB_DIR"

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

echo ">>> [7/9] 產生並設定 airflow.cfg（用 airflow config set）..."
runuser -u "$AIRFLOW_USER" -- bash -lc "
  set -euo pipefail
  source '$VENV_DIR/bin/activate'
  export AIRFLOW_HOME='$AIRFLOW_HOME'

  # 產生預設 cfg
  if [ ! -f '$CFG_FILE' ]; then
    airflow version >/dev/null
  fi

  # CeleryExecutor + DB/Redis 設定
  airflow config set core executor CeleryExecutor
  airflow config set database sql_alchemy_conn 'postgresql+psycopg2://airflow:airflow@localhost:5432/airflow'
  airflow config set celery broker_url 'redis://localhost:6379/0'
  airflow config set celery result_backend 'db+postgresql://airflow:airflow@localhost:5432/airflow'
  airflow config set core dags_folder '$AIRFLOW_HOME/dags'

  # 重要：避免你之前遇到的 FAB auth manager 缺 provider 導致 webserver 起不來
  airflow config unset core auth_manager || true
"
chown "$AIRFLOW_USER:$AIRFLOW_USER" "$CFG_FILE"

echo ">>> [8/9] 初始化資料庫..."
runuser -u "$AIRFLOW_USER" -- bash -lc "
  set -euo pipefail
  source '$VENV_DIR/bin/activate'
  export AIRFLOW_HOME='$AIRFLOW_HOME'

  airflow db migrate
  airflow users create \
    --username admin \
    --firstname Admin \
    --lastname User \
    --role Admin \
    --email admin@example.com \
    --password admin || true
"

echo ">>> [9/9] 安裝 systemd unit 並啟動 Airflow..."
# 移除不需要的 DB/Redis dependency 字串（保險）
for SVC_FILE in "$SYSTEMD_DIR"/*.service; do
  [ -f "$SVC_FILE" ] || continue
  sed -i 's/airflow-postgres.service//g' "$SVC_FILE"
  sed -i 's/airflow-redis.service//g' "$SVC_FILE"
  sed -i 's/postgresql.service//g' "$SVC_FILE"
  sed -i 's/redis.service//g' "$SVC_FILE"
done

# 修正 manage_airflow.sh（如存在）
MANAGE_SCRIPT="$SCRIPTS_DIR/manage_airflow.sh"
if [ -f "$MANAGE_SCRIPT" ]; then
  sed -i '/airflow-postgres.service/d' "$MANAGE_SCRIPT" || true
  sed -i '/airflow-redis.service/d' "$MANAGE_SCRIPT" || true
  chmod +x "$MANAGE_SCRIPT"
fi

# 安裝 service 檔
cp "$SYSTEMD_DIR"/*.service /etc/systemd/system/
systemctl daemon-reload

SERVICES=(airflow-scheduler airflow-webserver airflow-flower airflow-trigger)
for SVC in "${SERVICES[@]}"; do
  systemctl enable --now "$SVC"
done

# worker：不要刪 unit，直接 enable/start instance
if [ -f "/etc/systemd/system/airflow-worker@.service" ] || [ -f "$SYSTEMD_DIR/airflow-worker@.service" ]; then
  systemctl enable --now airflow-worker@1
fi

echo "=================================================="
echo "Airflow $AIRFLOW_VERSION 建置完成！"
echo "- Postgres volume: uid/gid=${POSTGRES_UID}:${POSTGRES_GID} + :Z + restorecon"
echo "- Pip: 使用 constraints 安裝避免 provider 衝突"
echo "- airflow config: 使用 airflow config set，並 unset core.auth_manager 避免 FAB 缺件"
echo "驗證："
echo "  systemctl status airflow-scheduler -l --no-pager"
echo "  podman exec airflow-postgres pg_isready -U airflow -d airflow"
echo "=================================================="

