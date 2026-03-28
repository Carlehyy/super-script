#!/bin/bash
set -e

# ============================================================
#  Nginx Ignition 一键部署脚本
#  用法: chmod +x setup.sh && ./setup.sh
# ============================================================

INSTALL_DIR=~/nginx-ignition

# 如果已存在，提示确认
if [ -d "$INSTALL_DIR" ] && [ -f "$INSTALL_DIR/docker-compose.yml" ]; then
    echo "⚠️  检测到 $INSTALL_DIR 已存在部署文件。"
    read -p "是否覆盖配置并重新部署？数据库数据会保留。(y/N): " confirm
    if [ "$confirm" != "y" ] && [ "$confirm" != "Y" ]; then
        echo "已取消。"
        exit 0
    fi
fi

echo "🚀 开始部署 Nginx Ignition..."
echo ""

# 1. 创建目录
mkdir -p "$INSTALL_DIR/data/postgres"
cd "$INSTALL_DIR"

# 2. 生成随机密码
DB_PASSWORD=$(openssl rand -hex 16)
JWT_SECRET=$(openssl rand -hex 32)

# 3. 写入 docker-compose.yml
cat > docker-compose.yml << 'COMPOSE_EOF'
services:

  postgres:
    image: postgres:18-alpine
    container_name: nginx-ignition-postgres
    restart: unless-stopped
    environment:
      POSTGRES_DB: nginx_ignition
      POSTGRES_USER: nginx_ignition
      POSTGRES_PASSWORD: __DB_PASSWORD__
    volumes:
      - ./data/postgres:/var/lib/postgresql/data
    healthcheck:
      test: ["CMD-SHELL", "pg_isready -U nginx_ignition"]
      interval: 5s
      timeout: 5s
      retries: 3
    networks:
      - nginx-ignition-network

  nginx-ignition:
    image: dillmann/nginx-ignition:latest
    container_name: nginx-ignition-app
    restart: unless-stopped
    ports:
      - "8090:8090"
      - "80:80"
      - "443:443"
    environment:
      NGINX_IGNITION_DATABASE_DRIVER: postgres
      NGINX_IGNITION_DATABASE_HOST: postgres
      NGINX_IGNITION_DATABASE_PORT: 5432
      NGINX_IGNITION_DATABASE_NAME: nginx_ignition
      NGINX_IGNITION_DATABASE_SSL_MODE: disable
      NGINX_IGNITION_DATABASE_USERNAME: nginx_ignition
      NGINX_IGNITION_DATABASE_PASSWORD: __DB_PASSWORD__
      NGINX_IGNITION_SECURITY_JWT_SECRET: __JWT_SECRET__
    depends_on:
      postgres:
        condition: service_healthy
    healthcheck:
      test: ["CMD", "curl", "-f", "http://localhost:8090/api/health/liveness"]
      interval: 5s
      timeout: 5s
      retries: 3
    networks:
      - nginx-ignition-network

networks:
  nginx-ignition-network:
    driver: bridge
COMPOSE_EOF

# 4. 替换占位符为真实密码
sed -i "s|__DB_PASSWORD__|${DB_PASSWORD}|g" docker-compose.yml
sed -i "s|__JWT_SECRET__|${JWT_SECRET}|g" docker-compose.yml

# 5. 保存凭据到文件（仅自己可读）
cat > .credentials << EOF
# Nginx Ignition 凭据（请妥善保管）
# 生成时间: $(date '+%Y-%m-%d %H:%M:%S')

数据库密码: ${DB_PASSWORD}
JWT 密钥:   ${JWT_SECRET}
EOF
chmod 600 .credentials

# 6. 启动服务
echo "📦 拉取镜像并启动容器..."
docker compose up -d

# 7. 等待服务就绪
echo ""
echo "⏳ 等待服务启动..."
for i in $(seq 1 30); do
    if curl -sf http://localhost:8090/api/health/liveness > /dev/null 2>&1; then
        echo ""
        echo "============================================================"
        echo "✅ 部署完成！"
        echo ""
        echo "📂 安装目录:     $INSTALL_DIR"
        echo "📂 数据库存储:   $INSTALL_DIR/data/postgres"
        echo "🔑 凭据文件:     $INSTALL_DIR/.credentials"
        echo ""
        echo "🌐 管理面板:     http://$(hostname -I | awk '{print $1}'):8090"
        echo ""
        echo "下一步:"
        echo "  1. 浏览器访问上面的地址，创建管理员账户"
        echo "  2. 添加虚拟主机，配置你的子域名转发"
        echo "  3. 配好 admin.carleopoc.top 后可关闭 8090 端口"
        echo "============================================================"
        exit 0
    fi
    sleep 2
    printf "."
done

echo ""
echo "⚠️  服务还在启动中，请稍后手动检查: docker compose logs -f"
