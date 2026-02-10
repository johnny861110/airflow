#!/bin/bash
set -euo pipefail

# ====================================================
# Step 2: Install required Python version
# - Check if version exists
# - If not, compile from source
# ====================================================

# 取得腳本所在目錄的絕對路徑
SCRIPT_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" &> /dev/null && pwd )"

# 載入所有設定變數
source "$SCRIPT_DIR/config.env"

echo ">>> 檢查並安裝 Python $PYTHON_VERSION..."
NEED_COMPILE=false
# 試著找出 python3.10, python3.11, etc. 的指令
PYTHON_CMD_SHORT="python${PYTHON_MAJOR_MINOR}"

if command -v "$PYTHON_CMD_SHORT" &> /dev/null; then
  # 取得版本字串，例如 "Python 3.10.14"
  CURRENT_VER="$("$PYTHON_CMD_SHORT" --version 2>&1 || true)"
  if [[ "$CURRENT_VER" == *"$PYTHON_VERSION"* ]]; then
    echo "  - 已安裝相符版本: $CURRENT_VER，跳過編譯。"
  else
    echo "  - 版本不符 (找到: $CURRENT_VER, 需要: $PYTHON_VERSION)，準備編譯..."
    NEED_COMPILE=true
  fi
else
  echo "  - 未偵測到 '$PYTHON_CMD_SHORT'，準備編譯..."
  NEED_COMPILE=true
fi

if [ "$NEED_COMPILE" = true ]; then
  # 確保編譯環境的依賴已安裝
  if ! (gcc --version && make --version) > /dev/null; then
    echo "錯誤: 找不到 gcc 或 make，無法編譯 Python。請先執行 01_prepare_system.sh。"
    exit 1
  fi
  
  echo "  - 開始從原始碼編譯 Python $PYTHON_VERSION (這可能需要 10-20 分鐘)..."
  mkdir -p /usr/local/src
  cd /usr/local/src
  
  if [ ! -f "Python-$PYTHON_VERSION.tgz" ]; then
    echo "  - 下載原始碼..."
    wget "https://www.python.org/ftp/python/$PYTHON_VERSION/Python-$PYTHON_VERSION.tgz"
  fi
  
  echo "  - 解壓縮..."
  rm -rf "Python-$PYTHON_VERSION" 2>/dev/null || true
  tar -xf "Python-$PYTHON_VERSION.tgz"
  
  cd "Python-$PYTHON_VERSION"
  echo "  - 執行 ./configure ..."
  ./configure --enable-optimizations --with-ensurepip=install
  
  echo "  - 執行 make altinstall (使用 $(nproc) 核心)..."
  make -j"$(nproc)" altinstall
  
  echo "  - Python 編譯完成。"
fi

# 最後驗證一次
if ! command -v "$PYTHON_CMD_SHORT" &> /dev/null; then
    echo "錯誤: Python '$PYTHON_CMD_SHORT' 安裝失敗或未找到。請檢查編譯日誌。"
    exit 1
fi

DETECTED_PYTHON_CMD="$(command -v "$PYTHON_CMD_SHORT")"
echo "  - Python 指令位置: $DETECTED_PYTHON_CMD"
echo "  - 版本: $("$DETECTED_PYTHON_CMD" --version)"
echo "✅ Python 環境準備完成。"
