# ip-checker

Сайт **ip.sdsds.top** — показывает ваш IP-адрес и страну (данные ipinfo.io), плюс город, провайдера и часовой пояс. Можно проверить любой другой IP.

- `GET /` — страница
- Два блока: IPv4 и IPv6 (через ipify, IPv6 на сервере не нужен), отметка какой протокол основной
- `GET /api/ip` — JSON о вашем IP, `GET /api/ip?ip=8.8.8.8` — о любом
- `GET /raw` — только IP текстом: `curl ip.sdsds.top/raw`

Node 20 без зависимостей, Docker, порт `127.0.0.1:3077` за nginx. Запросы к ipinfo идут с сервера (токен не светится, ответы кешируются на 10 минут, лимит 60 запросов/мин с IP).

## Первая установка на VPS

```bash
unzip ip-checker-main.zip && cd ip-checker-main
sudo bash deploy/setup-server.sh
```

Скрипт:
- создаёт пользователя `gh-ipchecker` для GitHub Actions (без пароля, вход только по ключу, в группе docker),
  генерирует ему SSH-ключ и в конце печатает готовые значения `SSH_HOST`, `SSH_PORT`, `SSH_USER`, `SSH_KEY`;
- кладёт приложение в `/opt/ip-checker`, спрашивает токен ipinfo и создаёт `.env`;
- настраивает nginx (реальный IP посетителя из Cloudflare) и запускает контейнер;
- по желанию выпускает сертификат certbot.

Файрвол, `sshd_config` и другие сайты не трогает. Если в sshd задан `AllowUsers`, предупредит —
нового пользователя туда нужно добавить вручную. Запускать можно повторно: уже созданное не ломается.
Имена можно переопределить: `sudo DEPLOY_USER=... DOMAIN=... bash deploy/setup-server.sh`.

DNS: A-запись `ip.sdsds.top` → сервер, проксирование Cloudflare можно включить.
В Cloudflare: SSL/TLS → **Full (strict)**.

IPv4 и IPv6 посетителя:
- если у сервера нет IPv6 — через `api.ipify.org` / `api6.ipify.org`;
- если есть — скрипт предложит свои поддомены: `ipv4.sdsds.top` (только A) и `ipv6.sdsds.top` (только AAAA),
  обе записи с серым облаком (DNS only).

## Обновление

GitHub → Actions → **Deploy** → Run workflow. Нужные секреты репозитория:
`SSH_HOST`, `SSH_PORT`, `SSH_USER`, `SSH_KEY` — их печатает `setup-server.sh`.
