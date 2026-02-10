#!/bin/bash
set -euo pipefail

# ====================================================
# Step 5: Configure Airflow and Initialize Database
# - Generates and configures airflow.cfg
# - Runs `db migrate`
# - Creates an initial admin user
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

if [ ! -d "$VENV_DIR" ]; then
  echo "錯誤: Venv目錄 '$VENV_DIR' 不存在。請先執行 04_setup_airflow_venv.sh。"
  exit 1
fi

# --- Main Logic ---

echo ">>> 以 '$AIRFLOW_USER' 使用者身份設定 airflow.cfg 並初始化資料庫..."
runuser -u "$AIRFLOW_USER" -- bash -lc "
  set -euo pipefail
  
  echo '  - 啟用 venv...'
  source '$VENV_DIR/bin/activate'
  export AIRFLOW_HOME='$AIRFLOW_HOME' # 確保 airflow 指令知道家在哪裡

  # 如果 airflow.cfg 不存在，執行一個無害指令讓它自動產生
  if [ ! -f '$CFG_FILE' ]; then
    echo '  - airflow.cfg 不存在，執行 airflow version 來自動產生...'
    airflow version >/dev/null
  fi

  echo '  - 正在修改 airflow.cfg...'
  # 使用 sed 快速設定，這通常比多次執行 'airflow config set' 更快
  sed -i 's|^#?executor = .*|executor = CeleryExecutor|' '$CFG_FILE'
  sed -i 's|^#?sql_alchemy_conn = .*|sql_alchemy_conn = postgresql+psycopg2://airflow:airflow@127.0.0.1:5432/airflow|' '$CFG_FILE'
  sed -i 's|^#?broker_url = .*|broker_url = redis://127.0.0.1:6379/0|' '$CFG_FILE'
  sed -i 's|^#?result_backend = .*|result_backend = db+postgresql://airflow:airflow@127.0.0.1:5432/airflow|' '$CFG_FILE'
  sed -i "s|^#?dags_folder = .*|dags_folder = $AIRFLOW_HOME/dags|" '$CFG_FILE'
  # 移除 auth_manager 以使用預設的 FAB 認證，避免 webserver 因缺少 provider 而啟動失敗
  sed -i '/^#?auth_manager =/d' '$CFG_FILE'
  
  echo '  - 執行 airflow db migrate (初始化/升級資料庫)...'
  airflow db migrate

  echo '  - 建立 admin 使用者 (密碼: admin)...'
  # 使用 || true 避免在使用者已存在時報錯中斷
  airflow users create \
    --username admin \
    --firstname Admin \
    --lastname User \
    --role Admin \
    --email admin@example.com \
    --password admin || true
"

chown "$AIRFLOW_USER:$AIRFLOW_USER" "$CFG_FILE"

echo "✅ Airflow 設定與資料庫初始化完成。"
