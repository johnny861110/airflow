#!/bin/bash
set -euo pipefail

# ====================================================
# Main Airflow Setup Orchestrator
# ====================================================

# 取得腳本所在目錄的絕對路徑
SCRIPT_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" &> /dev/null && pwd )"
cd "$SCRIPT_DIR"

# 載入所有設定變數
if [ -f "$SCRIPT_DIR/config.env" ]; then
  source "$SCRIPT_DIR/config.env"
else
  echo "錯誤: 設定檔 config.env 不存在！"
  exit 1
fi

# --- 依序執行所有安裝步驟 ---
echo ">>> (1/6) 準備系統環境 (使用者、目錄、系統依賴)..."
bash "$SCRIPT_DIR/01_prepare_system.sh"

echo ">>> (2/6) 安裝指定的 Python 版本..."
bash "$SCRIPT_DIR/02_install_python.sh"

echo ">>> (3/6) 啟動 Postgres / Redis 容器..."
bash "$SCRIPT_DIR/03_start_containers.sh"

echo ">>> (4/6) 建立 venv 並安裝 Airflow..."
bash "$SCRIPT_DIR/04_setup_airflow_venv.sh"

echo ">>> (5/6) 設定 Airflow (airflow.cfg) 並初始化資料庫..."
bash "$SCRIPT_DIR/05_configure_airflow.sh"

echo ">>> (6/6) 設定並啟動 systemd 服務..."
bash "$SCRIPT_DIR/06_setup_systemd.sh"

echo "=================================================="
echo "✅ Airflow 環境已全部署完成！"
echo
echo "---"
echo "下一步建議的驗證指令:"
echo "  - 檢查 Podman 容器: sudo podman ps"
echo "  - 檢查 Airflow Webserver 服務: systemctl status airflow-webserver -l --no-pager"
echo "  - 檢查 Airflow Scheduler 服務: systemctl status airflow-scheduler -l --no-pager"
echo "---"
echo
echo "您可以透過編輯 'config.env' 來調整設定，並單獨執行 '01_...' 到 '06_...' 的腳本來進行維護。"
echo "=================================================="