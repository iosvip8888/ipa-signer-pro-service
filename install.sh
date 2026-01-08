#!/bin/bash

# 顏色定義
GREEN='\033[0;32m'
RED='\033[0;31m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

echo -e "${BLUE}==========================================${NC}"
echo -e "${GREEN}     iOS 簽名託管服務 - 容器自動化部署工具       ${NC}"
echo -e "${BLUE}==========================================${NC}"

# 1. 檢查 Docker 環境
echo -e "\n[1/5] 正在檢查 Docker 運行環境..."
if ! [ -x "$(command -v docker)" ]; then
    echo -e "${RED}❌ 錯誤: 未偵測到 Docker。請先在寶塔面板安裝 Docker 管理器。${NC}" >&2
    exit 1
fi

if ! [ -x "$(command -v docker-compose)" ]; then
    echo -e "${YELLOW}⚠️ 提示: 未偵測到獨立的 docker-compose 指令，嘗試使用 'docker compose'...${NC}"
    DOCKER_CMD="docker compose"
else
    DOCKER_CMD="docker-compose"
fi
echo -e "${GREEN}✅ Docker 環境正常 (${DOCKER_CMD})${NC}"

# 2. 檢查並建立必要資料夾
echo -e "\n[2/5] 正在建立必要資料夾與設定權限..."
DIRS=("mysql_data" "data" "logs" "private_certs" "signed" "apps" "fenfa" "plists" "firmcert" "tmp" "tmp_sign" "uploads" ".zsign_cache" ".zsign_debug" "downloaded_certs")
for dir in "${DIRS[@]}"; do
    if [ ! -d "$dir" ]; then
        mkdir -p "$dir"
        echo "   建立目錄: $dir"
    fi
done
chmod -R 777 data logs private_certs signed apps fenfa plists firmcert tmp
echo -e "${GREEN}✅ 資料夾準備就緒${NC}"

# 3. 驗證配置文件
echo -e "\n[3/5] 正在驗證配置文件內容..."
if [ ! -f ".env" ]; then
    echo -e "${RED}❌ 錯誤: 找不到 .env 文件！請先參照範例建立 .env。${NC}"
    exit 1
fi

# 簡單檢查 .env 內的關鍵變數是否為空
source .env
if [ -z "$LICENSE_KEY" ] || [ -z "$AGENT_CODE" ]; then
    echo -e "${YELLOW}⚠️ 警告: .env 中的 LICENSE_KEY 或 AGENT_CODE 似乎為空，這可能導致啟動失敗。${NC}"
fi

if [ ! -f "init_db.sql" ]; then
    echo -e "${YELLOW}⚠️ 警告: 找不到 init_db.sql，新伺服器將無法自動建立資料庫表結構！${NC}"
else
    echo -e "${GREEN}✅ 配置文件檢查通過${NC}"
fi

# 4. 測試網路連線 (Docker Hub)
echo -e "\n[4/5] 正在測試與 Docker Hub 的連線..."
if timeout 5s curl -s --head  https://hub.docker.com > /dev/null; then
    echo -e "${GREEN}✅ 網路連線正常${NC}"
else
    echo -e "${YELLOW}⚠️ 警告: 無法連線至 Docker Hub，拉取鏡像可能會失敗。請檢查伺服器 DNS 或代理設置。${NC}"
fi

# 5. 啟動容器
echo -e "\n[5/5] 正在拉取並啟動容器環境..."
$DOCKER_CMD pull || echo -e "${YELLOW}提示: 部分鏡像拉取失敗，嘗試直接啟動...${NC}"
$DOCKER_CMD up -d

# 最終檢查容器狀態
echo -e "\n------------------------------------------"
echo -e "${BLUE} 正在檢查容器運行狀態:${NC}"
docker ps --format "table {{.Names}}\t{{.Status}}\t{{.Ports}}"

echo -e "\n${GREEN} 部署指令執行完畢！${NC}"
echo -e "${YELLOW}請確認上方列表中的容器狀態是否為 (Up)。${NC}"
echo -e "${BLUE}後續步驟：${NC}"
echo -e "1. 至寶塔面板「網站」建立站點。"
echo -e "2. 設定反向代理：${BLUE}http://127.0.0.1:1235${NC} (分發前台)"
echo -e "3. 設定管理後台：${BLUE}http://127.0.0.1:8001${NC}"
echo -e "4. 如果無法打開網頁，請檢查寶塔「安全」頁面是否放行了上述端口。"
echo -e "${BLUE}==========================================${NC}"
