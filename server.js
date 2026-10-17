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
const RATE_LIMIT = 60; // запросов к API в минуту с одного IP

const INDEX_HTML = fs.readFileSync(path.join(__dirname, 'public', 'index.html'));
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

function send(res, status, body, type) {
  res.writeHead(status, {
    'Content-Type': type,
    'X-Content-Type-Options': 'nosniff',
    'Referrer-Policy': 'no-referrer',
    'X-Frame-Options': 'DENY',
    'Content-Security-Policy':
      "default-src 'none'; script-src 'self' 'unsafe-inline'; style-src 'unsafe-inline'; img-src 'self' data:; connect-src 'self'; base-uri 'none'; form-action 'none'",
    'Cache-Control': type.startsWith('application/json') ? 'no-store' : 'public, max-age=300',
  });
  res.end(body);
}

function json(res, status, obj) {
  send(res, status, JSON.stringify(obj), 'application/json; charset=utf-8');
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
    const n = (hits.get(ip) || 0) + 1;
    hits.set(ip, n);
    if (n > RATE_LIMIT) return json(res, 429, { error: 'too_many_requests' });

    const target = (url.searchParams.get('ip') || '').trim() || ip;
    if (!net.isIP(target)) return json(res, 400, { error: 'invalid_ip' });

    try {
      const data = await lookup(target);
      return json(res, 200, { ...data, self: target === ip });
    } catch (e) {
      console.error('lookup failed', target, e.message);
      return json(res, 502, { error: 'lookup_failed', ip: target });
    }
  }

  if (url.pathname === '/healthz') return send(res, 200, 'ok', 'text/plain');

  json(res, 404, { error: 'not_found' });
});

server.listen(PORT, HOST, () => {
  console.log(`ip-checker listening on ${HOST}:${PORT}${TOKEN ? '' : ' (no IPINFO_TOKEN set)'}`);
});
