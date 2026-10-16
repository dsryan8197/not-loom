#!/usr/bin/env node
// Zero-dependency static server for not-loom.
// Browsers only allow camera, mic and screen capture on https:// or localhost,
// so the app is served from 127.0.0.1 instead of being opened as a file.
const http = require('http');
const fs = require('fs');
const path = require('path');
const { exec } = require('child_process');

const PORT = Number(process.env.PORT) || 4321;
const ROOT = path.join(__dirname, 'public');
const URL_ = `http://127.0.0.1:${PORT}`;
const TYPES = {
  '.html': 'text/html; charset=utf-8',
  '.js': 'text/javascript; charset=utf-8',
  '.css': 'text/css; charset=utf-8',
  '.svg': 'image/svg+xml',
  '.png': 'image/png',
};

function openBrowser() {
  if (process.env.NO_OPEN) return;
  const cmd = process.platform === 'darwin' ? `open "${URL_}"`
    : process.platform === 'win32' ? `start "" "${URL_}"`
    : `xdg-open "${URL_}"`;
  exec(cmd, () => {});
}

const server = http.createServer((req, res) => {
  const pathname = decodeURIComponent(new URL(req.url, URL_).pathname);
  const file = path.join(ROOT, pathname === '/' ? 'index.html' : pathname);
  if (!file.startsWith(ROOT + path.sep)) {
    res.writeHead(403).end();
    return;
  }
  fs.readFile(file, (err, data) => {
    if (err) {
      res.writeHead(404).end('Not found');
      return;
    }
    res.writeHead(200, {
      'Content-Type': TYPES[path.extname(file)] || 'application/octet-stream',
      'Cache-Control': 'no-store',
    });
    res.end(data);
  });
});

server.on('error', (err) => {
  if (err.code === 'EADDRINUSE') {
    console.log(`not-loom already seems to be running at ${URL_}. Opening it.`);
    openBrowser();
    return;
  }
  throw err;
});

server.listen(PORT, '127.0.0.1', () => {
  console.log(`not-loom running at ${URL_}  (Ctrl+C to quit)`);
  openBrowser();
});
