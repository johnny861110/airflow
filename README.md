# Airflow 自動化調度專案

本專案提供了一個在 RHEL (或相容) 作業系統上，使用 `systemd` 進行服務管理的 Apache Airflow 生產級環境。

它包含完整的自動化安裝腳本、服務管理工具，以及與 Hadoop/Spark 的整合設定範例。

## 專案特色

- **自動化安裝**: 使用單一腳本 `setup_airflow_complete.sh` 完成所有環境建置。
- **服務化管理**: 透過 `systemd` 管理 Airflow Scheduler, Webserver, Worker, Trigger, Flower 等核心服務。
- **容器化相依性**: 使用 `Podman` 管理 PostgreSQL 和 Redis，簡化部署並隔離環境。
- **Celery 執行器**: 設定為使用 `CeleryExecutor`，支援平行化與擴展任務。
- **版本鎖定**: 精確鎖定 Airflow v2.8.1 與 Python v3.10.14，確保環境穩定性。
- **SELinux 相容**: 安裝腳本已處理 `Podman` 的 SELinux 標籤問題。

## 目錄結構

```
/opt/airflow/
├── dags/                     # DAG 檔案存放目錄
├── logs/                     # Airflow 任務日誌
├── plugins/                  # 自訂 Airflow 插件
├── scripts/                  # 主要管理腳本
│   ├── manage_airflow.sh     # 啟動/停止/重啟服務
│   └── setup_airflow_v2.sh   # (舊版腳本，請使用根目錄的 setup_airflow_complete.sh)
├── systemd/                  # systemd service unit 檔案
├── integrations/             # 整合設定 (Hadoop, Spark)
├── config/                   # 環境設定檔
│   └── airflow.env           # (注意: 此檔案為參考，實際設定由 setup script 硬寫入 airflow.cfg)
├── setup_airflow_complete.sh # 主要安裝腳本
└── README.md                 # 本說明檔案
```

## 環境安裝

**重要**: 安裝前請確保您在一個乾淨的 RHEL-like (CentOS, Rocky Linux, etc.) 環境中，並具有 `root` 權限。

1.  **複製專案**:
    將整個專案複製到 `/opt/airflow` 目錄。

2.  **執行安裝腳本**:
    以 `root` 身份執行安裝腳本。此腳本將會自動處理所有事情，包含：
    - 安裝系統依賴套件 (gcc, podman, etc.)
    - 建立 `airflow` 使用者
    - 下載並編譯指定版本的 Python (如果需要)
    - 透過 `Podman` 啟動 Postgres 和 Redis 容器
    - 建立 Python 虛擬環境 (`venv`) 並安裝 Airflow 及其依賴
    - 初始化 Airflow 資料庫並建立預設管理員 (`admin`/`admin`)
    - 設定並啟用 `systemd` 服務

    ```bash
    sudo bash /opt/airflow/setup_airflow_complete.sh
    ```

3.  **驗證安裝**:
    腳本執行完畢後，Airflow 服務應已在背景執行。
    - **Web UI**: http://<YOUR_SERVER_IP>:8080
    - **預設帳號**: `admin`
    - **預設密碼**: `admin`

    您可以透過 `systemctl status` 檢查服務狀態：
    ```bash
    systemctl status airflow-scheduler
    systemctl status airflow-webserver
    ```

## 日常管理

使用 `/opt/airflow/scripts/airflow-ops` 腳本來統一管理所有 Airflow 相關服務，包括 systemd 管理的 Airflow 元件和 Podman 容器中的資料庫 (Postgres/Redis)。

### 使用方式

```bash
sudo /opt/airflow/scripts/airflow-ops {動作} {目標}
```

- **動作 (Action)**:
    - `start`: 啟動
    - `stop`: 停止
    - `restart`: 重啟
    - `status`: 查看狀態
    - `logs`: 查看日誌 (針對 systemd 服務使用 `journalctl -f`, 針對 Podman 容器使用 `podman logs -f`)

- **目標 (Target)**:
    - `all`: 整個 Airflow 堆疊 (包含基礎設施和 Airflow 服務)
    - `airflow`: 所有 Airflow 元件 (Webserver, Scheduler, Triggerer, Flower, Worker)
    - `infra`: 基礎設施 (Postgres, Redis)
    - `db` / `postgres`: 僅 Postgres 容器
    - `redis`: 僅 Redis 容器
    - `web`: 僅 Airflow Webserver
    - `scheduler`: 僅 Airflow Scheduler
    - `triggerer`: 僅 Airflow Triggerer
    - `flower`: 僅 Airflow Flower
    - `worker` / `workers`: 所有 Airflow Worker 實例

### 範例

```bash
# 查看所有服務的狀態
sudo /opt/airflow/scripts/airflow-ops status all

# 啟動所有 Airflow 服務 (不包含資料庫)
sudo /opt/airflow/scripts/airflow-ops start airflow

# 停止 Airflow Webserver
sudo /opt/airflow/scripts/airflow-ops stop web

# 重啟資料庫基礎設施 (Postgres 和 Redis)
sudo /opt/airflow/scripts/airflow-ops restart infra

# 追蹤 Airflow Scheduler 的日誌
sudo /opt/airflow/scripts/airflow-ops logs scheduler
```

## DAG 開發

將您的 DAG Python 檔案放入 `dags/` 目錄即可。Airflow Scheduler 會自動偵測並載入。

專案內已包含一個 `dags/example_ops_test.py` 作為測試範例，您可以透過 Airflow UI 手動觸發它來驗證 Celery worker 是否正常運作。

## 設定

- **主要設定檔**: `airflow.cfg`，由 `setup_airflow_complete.sh` 腳本在安裝時自動產生與設定。
- **環境變數參考**: `config/airflow.env` 檔案列出了一些可用的環境變數，但請注意，目前的自動化腳本**並未**使用此檔案。所有關鍵設定（如資料庫連線）都已在 `setup_airflow_complete.sh` 中硬式編碼至 `airflow.cfg`。

## 整合

`integrations/` 目錄存放了與其他系統 (如 Hadoop, Spark) 整合時所需的設定檔範本。您需要根據您的實際環境調整這些檔案，並確保 Airflow Worker 所在的節點可以存取相關服務。
