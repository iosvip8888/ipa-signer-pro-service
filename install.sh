#!/bin/bash

# =================================================================
# 服務名稱：iOS 簽名託管容器自動化部署工具
# 當前版本：v1.2.5 (2026-01-08)
# 技術支持：Telegram @ios_vip8888
# =================================================================

# 顏色定義
GREEN='\033[0;32m'
RED='\033[0;31m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

# 清屏並顯示標題
clear
echo -e "${BLUE}==========================================${NC}"
echo -e "${GREEN}      iOS 簽名託管服務 - 容器自動化部署工具        ${NC}"
echo -e "${BLUE}==========================================${NC}"

# 1. 檢查 Docker 環境
echo -e "\n[1/5] 正在檢查 Docker 運行環境..."
if ! [ -x "$(command -v docker)" ]; then
    echo -e "${RED}❌ 錯誤: 未偵測到 Docker。${NC}"
    echo -e "${YELLOW}請先在寶塔面板「軟體商店」安裝 Docker 管理器，或執行: curl -fsSL https://get.docker.com | bash${NC}"
    exit 1
fi

if ! [ -x "$(command -v docker-compose)" ]; then
    echo -e "${YELLOW}⚠️ 提示: 未偵測到獨立 docker-compose，嘗試使用 'docker compose'...${NC}"
    DOCKER_CMD="docker compose"
else
    DOCKER_CMD="docker-compose"
fi
echo -e "${GREEN}✅ Docker 環境正常 (${DOCKER_CMD})${NC}"

# 2. 檢查並建立必要資料夾
echo -e "\n[2/5] 正在建立必要目錄與設定權限..."
DIRS=("mysql_data" "data" "logs" "private_certs" "signed" "apps" "fenfa" "plists" "firmcert" "tmp" "tmp_sign" "uploads" ".zsign_cache" ".zsign_debug" "downloaded_certs")
for dir in "${DIRS[@]}"; do
    if [ ! -d "$dir" ]; then
        mkdir -p "$dir"
        echo "   建立目錄: $dir"
    fi
done
chmod -R 777 data logs private_certs signed apps fenfa plists firmcert tmp uploads
echo -e "${GREEN}✅ 資料夾準備就緒${NC}"

# 3. 驗證配置文件
echo -e "\n[3/5] 正在驗證配置文件內容..."
if [ ! -f ".env" ]; then
    echo -e "${RED}❌ 錯誤: 找不到 .env 配置文件！${NC}"
    echo -e "${YELLOW}指引: 請參照 .env.example 建立並填寫 LICENSE_KEY 等資訊。${NC}"
    exit 1
fi

source .env
if [ -z "$LICENSE_KEY" ] || [ -z "$AGENT_CODE" ] || [ -z "$DOMAIN" ]; then
    echo -e "${RED}❌ 錯誤: .env 中的關鍵變數 (LICENSE_KEY/AGENT_CODE/DOMAIN) 缺失！${NC}"
    exit 1
fi
echo -e "${GREEN}✅ 配置文件校驗通過${NC}"

# 4. 驗證鏡像倉庫權限
echo -e "\n[4/5] 正在配置鏡像伺服器授權..."

# 提示用戶輸入 Token (如果你在執行時已經在腳本內填寫，這步會自動跳過)
GH_READ_TOKEN="" 

if [ -z "$GH_READ_TOKEN" ]; then
    echo -e "${YELLOW}請輸入您的鏡像拉取授權碼 (Image Pull Token):${NC}"
    read -p "Token: " GH_READ_TOKEN
fi

if [ -z "$GH_READ_TOKEN" ]; then
    echo -e "${RED}❌ 錯誤: 未提供授權碼，無法拉取私有容器鏡像。${NC}"
    echo -e "${BLUE}如需獲取授權碼，請聯繫 Telegram: @ios_vip8888${NC}"
    exit 1
fi

# 執行登入
echo "$GH_READ_TOKEN" | docker login ghcr.io -u iosvip8888 --password-stdin > /dev/null 2>&1

if [ $? -eq 0 ]; then
    echo -e "${GREEN}✅ 鏡像倉庫授權成功${NC}"
else
    echo -e "${RED}❌ 錯誤: 授權碼無效或已過期。${NC}"
    exit 1
fi

# 5. 啟動容器
echo -e "\n[5/5] 正在拉取並啟動 v1.2.5 鏡像環境..."
$DOCKER_CMD pull
$DOCKER_CMD up -d

# 安全性：拉取後自動登出
docker logout ghcr.io > /dev/null 2>&1

# 最終檢查
echo -e "\n------------------------------------------"
echo -e "${BLUE}正在檢查容器運行狀態:${NC}"
docker ps --format "table {{.Names}}\t{{.Status}}\t{{.Ports}}"

echo -e "\n${GREEN}✨ 部署指令執行完畢！${NC}"
echo -e "${YELLOW}請確認上方列表中 agent_app 與 agent_admin 是否顯示為 (Up)。${NC}"

echo -e "\n${BLUE}🖥️  寶塔面板配置指引：${NC}"
echo -e "1. 建立站點: ${BLUE}${DOMAIN}${NC}"
echo -e "2. 反向代理 (前台): 代理至 ${GREEN}http://127.0.0.1:1235${NC}"
echo -e "3. 反向代理 (後台): 代理至 ${GREEN}http://127.0.0.1:8001${NC}"
echo -e "4. 安全: 開放 ${YELLOW}1235, 8001, 3306(如需外部連接)${NC} 端口。"
echo -e "${BLUE}==========================================${NC}"
echo -e "${GREEN}技術支持 Telegram: @ios_vip8888${NC}"
