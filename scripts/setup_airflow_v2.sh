#!/bin/bash
set -e

# ====================================================
# Airflow 環境重構腳本 v2 (編譯 Python 3.10.14 版)
# ====================================================

AIRFLOW_HOME="/opt/airflow"
AIRFLOW_USER="airflow"
VENV_DIR="$AIRFLOW_HOME/venv"
REQUIREMENTS_FILE="$AIRFLOW_HOME/requirement.txt"
CFG_FILE="$AIRFLOW_HOME/airflow.cfg"
PYTHON_VERSION="3.10.14"
PYTHON_SRC_DIR="/usr/local/src/Python-$PYTHON_VERSION"

echo ">>> [1/7] 檢查權限..."
if [ "$EUID" -ne 0 ]; then 
  echo "錯誤: 請使用 sudo 執行此腳本"
  exit 1
fi

echo ">>> [2/7] 安裝系統依賴..."
# 嘗試安裝編譯 Python 所需的工具
# 注意: 請確保 RHEL 訂閱或 Repo 正常
dnf install -y gcc make openssl-devel bzip2-devel libffi-devel zlib-devel xz-devel tar gzip wget podman \
    || echo "警告: 部分套件安裝失敗，將嘗試繼續..."

echo ">>> [3/7] 安裝 Python $PYTHON_VERSION (從原始碼編譯)..."

# 檢查是否已存在
if command -v python3.10 &> /dev/null; then
    CURRENT_VER=$(python3.10 --version)
    echo "發現已安裝: $CURRENT_VER"
    # 如果版本剛好是我們想要的，可以跳過，但為了確保是乾淨的 3.10.14，這裡可選擇重裝或沿用
    # 為節省時間，若版本匹配則沿用
    if [[ "$CURRENT_VER" == *"3.10.14"* ]]; then
        echo "版本相符，跳過編譯。"
    else
        echo "版本不符 (目標 3.10.14)，將重新編譯..."
        BUILD_PYTHON=true
    fi
else
    echo "未偵測到 python3.10，準備編譯..."
    BUILD_PYTHON=true
fi

if [ "$BUILD_PYTHON" = true ]; then
    echo "下載 Python $PYTHON_VERSION 原始碼..."
    mkdir -p /usr/local/src
    cd /usr/local/src
    
    if [ ! -f "Python-$PYTHON_VERSION.tgz" ]; then
        wget https://www.python.org/ftp/python/$PYTHON_VERSION/Python-$PYTHON_VERSION.tgz
    fi
    
    echo "解壓縮..."
    tar -xf Python-$PYTHON_VERSION.tgz
    cd Python-$PYTHON_VERSION
    
    echo "配置編譯選項..."
    ./configure --enable-optimizations
    
    echo "編譯並安裝 (make altinstall)..."
    # 使用 altinstall 避免覆蓋系統預設的 python3 (非常重要！)
    make -j$(nproc) altinstall
    
    echo "Python 3.10 安裝完成。"
fi

PYTHON_CMD="/usr/local/bin/python3.10"
if [ ! -f "$PYTHON_CMD" ]; then
    # 若不在 /usr/local/bin，嘗試找一下 path
    PYTHON_CMD=$(which python3.10)
fi

echo "使用 Python 指令: $PYTHON_CMD"

echo ">>> [4/7] 初始 Airflow 目錄與權限..."
mkdir -p "$AIRFLOW_HOME"
# 確保 requirement.txt 
if [ -f "requirement.txt" ]; then
    cp requirement.txt "$REQUIREMENTS_FILE"
fi

echo ">>> [5/7] 設定 Podman (Postgres 13 & Redis)..."
podman rm -f airflow-postgres airflow-redis 2>/dev/null || true

podman run -d --name airflow-postgres --replace \
    --restart unless-stopped \
    -p 5432:5432 \
    -e POSTGRES_USER=airflow \
    -e POSTGRES_PASSWORD=airflow \
    -e POSTGRES_DB=airflow \
    postgres:13

podman run -d --name airflow-redis --replace \
    --restart unless-stopped \
    -p 6379:6379 \
    redis:latest

# 等待資料庫就緒
sleep 5

echo ">>> [6/7] 建構虛擬環境 ($VENV_DIR)..."
# 修正目錄擁有者
chown -R $AIRFLOW_USER:$AIRFLOW_USER "$AIRFLOW_HOME"

# 切換到 airflow 使用者執行 venv
runuser -u $AIRFLOW_USER -- bash <<EOF
    cd "$AIRFLOW_HOME"
    
    # 清理舊 venv
    rm -rf "$VENV_DIR"
    
    echo "建立 venv..."
    $PYTHON_CMD -m venv "$VENV_DIR"
    
    source "$VENV_DIR/bin/activate"
    
    echo "更新 pip..."
    pip install --upgrade pip
    
    echo "安裝套件 (這可能需要一點時間)..."
    if [ -f "$REQUIREMENTS_FILE" ]; then
        pip install -r "$REQUIREMENTS_FILE" --constraint "https://raw.githubusercontent.com/apache/airflow/constraints-3.1.6/constraints-3.10.txt"
    else
        echo "警告: 找不到 $REQUIREMENTS_FILE"
    fi
EOF

echo ">>> [7/7] 更新設定與初始化資料庫..."
if [ -f "$CFG_FILE" ]; then
    cp "$CFG_FILE" "${CFG_FILE}.bak_v2"
    chown $AIRFLOW_USER:$AIRFLOW_USER "${CFG_FILE}.bak_v2"
    
    sed -i 's/^executor = .*/executor = CeleryExecutor/' "$CFG_FILE"
    sed -i 's|^sql_alchemy_conn = .*|sql_alchemy_conn = postgresql+psycopg2://airflow:airflow@localhost:5432/airflow|' "$CFG_FILE"
    sed -i 's|^broker_url = .*|broker_url = redis://localhost:6379/0|' "$CFG_FILE"
    sed -i 's|^result_backend = .*|result_backend = db+postgresql://airflow:airflow@localhost:5432/airflow|' "$CFG_FILE"
    sed -i 's|^celery_result_backend = .*|celery_result_backend = db+postgresql://airflow:airflow@localhost:5432/airflow|' "$CFG_FILE"
fi

# 初始化 DB
runuser -u $AIRFLOW_USER -- bash <<EOF
    export AIRFLOW_HOME="$AIRFLOW_HOME"
    source "$VENV_DIR/bin/activate"
    airflow db migrate
    airflow users create --username admin --firstname admin --lastname user --role Admin --email admin@example.com -p admin
EOF


# 設置 manage_airflow.sh 可執行權限
chmod +x "$AIRFLOW_HOME/manage_airflow.sh"

echo "=================================================="
echo "完成！已安裝 Python 3.10.14 並重構 Airflow 環境。"
echo "啟用指令: source $VENV_DIR/bin/activate"
echo "=================================================="
