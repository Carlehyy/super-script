#!/bin/bash
set -e

# ============================================================
#  LiteLLM 一键部署脚本
#  - 检查 Docker 环境
#  - 创建配置文件到 ~/litellm/
#  - 启动 LiteLLM + PostgreSQL
# ============================================================

GREEN='\033[0;32m'
RED='\033[0;31m'
YELLOW='\033[1;33m'
NC='\033[0m'

INSTALL_DIR="$HOME/litellm"

info()  { echo -e "${GREEN}[✓]${NC} $1"; }
warn()  { echo -e "${YELLOW}[!]${NC} $1"; }
error() { echo -e "${RED}[✗]${NC} $1"; }

echo ""
echo "========================================="
echo "    LiteLLM 一键部署脚本"
echo "========================================="
echo ""

# ----------------------------------------------------------
# 1. 检查 Docker 是否安装
# ----------------------------------------------------------
echo ">>> 检查 Docker 环境..."

if ! command -v docker &> /dev/null; then
    error "Docker 未安装"
    echo "  请先安装 Docker: https://docs.docker.com/engine/install/ubuntu/"
    exit 1
fi
info "Docker 已安装: $(docker --version)"

# 检查 Docker 服务是否运行
if ! docker info &> /dev/null; then
    error "Docker 服务未运行，或当前用户无权限"
    echo "  尝试执行: sudo systemctl start docker"
    echo "  或将用户加入 docker 组: sudo usermod -aG docker \$USER"
    exit 1
fi
info "Docker 服务运行正常"

# 检查 docker compose
if docker compose version &> /dev/null; then
    COMPOSE_CMD="docker compose"
    info "Docker Compose (V2) 可用: $(docker compose version --short)"
elif command -v docker-compose &> /dev/null; then
    COMPOSE_CMD="docker-compose"
    info "Docker Compose (V1) 可用: $(docker-compose --version)"
else
    error "Docker Compose 未安装"
    echo "  请先安装: https://docs.docker.com/compose/install/"
    exit 1
fi

# ----------------------------------------------------------
# 2. 创建目录
# ----------------------------------------------------------
echo ""
echo ">>> 创建部署目录: $INSTALL_DIR"

mkdir -p "$INSTALL_DIR"
info "目录就绪: $INSTALL_DIR"

# ----------------------------------------------------------
# 3. 生成 docker-compose.yml
# ----------------------------------------------------------
echo ""
echo ">>> 生成配置文件..."

cat > "$INSTALL_DIR/docker-compose.yml" << 'EOF'
services:
  litellm:
    image: docker.litellm.ai/berriai/litellm:main-stable
    container_name: litellm
    restart: always
    ports:
      - "4000:4000"
    volumes:
      - ./config.yaml:/app/config.yaml
    command:
      - "--config=/app/config.yaml"
    environment:
      DATABASE_URL: "postgresql://llmproxy:dbpassword9090@db:5432/litellm"
      STORE_MODEL_IN_DB: "True"
    env_file:
      - .env
    depends_on:
      db:
        condition: service_healthy
    healthcheck:
      test:
        - CMD-SHELL
        - python3 -c "import urllib.request; urllib.request.urlopen('http://localhost:4000/health/liveliness')"
      interval: 30s
      timeout: 10s
      retries: 3
      start_period: 40s

  db:
    image: postgres:16
    container_name: litellm_db
    restart: always
    environment:
      POSTGRES_DB: litellm
      POSTGRES_USER: llmproxy
      POSTGRES_PASSWORD: dbpassword9090
    ports:
      - "5432:5432"
    volumes:
      - ./postgres_data:/var/lib/postgresql/data
    healthcheck:
      test: ["CMD-SHELL", "pg_isready -d litellm -U llmproxy"]
      interval: 1s
      timeout: 5s
      retries: 10
EOF
info "docker-compose.yml 已生成"

# ----------------------------------------------------------
# 4. 生成 config.yaml
# ----------------------------------------------------------
cat > "$INSTALL_DIR/config.yaml" << 'EOF'
model_list:
  - model_name: gpt-4o
    litellm_params:
      model: gpt-4o
      api_key: os.environ/OPENAI_API_KEY

general_settings:
  master_key: sk-1234
  database_url: "postgresql://llmproxy:dbpassword9090@db:5432/litellm"
EOF
info "config.yaml 已生成"

# ----------------------------------------------------------
# 5. 生成 .env（不覆盖已有文件）
# ----------------------------------------------------------
if [ -f "$INSTALL_DIR/.env" ]; then
    warn ".env 文件已存在，跳过生成（避免覆盖你的密钥配置）"
else
    cat > "$INSTALL_DIR/.env" << 'EOF'
LITELLM_MASTER_KEY="sk-1234"
LITELLM_SALT_KEY="sk-1234"

# 在下方添加你的 API Key，例如：
# OPENAI_API_KEY=sk-xxxxxxxxxxxxxxxx
# ANTHROPIC_API_KEY=sk-ant-xxxxxxxxxxxxxxxx
EOF
    info ".env 已生成"
fi

# ----------------------------------------------------------
# 6. 启动服务
# ----------------------------------------------------------
echo ""
echo ">>> 启动 LiteLLM 服务..."

cd "$INSTALL_DIR"
$COMPOSE_CMD up -d

# ----------------------------------------------------------
# 7. 等待服务就绪
# ----------------------------------------------------------
echo ""
echo ">>> 等待服务启动（最多 60 秒）..."

for i in $(seq 1 60); do
    if curl -s -o /dev/null -w "%{http_code}" http://localhost:4000/health/liveliness 2>/dev/null | grep -q "200"; then
        echo ""
        info "LiteLLM 已成功启动！"
        break
    fi
    if [ "$i" -eq 60 ]; then
        echo ""
        warn "等待超时，服务可能仍在启动中"
        echo "  请手动检查: $COMPOSE_CMD -f $INSTALL_DIR/docker-compose.yml logs -f"
    fi
    printf "."
    sleep 1
done

# ----------------------------------------------------------
# 8. 打印信息
# ----------------------------------------------------------
SERVER_IP=$(hostname -I | awk '{print $1}')

echo ""
echo "========================================="
echo "    部署完成"
echo "========================================="
echo ""
echo "  代理地址:  http://${SERVER_IP}:4000"
echo "  管理界面:  http://${SERVER_IP}:4000/ui"
echo "  Master Key: sk-1234"
echo ""
echo "  部署目录:  $INSTALL_DIR"
echo "  数据目录:  $INSTALL_DIR/postgres_data/"
echo ""
echo "  常用命令:"
echo "    查看日志:  cd $INSTALL_DIR && $COMPOSE_CMD logs -f"
echo "    停止服务:  cd $INSTALL_DIR && $COMPOSE_CMD down"
echo "    重启服务:  cd $INSTALL_DIR && $COMPOSE_CMD restart"
echo ""
echo -e "  ${YELLOW}提示: 请编辑 $INSTALL_DIR/.env 添加你的 API Key${NC}"
echo -e "  ${YELLOW}提示: 生产环境请修改 LITELLM_MASTER_KEY 和 LITELLM_SALT_KEY${NC}"
echo ""
