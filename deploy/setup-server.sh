#!/usr/bin/env bash
# Первичная установка ip-checker на сервер.
#   sudo bash deploy/setup-server.sh
# Запускать из распакованной папки репозитория. Скрипт можно запускать повторно.
#
# Что делает:
#  1. создаёт пользователя для GitHub Actions (без пароля, только вход по ключу, в группе docker)
#  2. генерирует ему SSH-ключ и выводит значения для секретов репозитория
#  3. кладёт приложение в /opt/ip-checker и создаёт .env
#  4. настраивает nginx (с реальным IP из Cloudflare) и запускает контейнер
#  5. по желанию выпускает сертификат certbot
#
# Не трогает: ufw/файрвол, sshd_config, другие сайты nginx.

set -euo pipefail

DEPLOY_USER="${DEPLOY_USER:-gh-ipchecker}"
APP_DIR="${APP_DIR:-/opt/ip-checker}"
DOMAIN="${DOMAIN:-ip.sdsds.top}"
V4_DOMAIN="${V4_DOMAIN:-ipv4.sdsds.top}"
V6_DOMAIN="${V6_DOMAIN:-ipv6.sdsds.top}"
SRC_DIR="$(cd "$(dirname "$0")/.." && pwd)"
SITE_CONF="/etc/nginx/sites-available/$DOMAIN"
SITE_LINK="/etc/nginx/sites-enabled/$DOMAIN"

c() { printf '\033[1;36m==> %s\033[0m\n' "$*"; }
warn() { printf '\033[1;33m!! %s\033[0m\n' "$*"; }
die() { printf '\033[1;31mОшибка: %s\033[0m\n' "$*" >&2; exit 1; }
ask() { local a; read -r -p "$1 " a </dev/tty || true; printf '%s' "$a"; }

[ "$(id -u)" -eq 0 ] || die "запустите через sudo"
[ -f "$SRC_DIR/server.js" ] || die "не найден server.js — запускайте из папки репозитория"
command -v docker >/dev/null || die "docker не установлен"
docker compose version >/dev/null 2>&1 || die "нет docker compose (плагин v2)"
command -v nginx >/dev/null || die "nginx не установлен"

# ---------- 1. Пользователь для деплоя ----------
c "Пользователь $DEPLOY_USER"
if id "$DEPLOY_USER" >/dev/null 2>&1; then
  echo "уже существует"
else
  useradd --create-home --shell /bin/bash --user-group "$DEPLOY_USER"
  passwd -l "$DEPLOY_USER" >/dev/null   # вход по паролю невозможен, только по ключу
  echo "создан"
fi
usermod -aG docker "$DEPLOY_USER"

# Если в sshd ограничен список пользователей — сами не меняем, только предупреждаем
ALLOW_USERS="$(sshd -T 2>/dev/null | awk '/^allowusers /{ $1=""; print }' | xargs || true)"
if [ -n "$ALLOW_USERS" ] && ! grep -qw "$DEPLOY_USER" <<<"$ALLOW_USERS"; then
  warn "в sshd задан AllowUsers ($ALLOW_USERS) — добавьте туда $DEPLOY_USER, иначе GitHub не войдёт"
fi
ALLOW_GROUPS="$(sshd -T 2>/dev/null | awk '/^allowgroups /{ $1=""; print }' | xargs || true)"
if [ -n "$ALLOW_GROUPS" ]; then
  warn "в sshd задан AllowGroups ($ALLOW_GROUPS) — убедитесь, что $DEPLOY_USER в одной из этих групп"
fi

# ---------- 2. SSH-ключ ----------
SSH_DIR="/home/$DEPLOY_USER/.ssh"
KEY="$SSH_DIR/github_actions"
install -d -m 700 -o "$DEPLOY_USER" -g "$DEPLOY_USER" "$SSH_DIR"
NEW_KEY=0
if [ ! -f "$KEY" ]; then
  c "Генерирую SSH-ключ для GitHub Actions"
  ssh-keygen -q -t ed25519 -N "" -C "github-actions@ip-checker" -f "$KEY"
  NEW_KEY=1
fi
PUB="$(cat "$KEY.pub")"
touch "$SSH_DIR/authorized_keys"
if ! grep -qF "$PUB" "$SSH_DIR/authorized_keys"; then
  echo "no-port-forwarding,no-agent-forwarding,no-X11-forwarding $PUB" >> "$SSH_DIR/authorized_keys"
fi
chown -R "$DEPLOY_USER:$DEPLOY_USER" "$SSH_DIR"
chmod 600 "$SSH_DIR/authorized_keys" "$KEY"

# ---------- 3. Приложение ----------
c "Файлы приложения → $APP_DIR"
install -d -o "$DEPLOY_USER" -g "$DEPLOY_USER" "$APP_DIR"
cp -r "$SRC_DIR"/{server.js,public,Dockerfile,docker-compose.yml,deploy} "$APP_DIR/"

USE_OWN=n
if ip -6 addr show scope global 2>/dev/null | grep -q inet6; then
  USE_OWN="$(ask "На сервере есть IPv6. Определять IPv4/IPv6 через свои поддомены $V4_DOMAIN и $V6_DOMAIN вместо ipify? [Y/n]")"
  [[ "$USE_OWN" =~ ^[Nn] ]] && USE_OWN=n || USE_OWN=y
else
  echo "IPv6 на сервере нет — IPv4/IPv6 посетителя будут определяться через ipify"
fi

if [ ! -f "$APP_DIR/.env" ]; then
  TOKEN="$(ask "Токен ipinfo (https://ipinfo.io/account/token, Enter — без токена):")"
  {
    echo "IPINFO_TOKEN=$TOKEN"
    if [ "$USE_OWN" = y ]; then
      echo "V4_URL=https://$V4_DOMAIN/raw.json"
      echo "V6_URL=https://$V6_DOMAIN/raw.json"
    fi
  } > "$APP_DIR/.env"
else
  echo ".env уже есть — не трогаю"
fi
chown -R "$DEPLOY_USER:$DEPLOY_USER" "$APP_DIR"
chmod 600 "$APP_DIR/.env"

if ss -ltn 2>/dev/null | grep -q '127.0.0.1:3077 ' && ! docker ps --format '{{.Names}}' | grep -qx ip-checker; then
  die "порт 3077 занят другим процессом"
fi

# ---------- 4. nginx ----------
c "nginx"
NO_RELOAD=1 sh "$APP_DIR/deploy/update-cloudflare-ips.sh" >/dev/null || die "не удалось получить адреса Cloudflare"

NAMES="$DOMAIN"
[ "$USE_OWN" = y ] && NAMES="$DOMAIN $V4_DOMAIN $V6_DOMAIN"
if [ -f "$SITE_CONF" ] && grep -q 'managed by Certbot' "$SITE_CONF"; then
  echo "$SITE_CONF уже настроен certbot — не перезаписываю"
else
  sed "s/server_name $DOMAIN;/server_name $NAMES;/" "$APP_DIR/deploy/nginx-ip.sdsds.top.conf" > "$SITE_CONF"
fi
ln -sfn "$SITE_CONF" "$SITE_LINK"
if ! nginx -t 2>/tmp/ip-checker-nginx.log; then
  rm -f "$SITE_LINK"          # не оставляем nginx в сломанном состоянии
  cat /tmp/ip-checker-nginx.log
  die "nginx -t не прошёл, сайт отключён — остальные сайты не затронуты"
fi
systemctl reload nginx

# ---------- Контейнер ----------
c "Запуск контейнера"
(cd "$APP_DIR" && docker compose up -d --build)
for _ in 1 2 3 4 5 6 7 8 9 10; do
  curl -fsS http://127.0.0.1:3077/healthz >/dev/null 2>&1 && break
  sleep 1
done
curl -fsS http://127.0.0.1:3077/healthz >/dev/null && echo "ip-checker работает" || warn "контейнер не отвечает: docker logs ip-checker"

# ---------- 5. Сертификат ----------
if command -v certbot >/dev/null; then
  CERT_ARGS=(-d "$DOMAIN")
  [ "$USE_OWN" = y ] && CERT_ARGS+=(-d "$V4_DOMAIN" -d "$V6_DOMAIN")
  if [[ "$(ask "Выпустить сертификат certbot для: $NAMES ? (DNS уже должен указывать сюда) [y/N]")" =~ ^[Yy] ]]; then
    certbot --nginx "${CERT_ARGS[@]}" || warn "certbot не прошёл — повторите позже: certbot --nginx ${CERT_ARGS[*]}"
  fi
else
  warn "certbot не установлен — HTTPS настройте сами"
fi

# ---------- Итог ----------
SSH_PORT="$(sshd -T 2>/dev/null | awk '/^port /{print $2; exit}')"
SSH_PORT="${SSH_PORT:-22}"
HOST_IP="$(curl -4 -fsS --max-time 5 https://api.ipify.org 2>/dev/null || hostname -I | awk '{print $1}')"

echo
c "Готово. Секреты для GitHub → Settings → Secrets and variables → Actions:"
echo "  SSH_HOST = $HOST_IP"
echo "  SSH_PORT = $SSH_PORT"
echo "  SSH_USER = $DEPLOY_USER"
echo "  SSH_KEY  = весь текст ниже, включая строки BEGIN/END:"
echo "-----------------------------------------------------------------"
cat "$KEY"
echo "-----------------------------------------------------------------"
[ "$NEW_KEY" = 1 ] || echo "(ключ создан при прошлом запуске)"
echo "Ключ лежит в $KEY. После того как добавите его в GitHub, его можно удалить:"
echo "  sudo rm $KEY   (вход продолжит работать — нужен только authorized_keys)"
if [ "$USE_OWN" = y ]; then
  echo
  echo "DNS в Cloudflare: $V4_DOMAIN — только A, $V6_DOMAIN — только AAAA, обе с серым облаком (DNS only)."
fi
