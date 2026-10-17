# ip-checker

Сайт **ip.sdsds.top** — показывает ваш IP-адрес и страну (данные ipinfo.io), плюс город, провайдера и часовой пояс. Можно проверить любой другой IP.

- `GET /` — страница
- Два блока: IPv4 и IPv6 (через ipify, IPv6 на сервере не нужен), отметка какой протокол основной
- `GET /api/ip` — JSON о вашем IP, `GET /api/ip?ip=8.8.8.8` — о любом
- `GET /raw` — только IP текстом: `curl ip.sdsds.top/raw`

Node 20 без зависимостей, Docker, порт `127.0.0.1:3077` за nginx. Запросы к ipinfo идут с сервера (токен не светится, ответы кешируются на 10 минут, лимит 60 запросов/мин с IP).

## Первая установка на VPS

```bash
sudo mkdir -p /opt/ip-checker && sudo chown $USER /opt/ip-checker
cd /opt/ip-checker
echo "IPINFO_TOKEN=ваш_токен" > .env        # токен: https://ipinfo.io/account/token

# nginx (сайт за Cloudflare — сначала список адресов CF)
sudo sh deploy/update-cloudflare-ips.sh
sudo cp deploy/nginx-ip.sdsds.top.conf /etc/nginx/sites-available/ip.sdsds.top   # файл из репо
sudo ln -s /etc/nginx/sites-available/ip.sdsds.top /etc/nginx/sites-enabled/
sudo nginx -t && sudo systemctl reload nginx
sudo certbot --nginx -d ip.sdsds.top
```

DNS: A-запись `ip.sdsds.top` → сервер, проксирование Cloudflare можно включить.

IPv4 и IPv6 браузер узнаёт через `api.ipify.org` (только IPv4) и `api6.ipify.org` (только IPv6),
страну — через этот сервер. IPv6 на сервере не нужен. Свои адреса можно задать в `.env`:
`V4_URL=https://ipv4.sdsds.top/raw.json`, `V6_URL=https://ipv6.sdsds.top/raw.json`
(поддомены только с A / только с AAAA и без прокси Cloudflare).
В Cloudflare: SSL/TLS → режим **Full (strict)** (с Flexible будет бесконечный редирект после certbot).
Если certbot не проходит из-за прокси — временно выключите облако на время выпуска сертификата
или поставьте Cloudflare Origin Certificate.

## Обновление

GitHub → Actions → **Deploy** → Run workflow. Нужные секреты репозитория:
`SSH_HOST`, `SSH_PORT`, `SSH_USER`, `SSH_KEY` (пользователь не root, с доступом к docker).
