#!/bin/bash
set -e

# ====================================================
# Airflow 環境重構與部署腳本 v3
# 功能: 檔案結構整理 + Podman 純容器化 DB + Systemd Airflow
# ====================================================

AIRFLOW_HOME="/opt/airflow"
AIRFLOW_USER="airflow"
VENV_DIR="$AIRFLOW_HOME/venv"
SYSTEMD_DIR="$AIRFLOW_HOME/systemd"
SCRIPTS_DIR="$AIRFLOW_HOME/scripts"
CONFIG_DIR="$AIRFLOW_HOME/config"

echo ">>> [1/6] 檢查權限..."
if [ "$EUID" -ne 0 ]; then 
  echo "請使用 root 權限執行此腳本 (sudo $0)"
  exit 1
fi

echo ">>> [2/6] 整理專案結構 (Organize Repo)..."
# 建立目錄
mkdir -p "$SYSTEMD_DIR" "$SCRIPTS_DIR" "$CONFIG_DIR"

# 移動並修復 Service 檔案
echo "  - 移動 Systemd 服務檔..."
mv "$AIRFLOW_HOME"/*.service "$SYSTEMD_DIR/" 2>/dev/null || true
# 修復拼字錯誤 .servive -> .service
if [ -f "$AIRFLOW_HOME/airflow-worker@.servive" ]; then
    mv "$AIRFLOW_HOME/airflow-worker@.servive" "$SYSTEMD_DIR/airflow-worker@.service"
    echo "  - 修復 airflow-worker@.servive 檔名"
fi
# 確保 airflow-worker@.service 在 systemd 內 (如果原本就是正確的)
mv "$AIRFLOW_HOME/airflow-worker@.service" "$SYSTEMD_DIR/" 2>/dev/null || true

# 移動腳本
echo "  - 移動 Shell 腳本..."
mv "$AIRFLOW_HOME/init_db.sh" "$SCRIPTS_DIR/" 2>/dev/null || true
mv "$AIRFLOW_HOME/manage_airflow.sh" "$SCRIPTS_DIR/" 2>/dev/null || true

# 清理舊備份 (可選)
rm -f "$AIRFLOW_HOME/airflow.cfg.bak_v2" "$AIRFLOW_HOME/requirement_bk.txt"

# 修正權限
chown -R $AIRFLOW_USER:$AIRFLOW_USER "$AIRFLOW_HOME"

echo ">>> [3/6] 修改 Service 設定 (移除 DB 服務依賴)..."
# 因資料庫改為純 Podman 管理，Systemd 不再需要 After/Wants 資料庫服務
SERVICES_TO_FIX=$(ls "$SYSTEMD_DIR"/*.service)

for ADJ_FILE in $SERVICES_TO_FIX; do
    echo "  - 修正 $ADJ_FILE..."
    # 移除 airflow-postgres.service, airflow-redis.service, postgresql.service, redis.service
    sed -i 's/airflow-postgres.service//g' "$ADJ_FILE"
    sed -i 's/airflow-redis.service//g' "$ADJ_FILE"
    sed -i 's/postgresql.service//g' "$ADJ_FILE"
    sed -i 's/redis.service//g' "$ADJ_FILE"
    
    # 清理可能多出的空格
    sed -i 's/After=network.target  /After=network.target /g' "$ADJ_FILE"
    sed -i 's/Wants=  /Wants=/g' "$ADJ_FILE"
done

echo ">>> [4/6] 修正管理腳本 scripts/manage_airflow.sh..."
MANAGE_SCRIPT="$SCRIPTS_DIR/manage_airflow.sh"
if [ -f "$MANAGE_SCRIPT" ]; then
    # 移除 postgres 和 redis 的 systemd 操作
    sed -i '/airflow-postgres.service/d' "$MANAGE_SCRIPT"
    sed -i '/airflow-redis.service/d' "$MANAGE_SCRIPT"
    echo "  - 已更新 manage_airflow.sh 移除 DB 服務控制"
fi

echo ">>> [5/6] 啟動/重啟 Podman 資料庫 (Managed by Podman)..."
# 移除 Systemd 的舊 DB 服務 (如果存在)
systemctl stop airflow-postgres airflow-redis 2>/dev/null || true
systemctl disable airflow-postgres airflow-redis 2>/dev/null || true
rm -f /etc/systemd/system/airflow-postgres.service /etc/systemd/system/airflow-redis.service

# 啟動 Postgres (加入 --restart always)
echo "  - Starting Postgres..."
podman run -d --name airflow-postgres --replace \
    --restart always \
    -p 5432:5432 \
    -e POSTGRES_USER=airflow \
    -e POSTGRES_PASSWORD=airflow \
    -e POSTGRES_DB=airflow \
    postgres:13

# 啟動 Redis (加入 --restart always)
echo "  - Starting Redis..."
podman run -d --name airflow-redis --replace \
    --restart always \
    -p 6379:6379 \
    redis:latest

echo "  - 等待資料庫就緒 (5s)..."
sleep 5

echo ">>> [6/6] 安裝與重啟 Airflow Systemd 服務..."
cp "$SYSTEMD_DIR"/*.service /etc/systemd/system/
systemctl daemon-reload

SERVICES=(
    airflow-scheduler
    airflow-webserver
    airflow-flower
    airflow-trigger
)

for SVC in "${SERVICES[@]}"; do
    echo "  - 重啟 $SVC..."
    systemctl enable "$SVC"
    systemctl restart "$SVC"
done

# 如果有 Celery Worker 也重啟 (假設 ID 1 和 2)
systemctl restart airflow-webserver # 再次確保 webserver 起來
echo "重啟 Worker..."
systemctl restart airflow-worker@1
# systemctl restart airflow-worker@2 # 如果有第二個的話

echo "=================================================="
echo "遷移完成！"
echo "1. 檔案已整理至 $SYSTEMD_DIR 與 $SCRIPTS_DIR"
echo "2. DB 現在由 Podman 自動管理 (--restart always)"
echo "3. Airflow 服務已設定為開機自啟並移除 DB 依賴"
echo "管理指令: $SCRIPTS_DIR/manage_airflow.sh"
echo "=================================================="
