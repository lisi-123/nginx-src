#!/bin/bash
set -e

# -----------------------------
# 一键安装 nginx + acme.sh 自动签证书
# 自动生成邮箱注册 ZeroSSL
# -----------------------------

# 检查是否 root
if [ "$EUID" -ne 0 ]; then
  echo "请使用 root 用户执行此脚本"
  exit 1
fi

# 安装 nginx
if ! command -v nginx >/dev/null 2>&1; then
    echo "检测到 Nginx 未安装，正在安装..."
    apt update -y
    apt install nginx curl socat -y
else
    echo "Nginx 已安装"
fi

# 创建默认站点
NGINX_DEFAULT="/etc/nginx/sites-available/default"
if [ ! -f "$NGINX_DEFAULT.bak" ]; then
    cp $NGINX_DEFAULT $NGINX_DEFAULT.bak
fi

cat > $NGINX_DEFAULT <<EOF
server {
    listen 80 default_server;
    listen [::]:80 default_server;

    server_name _;

    root /var/www/html;
    index index.html index.htm index.nginx-debian.html;

    location / {
        try_files \$uri \$uri/ =404;
    }
}
EOF

systemctl restart nginx

# 安装 acme.sh
if [ ! -f ~/.acme.sh/acme.sh ]; then
    echo "安装 acme.sh..."
    curl https://get.acme.sh | sh
    ~/.acme.sh/acme.sh --upgrade --auto-upgrade
else
    echo "acme.sh 已安装"
fi

# 自动生成随机邮箱注册 ZeroSSL
ACME_EMAIL="acme_$(date +%s)_$RANDOM@gmail.com"
~/.acme.sh/acme.sh --register-account -m "$ACME_EMAIL" || true

# 交互式输入域名
echo
read -p "请输入需要签证书的域名（如 example.xyz）: " DOMAIN < /dev/tty
if [ -z "$DOMAIN" ]; then
    echo "域名不能为空"
    exit 1
fi

# 创建 ACME webroot
mkdir -p /var/www/html/.well-known/acme-challenge

# 签发证书
echo "正在签发证书..."
~/.acme.sh/acme.sh --issue --webroot /var/www/html -d $DOMAIN --force

# 安装证书
CERT_DIR="/etc/ssl/$DOMAIN"
mkdir -p $CERT_DIR

~/.acme.sh/acme.sh --install-cert -d $DOMAIN \
--key-file $CERT_DIR/$DOMAIN.key \
--fullchain-file $CERT_DIR/$DOMAIN.crt \
--reloadcmd "systemctl reload nginx"

# 配置 Nginx HTTPS
cat > $NGINX_DEFAULT <<EOF
server {
    listen 443 ssl http2;
    listen [::]:443 ssl http2;

    server_name $DOMAIN;

    root /var/www/html;
    index index.html index.htm index.nginx-debian.html;

    ssl_certificate $CERT_DIR/$DOMAIN.crt;
    ssl_certificate_key $CERT_DIR/$DOMAIN.key;

    location / {
        try_files \$uri \$uri/ =404;
    }
}

server {
    listen 80;
    listen [::]:80;
    server_name $DOMAIN;
    return 301 https://\$host\$request_uri;
}
EOF

# 测试并重载 nginx
nginx -t && systemctl reload nginx

echo "=============================="
echo "证书已签发并配置完成！"
echo "域名: https://$DOMAIN"
echo "默认 Nginx 页面可访问"
echo "配置文件路径：/etc/nginx/sites-available"
echo "=============================="
