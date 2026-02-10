#!/bin/bash
set -euo pipefail

# ====================================================
# Step 3: Start Database & Redis Containers (Podman)
# - Manages Postgres volume permissions & SELinux
# - Starts Postgres and Redis containers
# - Waits for PG to be ready and auto-fixes "skipping init" issue
# ====================================================

# 取得腳本所在目錄的絕對路徑
SCRIPT_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" &> /dev/null && pwd )"

# 載入所有設定變數
source "$SCRIPT_DIR/config.env"

# --- Helper Functions (from original script) ---

# 準備 Postgres 資料目錄：設定正確的擁有者和權限
prepare_pg_dir() {
  echo "  - 準備 Postgres 資料目錄: $MOUNT_DB_DIR"
  # postgres_data 必須讓容器內 postgres(uid=999) 可寫
  chown -R "${POSTGRES_UID}:${POSTGRES_GID}" "$MOUNT_DB_DIR"
  chmod 700 "$MOUNT_DB_DIR"
  # 處理 SELinux context
  restorecon -RFv "$MOUNT_DB_DIR" 2>/dev/null || true
  echo "  - 目錄權限設定完成."
}

# 啟動 Postgres 容器
start_postgres_container() {
  echo "  - 執行 podman run postgres:13.4-buster..."
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

# 等待 Postgres 完全就緒
wait_pg_ready() {
  local ready=0
  echo "  - 等待 Postgres 接受連線 (最多 120 秒)..."
  for i in {1..60}; do
    # 使用 podman exec 檢查 DB 狀態
    if podman exec airflow-postgres pg_isready -U airflow -d airflow >/dev/null 2>&1; then
      ready=1
      echo "  - Postgres is ready!"
      break
    fi
    echo -n "."
    sleep 2
  done
  echo
  echo "$ready"
}

#當偵測到 "Skipping initialization" 時，執行一次性修復
fix_skipping_initialization_once() {
  echo "  - 警告: 偵測到 'Skipping initialization'，可能是因為 volume 不為空."
  echo "  - 執行一次性自動修復：刪除容器並清空 volume..."
  podman rm -f airflow-postgres 2>/dev/null || true
  # rm -rf "$MOUNT_DB_DIR"
  # mkdir -p "$MOUNT_DB_DIR"
  prepare_pg_dir
  start_postgres_container
}

# --- Main Logic ---

echo ">>> 清理舊的 DB/Redis 容器與 systemd 服務..."
# 確保舊的 rootful 容器被移除
podman rm -f airflow-postgres airflow-redis 2>/dev/null || true
# 從原腳本移過來：如果存在用 systemd 管理的 db 服務，一併移除，因為現在由 podman --restart always 管理
rm -f /etc/systemd/system/airflow-postgres.service /etc/systemd/system/airflow-redis.service
systemctl daemon-reload

echo ">>> 建立 Postgres 資料目錄..."
mkdir -p "$MOUNT_DB_DIR"
prepare_pg_dir

echo ">>> 啟動資料庫容器 (Podman)..."
echo "  - 啟動 Postgres (13.4-buster)..."
start_postgres_container

echo "  - 啟動 Redis (7.2-rc2-bullseye)..."
podman run -d --name airflow-redis --replace \
  --restart always \
  -p 6379:6379 \
  docker.io/library/redis:7.2-rc2-bullseye

# --- 等待並驗證 Postgres ---
READY="$(wait_pg_ready)"

# 如果在指定時間內未就緒，嘗試分析日誌並修復
if [ "$READY" -ne 1 ]; then
  echo "  - Postgres 未在時間內就緒，檢查日誌..."
  # 如果日誌中包含 "Skipping initialization"，觸發自動修復
  if podman logs --tail 200 airflow-postgres 2>/dev/null | grep -qi "Skipping initialization"; then
    fix_skipping_initialization_once
    echo "  - 重建後再次等待 Postgres..."
    READY="$(wait_pg_ready)"
  fi
fi

# 在所有嘗試後，做最後的確認
if [ "$READY" -ne 1 ]; then
  echo "錯誤: Postgres 在自動修復後仍然未就緒。請手動檢查容器日誌:"
  podman logs --tail 200 airflow-postgres || true
  exit 1
fi

# 額外驗證：確保 'airflow' 資料庫確實存在
if ! podman exec airflow-postgres psql -U airflow -d template1 -tAc "SELECT 1 FROM pg_database WHERE datname='airflow';" | grep -q 1; then
  echo "錯誤: Postgres 服務已啟動，但 'airflow' 資料庫不存在。請檢查容器日誌."
  podman logs --tail 200 airflow-postgres || true
  exit 1
fi

echo "  - Postgres 已就緒且 'airflow' 資料庫存在."
echo "✅ 資料庫與 Redis 容器已成功啟動."
