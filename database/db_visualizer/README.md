# db_visualizer (Node)

This lightweight Node.js service provides a simple database viewer/API for PostgreSQL (and optional MySQL/SQLite/MongoDB if configured). It is bootstrapped by the database container's startup.sh.

How it starts:
- startup.sh exports PostgreSQL env vars to db_visualizer/postgres.env.
- It verifies Node/npm presence, then installs dependencies:
  - If package-lock.json exists, runs: npm ci --no-audit --no-fund
  - Otherwise, runs: npm install --no-audit --no-fund
- It verifies express resolves and then launches:
  node server.js --host 0.0.0.0

Manual start (optional):
- cd android-calendar-manager-217763-217772/database/db_visualizer
- npm ci (or npm install)
- source ./postgres.env
- node server.js --host 0.0.0.0

Notes:
- package.json includes "express": ^4.19.2 and "main": "server.js".
- If Node/npm are missing in the base image, startup.sh will warn and skip starting the service.
