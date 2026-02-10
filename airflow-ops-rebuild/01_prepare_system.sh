#!/bin/bash
set -euo pipefail

# ====================================================
# Step 1: Prepare System Environment
# - Check root
# - Install dependencies
# - Create user and directories
# ====================================================

# 取得腳本所在目錄的絕對路徑
SCRIPT_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" &> /dev/null && pwd )"

# 載入所有設定變數
source "$SCRIPT_DIR/config.env"

echo ">>> 檢查權限..."
if [ "${EUID}" -ne 0 ]; then
  echo "錯誤: 請使用 root (sudo) 執行此腳本"
  exit 1
fi

echo ">>> 安裝系統依賴..."
dnf install -y \
  gcc make openssl-devel bzip2-devel libffi-devel zlib-devel xz-devel tar gzip wget git \
  podman \
  postgresql-devel libpq-devel \
  || echo "警告: 部分套件安裝失敗，嘗試繼續..."

echo ">>> 建立 airflow 使用者與目錄..."
if ! id "$AIRFLOW_USER" &>/dev/null; then
  useradd -m -d "$AIRFLOW_HOME" "$AIRFLOW_USER"
  echo "  - 使用者 '$AIRFLOW_USER' 已建立。"
else
  echo "  - 使用者 '$AIRFLOW_USER' 已存在，跳過建立。"
fi

# 建立 Airflow 所需的基礎目錄
mkdir -p "$AIRFLOW_HOME" "$SYSTEMD_DIR" "$SCRIPTS_DIR" "$CONFIG_DIR" "$RUN_DIR" "$LOG_DIR"
# 注意：這裡只 chown airflow 自己的目錄，postgres_data 會在後續步驟獨立處理
chown -R "$AIRFLOW_USER:$AIRFLOW_USER" "$AIRFLOW_HOME"

echo "  - Airflow 目錄結構已建立於 $AIRFLOW_HOME"
echo "✅ 系統環境準備完成。"
