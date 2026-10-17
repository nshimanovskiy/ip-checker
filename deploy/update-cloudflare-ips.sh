#!/bin/sh
# Создаёт /etc/nginx/snippets/cloudflare-realip.conf с актуальными адресами Cloudflare.
# Запуск: sudo sh deploy/update-cloudflare-ips.sh  (можно повесить в cron раз в неделю)
set -e
OUT=/etc/nginx/snippets/cloudflare-realip.conf
TMP=$(mktemp)
{
  echo "# Сгенерировано $(date -u +%F) из https://www.cloudflare.com/ips/"
  for u in https://www.cloudflare.com/ips-v4 https://www.cloudflare.com/ips-v6; do
    curl -fsS "$u" | grep -E '^[0-9a-fA-F:.]+/[0-9]+$' | sed 's/.*/set_real_ip_from &;/'
  done
  echo "real_ip_header CF-Connecting-IP;"
} > "$TMP"
grep -q set_real_ip_from "$TMP" || { echo "Не удалось получить список Cloudflare"; rm -f "$TMP"; exit 1; }
mkdir -p /etc/nginx/snippets
mv "$TMP" "$OUT" && chmod 644 "$OUT"
[ "${NO_RELOAD:-}" = 1 ] || { nginx -t && systemctl reload nginx; }
echo "OK: $OUT"
