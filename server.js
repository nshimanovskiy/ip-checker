'use strict';

const http = require('http');
const fs = require('fs');
const path = require('path');
const net = require('net');

const PORT = Number(process.env.PORT || 3077);
const HOST = process.env.HOST || '0.0.0.0';
const TOKEN = process.env.IPINFO_TOKEN || '';
const CACHE_TTL_MS = 10 * 60 * 1000;
const CACHE_MAX = 5000;
const RATE_LIMIT = 90; // запросов к API в минуту с одного IP

// Основной домен и два вспомогательных: только A-запись (IPv4) и только AAAA (IPv6)
const PUBLIC_HOST = process.env.PUBLIC_HOST || 'ip.sdsds.top';
const V4_HOST = process.env.V4_HOST || 'ipv4.sdsds.top';
const V6_HOST = process.env.V6_HOST || 'ipv6.sdsds.top';
const ALLOWED_ORIGINS = new Set([PUBLIC_HOST, V4_HOST, V6_HOST].map(h => `https://${h}`));

const INDEX_HTML = Buffer.from(
  fs.readFileSync(path.join(__dirname, 'public', 'index.html'), 'utf8')
    .replaceAll('__V4_HOST__', V4_HOST)
    .replaceAll('__V6_HOST__', V6_HOST)
);
const FAVICON = fs.readFileSync(path.join(__dirname, 'public', 'favicon.svg'));

const cache = new Map();
const hits = new Map();

setInterval(() => {
  hits.clear();
  const now = Date.now();
  for (const [k, v] of cache) if (v.exp < now) cache.delete(k);
}, 60 * 1000).unref();

function clientIp(req) {
  const real = req.headers['x-real-ip'];
  if (real && net.isIP(real.trim())) return real.trim();
  const xff = req.headers['x-forwarded-for'];
  if (xff) {
    const first = xff.split(',')[0].trim();
    if (net.isIP(first)) return first;
  }
  let ip = req.socket.remoteAddress || '';
  if (ip.startsWith('::ffff:')) ip = ip.slice(7);
  return ip;
}

async function lookup(ip) {
  const cached = cache.get(ip);
  if (cached && cached.exp > Date.now()) return cached.data;

  const url = `https://ipinfo.io/${encodeURIComponent(ip)}/json` + (TOKEN ? `?token=${TOKEN}` : '');
  const res = await fetch(url, {
    headers: { Accept: 'application/json' },
    signal: AbortSignal.timeout(5000),
  });
  if (!res.ok) throw new Error(`ipinfo HTTP ${res.status}`);
  const j = await res.json();

  const data = {
    ip: j.ip || ip,
    bogon: Boolean(j.bogon),
    country: j.country || null,
    region: j.region || null,
    city: j.city || null,
    org: j.org || null,
    timezone: j.timezone || null,
    hostname: j.hostname || null,
  };

  if (cache.size >= CACHE_MAX) cache.delete(cache.keys().next().value);
  cache.set(ip, { data, exp: Date.now() + CACHE_TTL_MS });
  return data;
}

function send(res, status, body, type, extra = {}) {
  res.writeHead(status, {
    ...extra,
    'Content-Type': type,
    'X-Content-Type-Options': 'nosniff',
    'Referrer-Policy': 'no-referrer',
    'X-Frame-Options': 'DENY',
    'Content-Security-Policy':
      `default-src 'none'; script-src 'self' 'unsafe-inline'; style-src 'unsafe-inline'; img-src 'self' data:; connect-src 'self' https://${V4_HOST} https://${V6_HOST}; base-uri 'none'; form-action 'none'`,
    'Cache-Control': type.startsWith('application/json') ? 'no-store' : 'public, max-age=300',
  });
  res.end(body);
}

function json(res, status, obj, extra) {
  send(res, status, JSON.stringify(obj), 'application/json; charset=utf-8', extra);
}

function cors(req) {
  const origin = req.headers.origin;
  if (origin && ALLOWED_ORIGINS.has(origin)) {
    return { 'Access-Control-Allow-Origin': origin, Vary: 'Origin' };
  }
  return { Vary: 'Origin' };
}

const server = http.createServer(async (req, res) => {
  const url = new URL(req.url, 'http://localhost');
  const ip = clientIp(req);

  if (req.method !== 'GET' && req.method !== 'HEAD') {
    return json(res, 405, { error: 'method_not_allowed' });
  }

  if (url.pathname === '/' || url.pathname === '/index.html') {
    return send(res, 200, INDEX_HTML, 'text/html; charset=utf-8');
  }
  if (url.pathname === '/favicon.svg' || url.pathname === '/favicon.ico') {
    return send(res, 200, FAVICON, 'image/svg+xml');
  }

  // Только IP — удобно для curl: curl ip.sdsds.top/raw
  if (url.pathname === '/raw') {
    return send(res, 200, ip + '\n', 'text/plain; charset=utf-8');
  }

  if (url.pathname === '/api/ip') {
    const h = cors(req);
    const n = (hits.get(ip) || 0) + 1;
    hits.set(ip, n);
    if (n > RATE_LIMIT) return json(res, 429, { error: 'too_many_requests' }, h);

    const target = (url.searchParams.get('ip') || '').trim() || ip;
    if (!net.isIP(target)) return json(res, 400, { error: 'invalid_ip' }, h);

    try {
      const data = await lookup(target);
      return json(res, 200, { ...data, family: net.isIP(target), self: target === ip }, h);
    } catch (e) {
      console.error('lookup failed', target, e.message);
      return json(res, 502, { error: 'lookup_failed', ip: target, family: net.isIP(target) }, h);
    }
  }

  if (url.pathname === '/healthz') return send(res, 200, 'ok', 'text/plain');

  json(res, 404, { error: 'not_found' });
});

server.listen(PORT, HOST, () => {
  console.log(`ip-checker listening on ${HOST}:${PORT}${TOKEN ? '' : ' (no IPINFO_TOKEN set)'}`);
});
