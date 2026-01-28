#!/bin/bash
set -e

# ====================================================
# Airflow 完整建置與重構腳本 (Merged v2 + v3)
# 功能: Python編譯 + Venv安裝 + 目錄重構 + Podman DB (Persistence) + Systemd
# ====================================================

# --- 變數設定 ---
AIRFLOW_HOME="/opt/airflow"
AIRFLOW_USER="airflow"
VENV_DIR="$AIRFLOW_HOME/venv"
REQUIREMENTS_FILE="$AIRFLOW_HOME/requirement.txt"
CFG_FILE="$AIRFLOW_HOME/airflow.cfg"
SYSTEMD_DIR="$AIRFLOW_HOME/systemd"
SCRIPTS_DIR="$AIRFLOW_HOME/scripts"
MOUNT_DB_DIR="$AIRFLOW_HOME/postgres_data"

# Python 版本設定
PYTHON_VERSION="3.10.14"
PYTHON_SRC_DIR="/usr/local/src/Python-$PYTHON_VERSION"

echo ">>> [1/9] 檢查權限..."
if [ "$EUID" -ne 0 ]; then 
  echo "錯誤: 請使用 root (sudo) 執行此腳本"
  exit 1
fi

echo ">>> [2/9] 準備系統依賴..."
dnf install -y gcc make openssl-devel bzip2-devel libffi-devel zlib-devel xz-devel tar gzip wget podman git \
    || echo "警告: 部分套件安裝失敗，嘗試繼續..."

# 建立使用者 (如果不存在)
if ! id "$AIRFLOW_USER" &>/dev/null; then
    useradd -m -d "$AIRFLOW_HOME" "$AIRFLOW_USER"
fi

echo ">>> [3/9] 檢查並安裝 Python $PYTHON_VERSION..."
NEED_COMPILE=false
if command -v python3.10 &> /dev/null; then
    CURRENT_VER=$(python3.10 --version)
    if [[ "$CURRENT_VER" == *"$PYTHON_VERSION"* ]]; then
        echo "  - 已安裝相符版本: $CURRENT_VER，跳過編譯。"
    else
        echo "  - 版本不符，準備編譯..."
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
        wget https://www.python.org/ftp/python/$PYTHON_VERSION/Python-$PYTHON_VERSION.tgz
    fi
    tar -xf Python-$PYTHON_VERSION.tgz
    cd Python-$PYTHON_VERSION
    ./configure --enable-optimizations
    make -j$(nproc) altinstall
    echo "  - Python 編譯完成。"
fi
PYTHON_CMD=$(which python3.10 || echo "/usr/local/bin/python3.10")

echo ">>> [4/9] 整理目錄與檔案結構 (Restructuring)..."
mkdir -p "$SYSTEMD_DIR" "$SCRIPTS_DIR" "$AIRFLOW_HOME/config"

# 移動檔案 (包含錯誤修復)
mv "$AIRFLOW_HOME"/*.service "$SYSTEMD_DIR/" 2>/dev/null || true
[ -f "$AIRFLOW_HOME/airflow-worker@.servive" ] && mv "$AIRFLOW_HOME/airflow-worker@.servive" "$SYSTEMD_DIR/airflow-worker@.service"
mv "$AIRFLOW_HOME/init_db.sh" "$SCRIPTS_DIR/" 2>/dev/null || true
mv "$AIRFLOW_HOME/manage_airflow.sh" "$SCRIPTS_DIR/" 2>/dev/null || true

# 清理舊的 Systemd DB 依賴檔 (因為現在改用 Podman 原生管理)
rm -f "$SYSTEMD_DIR/airflow-postgres.service" "$SYSTEMD_DIR/airflow-redis.service"
rm -f /etc/systemd/system/airflow-postgres.service /etc/systemd/system/airflow-redis.service
systemctl daemon-reload

echo ">>> [5/9] 啟動資料庫容器 (Podman with Persistence)..."
# 建立資料夾
mkdir -p "$MOUNT_DB_DIR"
chmod 777 "$MOUNT_DB_DIR" # 方便容器寫入

# 停止舊容器
podman rm -f airflow-postgres airflow-redis 2>/dev/null || true

# 啟動 Postgres
echo "  - Starting Postgres..."
podman run -d --name airflow-postgres --replace \
    --restart always \
    -v "$MOUNT_DB_DIR":/var/lib/postgresql/data \
    -p 5432:5432 \
    -e POSTGRES_USER=airflow \
    -e POSTGRES_PASSWORD=airflow \
    -e POSTGRES_DB=airflow \
    docker.io/library/postgres:13.4-buster


# 啟動 Redis
echo "  - Starting Redis..."
podman run -d --name airflow-redis --replace \
    --restart always \
    -p 6379:6379 \
    docker.io/library/redis:7.2-rc2-bullseye

sleep 30

echo ">>> [6/9] 建置 Python 虛擬環境 (Venv)..."
chown -R $AIRFLOW_USER:$AIRFLOW_USER "$AIRFLOW_HOME"
# 使用 runuser 切換身分執行安裝，避免 root 權限汙染 pip
runuser -u $AIRFLOW_USER -- bash <<EOF
    cd "$AIRFLOW_HOME"
    
    # 如果 venv 不存在或強制重建，這裡假設若 requirement 變更可能想重建，這裡先做基本檢查
    if [ ! -d "$VENV_DIR" ]; then
        echo "  - 建立新 venv..."
        $PYTHON_CMD -m venv "$VENV_DIR"
    fi
    
    source "$VENV_DIR/bin/activate"
    pip install --upgrade pip
    
    echo "  - 安裝 Python 套件..."
    if [ -f "$REQUIREMENTS_FILE" ]; then
        
	#pip install -r "$REQUIREMENTS_FILE" --constraint "https://raw.githubusercontent.com/apache/airflow/constraints-2.10.2/constraints-3.10.txt"
    	pip install -r "$REQUIREMENTS_FILE"
    else
        echo "  - 警告: 找不到 requirement.txt，安裝基本 airflow..."
        pip install "apache-airflow[postgres,redis,celery]==2.10.2"
    fi
EOF

echo ">>> [7/9] 設定 airflow.cfg..."
# 假如檔案不存在，先跑一次 version 產生預設檔
if [ ! -f "$CFG_FILE" ]; then
    runuser -u $AIRFLOW_USER -- bash -c "source $VENV_DIR/bin/activate && export AIRFLOW_HOME=$AIRFLOW_HOME && airflow version"
fi

# 修改設定 (來自 v2 的邏輯)
sed -i 's/^executor = .*/executor = CeleryExecutor/' "$CFG_FILE"
sed -i 's|^sql_alchemy_conn = .*|sql_alchemy_conn = postgresql+psycopg2://airflow:airflow@localhost:5432/airflow|' "$CFG_FILE"
sed -i 's|^broker_url = .*|broker_url = redis://localhost:6379/0|' "$CFG_FILE"
sed -i 's|^result_backend = .*|result_backend = db+postgresql://airflow:airflow@localhost:5432/airflow|' "$CFG_FILE"
sed -i 's|^celery_result_backend = .*|celery_result_backend = db+postgresql://airflow:airflow@localhost:5432/airflow|' "$CFG_FILE"
# 確保 dags_folder 正確
sed -i "s|^dags_folder = .*|dags_folder = $AIRFLOW_HOME/dags|" "$CFG_FILE"

# 再次確保權限
chown $AIRFLOW_USER:$AIRFLOW_USER "$CFG_FILE"

echo ">>> [8/9] 初始化資料庫..."
runuser -u $AIRFLOW_USER -- bash <<EOF
    export AIRFLOW_HOME="$AIRFLOW_HOME"
    source "$VENV_DIR/bin/activate"
    # 使用 migrate 比 init 更安全，能處理升級狀況
    airflow db migrate
    
    # 建立 Admin (若已存在會略過或報錯但不中斷)
    airflow users create --username admin --firstname Admin --lastname User --role Admin --email admin@example.com --password admin 2>/dev/null || true
EOF

echo ">>> [9/9] 設定 Systemd 並啟動 Airflow..."
# 修正 Service 檔內容 (移除 DB 依賴)
for SVC_FILE in "$SYSTEMD_DIR"/*.service; do
    sed -i 's/airflow-postgres.service//g' "$SVC_FILE"
    sed -i 's/airflow-redis.service//g' "$SVC_FILE"
    sed -i 's/postgresql.service//g' "$SVC_FILE"
    sed -i 's/redis.service//g' "$SVC_FILE"
done

# 修正 manage_airflow.sh
MANAGE_SCRIPT="$SCRIPTS_DIR/manage_airflow.sh"
if [ -f "$MANAGE_SCRIPT" ]; then
    sed -i '/airflow-postgres.service/d' "$MANAGE_SCRIPT"
    sed -i '/airflow-redis.service/d' "$MANAGE_SCRIPT"
    chmod +x "$MANAGE_SCRIPT"
fi

# 安裝並啟動 Service
cp "$SYSTEMD_DIR"/*.service /etc/systemd/system/
systemctl daemon-reload

SERVICES=(airflow-scheduler airflow-webserver airflow-flower airflow-trigger)
for SVC in "${SERVICES[@]}"; do
    systemctl enable "$SVC"
    systemctl restart "$SVC"
done
# 啟動 Worker
rm -f /etc/systemd/system/airflow-worker@.service
systemctl restart airflow-worker@1

echo "=================================================="
echo "全套建置完成！(Integrated Setup)"
echo "1. Python 3.10 & Venv 已就緒"
echo "2. DB (Postgres/Redis) 運行於 Podman (Volume: $MOUNT_DB_DIR)"
echo "3. Airflow 設定檔已修正並完成 DB Migration"
echo "4. Systemd 服務已啟動"
echo "驗證: systemctl status airflow-scheduler"
echo "=================================================="
