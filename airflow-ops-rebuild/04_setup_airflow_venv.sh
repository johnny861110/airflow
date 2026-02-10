#!/bin/bash
set -euo pipefail

# ====================================================
# Step 4: Setup Airflow Python Virtual Environment (Venv)
# - Prepares requirement.txt
# - Creates venv as the airflow user
# - Installs packages using pip and constraint file
# ====================================================

# 取得腳本所在目錄的絕對路徑
SCRIPT_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" &> /dev/null && pwd )"

# 載入所有設定變數
source "$SCRIPT_DIR/config.env"

# --- Pre-flight Checks ---
if ! id "$AIRFLOW_USER" &>/dev/null; then
  echo "錯誤: Airflow 使用者 '$AIRFLOW_USER' 不存在。請先執行 01_prepare_system.sh。"
  exit 1
fi

PYTHON_CMD_SHORT="python${PYTHON_MAJOR_MINOR}"
if ! command -v "$PYTHON_CMD_SHORT" &> /dev/null; then
  echo "錯誤: Python '$PYTHON_CMD_SHORT' 找不到。請先執行 02_install_python.sh。"
  exit 1
fi
DETECTED_PYTHON_CMD="$(command -v "$PYTHON_CMD_SHORT")"


# --- Main Logic ---

echo ">>> 準備 requirements.txt..."
# 如果 airflow home 中已經有，就不動它
if [ -f "$REQUIREMENTS_FILE" ]; then
  echo "  - $REQUIREMENTS_FILE 已存在，將直接使用。"
# 否則，從目前目錄複製
elif [ -f "$SCRIPT_DIR/requirement.txt" ]; then
  echo "  - 複製 'requirement.txt' 到 $AIRFLOW_HOME"
  cp "$SCRIPT_DIR/requirement.txt" "$REQUIREMENTS_FILE"
elif [ -f "$SCRIPT_DIR/requirements.txt" ]; then
  echo "  - 複製 'requirements.txt' 到 $AIRFLOW_HOME"
  cp "$SCRIPT_DIR/requirements.txt" "$REQUIREMENTS_FILE"
else
  echo "  - 找不到 requirement(s).txt，將直接安裝預設的 airflow providers。"
fi

echo ">>> 設定 Airflow 目錄權限..."
# 再次 chown airflow home，確保新複製的檔案權限正確
chown -R "$AIRFLOW_USER:$AIRFLOW_USER" "$AIRFLOW_HOME"
# **重要**: 再次執行 Postgres 目錄的權限設定，避免被上面的 chown 覆蓋
echo "  - 重新確認 Postgres 資料目錄權限..."
chown -R "${POSTGRES_UID}:${POSTGRES_GID}" "$MOUNT_DB_DIR"
chmod 700 "$MOUNT_DB_DIR"
restorecon -RFv "$MOUNT_DB_DIR" 2>/dev/null || true

echo ">>> 以 '$AIRFLOW_USER' 使用者身份建置 Venv 並安裝套件..."
# 使用 runuser 切换到 airflow 用户执行
runuser -u "$AIRFLOW_USER" -- bash -lc "
  set -euo pipefail
  cd '$AIRFLOW_HOME'

  echo '  - 正在建立 Python 虛擬環境於 $VENV_DIR...'
  rm -rf '$VENV_DIR' 2>/dev/null || true
  '$DETECTED_PYTHON_CMD' -m venv '$VENV_DIR'
  
  echo '  - 啟用 venv 並升級 pip...'
  source '$VENV_DIR/bin/activate'
  pip install --upgrade pip

  echo '  - 使用約束文件: $CONSTRAINT_URL'
  if [ -f '$REQUIREMENTS_FILE' ]; then
    echo '  - 從 $REQUIREMENTS_FILE 安裝套件...'
    pip install -r '$REQUIREMENTS_FILE' --constraint '$CONSTRAINT_URL'
  else
    echo '  - 安裝預設套件: apache-airflow[postgres,redis,celery]'
    pip install 'apache-airflow[postgres,redis,celery]==$AIRFLOW_VERSION' --constraint '$CONSTRAINT_URL'
  fi
  
  echo '  - 套件安裝完成。'
"

echo "✅ Airflow Venv 已成功建立並安裝完套件。"
