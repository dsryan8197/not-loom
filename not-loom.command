#!/bin/sh
# Double-click this in Finder to start not-loom and open it in your browser.
cd "$(dirname "$0")" || exit 1
if command -v node >/dev/null 2>&1; then
  exec node server.js
fi
echo "Node.js not found, falling back to Python."
(sleep 1 && open "http://127.0.0.1:4321") &
exec python3 -m http.server 4321 --bind 127.0.0.1 --directory public
