#!/bin/bash
set -euo pipefail

# ====================================================
# Step 6: Setup and start systemd services
# - Organizes service files
# - Removes container dependencies from service files
# - Copies, enables, and starts services
# ====================================================

# 取得腳本所在目錄的絕對路徑
SCRIPT_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" &> /dev/null && pwd )"

# 載入所有設定變數
source "$SCRIPT_DIR/config.env"

# --- Pre-flight Checks ---
if [ ! -d "$SYSTEMD_DIR" ]; then
  echo "錯誤: Systemd 目錄 '$SYSTEMD_DIR' 不存在。請先執行 01_prepare_system.sh。"
  exit 1
fi

echo ">>> 整理並設定 systemd service 檔案..."

# --- 1. 整理檔案 (從原腳本 step 4 移來) ---
echo "  - 將 .service 和 .sh 檔案移動到指定目錄..."
# 將 airflow home 下的 .service 檔案移到 systemd 子目錄
mv "$AIRFLOW_HOME"/*.service "$SYSTEMD_DIR/" 2>/dev/null || true

# 修正原腳本中可能存在的 typo (servive -> service)
if [ -f "$AIRFLOW_HOME/airflow-worker@.servive" ]; then
  echo "  - 偵測到 airflow-worker@.servive 錯字，自動修正..."
  mv "$AIRFLOW_HOME/airflow-worker@.servive" "$SYSTEMD_DIR/airflow-worker@.service"
fi
if [ -f "$AIRFLOW_HOME/airflow-worker@.service" ]; then
  mv "$AIRFLOW_HOME/airflow-worker@.service" "$SYSTEMD_DIR/"
fi

# 移動管理腳本
mv "$AIRFLOW_HOME/init_db.sh" "$SCRIPTS_DIR/" 2>/dev/null || true
mv "$AIRFLOW_HOME/manage_airflow.sh" "$SCRIPTS_DIR/" 2>/dev/null || true

# --- 2. 清理 Service 檔案中的容器依賴 ---
echo "  - 移除 service 檔案中對 DB/Redis 服務的依賴..."
for SVC_FILE in "$SYSTEMD_DIR"/*.service; do
  [ -f "$SVC_FILE" ] || continue
  # 因為 DB/Redis 現在由 Podman 的 restart policy 管理，所以從 systemd 依賴中移除
  sed -i -e 's/airflow-postgres.service//g' \
         -e 's/airflow-redis.service//g' \
         -e 's/postgresql.service//g' \
         -e 's/redis.service//g' "$SVC_FILE"
done

MANAGE_SCRIPT="$SCRIPTS_DIR/manage_airflow.sh"
if [ -f "$MANAGE_SCRIPT" ]; then
  echo "  - 移除 manage_airflow.sh 中對 DB/Redis 服務的依賴..."
  sed -i -e '/airflow-postgres.service/d' -e '/airflow-redis.service/d' "$MANAGE_SCRIPT" || true
  chmod +x "$MANAGE_SCRIPT"
fi

# --- 3. 安裝並啟動服務 ---
echo "  - 將 service 檔案複製到 /etc/systemd/system/..."
cp "$SYSTEMD_DIR"/*.service /etc/systemd/system/

echo "  - 重新載入 systemd..."
systemctl daemon-reload

SERVICES=(airflow-scheduler airflow-scheduler-2 airflow-webserver airflow-flower airflow-trigger)
echo "  - 啟用並啟動 Airflow 核心服務: ${SERVICES[*]}"
for SVC in "${SERVICES[@]}"; do
  # 檢查 service file 是否真的存在
  if [ -f "/etc/systemd/system/$SVC.service" ]; then
    systemctl enable --now "$SVC"
  else
    echo "  - 警告: $SVC.service 不存在，跳過。"
  fi
done

if [ -f "/etc/systemd/system/airflow-worker@.service" ]; then
  WORKER_COUNT=4
  echo "  - 啟用並啟動 $WORKER_COUNT 個 airflow-worker 服務 (airflow-worker@1..$WORKER_COUNT)..."
  for i in $(seq 1 $WORKER_COUNT); do
    systemctl enable --now "airflow-worker@$i"
  done
fi

echo "✅ systemd 服務已設定並啟動。"
