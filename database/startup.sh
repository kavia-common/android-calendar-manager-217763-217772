#!/bin/bash

# Minimal PostgreSQL startup script with full paths + Node db_visualizer bootstrap
DB_NAME="myapp"
DB_USER="appuser"
DB_PASSWORD="dbuser123"
DB_PORT="5000"

# Optional: allow overriding Node version through env var (default to 18)
NODE_VERSION="${NODE_VERSION:-18}"

# Resolve script directory to ensure all relative paths are correct
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR"

echo "Starting PostgreSQL setup..."

# Ensure db_visualizer dir exists before writing files to it
DBV_DIR="${SCRIPT_DIR}/db_visualizer"
mkdir -p "${DBV_DIR}"

# If package.json is missing, create a minimal one with express dependency to avoid MODULE_NOT_FOUND
if [ ! -f "${DBV_DIR}/package.json" ]; then
  cat > "${DBV_DIR}/package.json" << 'JSON'
{
  "name": "simple-db-viewer",
  "version": "1.0.0",
  "description": "Simple database viewer for PostgreSQL, MySQL, SQLite, and MongoDB",
  "main": "server.js",
  "scripts": {
    "start": "node server.js --host 0.0.0.0",
    "dev": "nodemon server.js"
  },
  "dependencies": {
    "express": "^4.19.2",
    "pg": "^8.11.3",
    "mysql2": "^3.6.3",
    "sqlite3": "^5.1.6",
    "mongodb": "^6.2.0"
  },
  "devDependencies": {
    "nodemon": "^3.0.1"
  }
}
JSON
fi

# Find PostgreSQL version and set paths
PG_VERSION=$(ls /usr/lib/postgresql/ 2>/dev/null | head -1)
if [ -z "${PG_VERSION}" ]; then
  echo "ERROR: PostgreSQL binaries not found under /usr/lib/postgresql."
  echo "Please ensure the base image contains PostgreSQL or adjust paths accordingly."
  exit 1
fi
PG_BIN="/usr/lib/postgresql/${PG_VERSION}/bin"

echo "Found PostgreSQL version: ${PG_VERSION}"

# Check if PostgreSQL is already running on the specified port
if sudo -u postgres ${PG_BIN}/pg_isready -p ${DB_PORT} > /dev/null 2>&1; then
    echo "PostgreSQL is already running on port ${DB_PORT}!"
    echo "Database: ${DB_NAME}"
    echo "User: ${DB_USER}"
    echo "Port: ${DB_PORT}"
    echo ""
    echo "To connect to the database, use:"
    echo "psql -h localhost -U ${DB_USER} -d ${DB_NAME} -p ${DB_PORT}"
    
    # Check if connection info file exists
    if [ -f "${SCRIPT_DIR}/db_connection.txt" ]; then
        echo "Or use: $(cat "${SCRIPT_DIR}/db_connection.txt")"
    fi

    # Even if PostgreSQL is already running, ensure db_visualizer is bootstrapped
    # Later in script we'll call a function to install/start Node service if not running.
fi

# Also check if there's a PostgreSQL process running (in case pg_isready fails)
if pgrep -f "postgres.*-p ${DB_PORT}" > /dev/null 2>&1; then
    echo "Found existing PostgreSQL process on port ${DB_PORT}"
    echo "Attempting to verify connection..."
    
    # Try to connect and verify the database exists
    if sudo -u postgres ${PG_BIN}/psql -p ${DB_PORT} -d ${DB_NAME} -c '\q' 2>/dev/null; then
        echo "Database ${DB_NAME} is accessible."
    fi
fi

# Initialize PostgreSQL data directory if it doesn't exist
if [ ! -f "/var/lib/postgresql/data/PG_VERSION" ]; then
    echo "Initializing PostgreSQL..."
    sudo -u postgres ${PG_BIN}/initdb -D /var/lib/postgresql/data
fi

# Start PostgreSQL server in background if not already started
if ! sudo -u postgres ${PG_BIN}/pg_isready -p ${DB_PORT} > /dev/null 2>&1; then
  echo "Starting PostgreSQL server..."
  sudo -u postgres ${PG_BIN}/postgres -D /var/lib/postgresql/data -p ${DB_PORT} &
fi

# Wait for PostgreSQL to start
echo "Waiting for PostgreSQL to start..."
for i in {1..15}; do
    if sudo -u postgres ${PG_BIN}/pg_isready -p ${DB_PORT} > /dev/null 2>&1; then
        echo "PostgreSQL is ready!"
        break
    fi
    echo "Waiting... ($i/15)"
    sleep 2
done

# Create database and user
echo "Setting up database and user..."
sudo -u postgres ${PG_BIN}/createdb -p ${DB_PORT} ${DB_NAME} 2>/dev/null || echo "Database might already exist"

# Set up user and permissions with proper schema ownership
sudo -u postgres ${PG_BIN}/psql -p ${DB_PORT} -d postgres << EOF
-- Create user if doesn't exist
DO \$\$
BEGIN
    IF NOT EXISTS (SELECT FROM pg_catalog.pg_roles WHERE rolname = '${DB_USER}') THEN
        CREATE ROLE ${DB_USER} WITH LOGIN PASSWORD '${DB_PASSWORD}';
    END IF;
    ALTER ROLE ${DB_USER} WITH PASSWORD '${DB_PASSWORD}';
END
\$\$;

-- Grant database-level permissions
GRANT ALL PRIVILEGES ON DATABASE ${DB_NAME} TO ${DB_USER};

-- Connect to the specific database for schema-level permissions
\c ${DB_NAME}

-- For PostgreSQL 15+, we need to handle public schema permissions differently
-- First, grant usage on public schema
GRANT USAGE ON SCHEMA public TO ${DB_USER};

-- Grant CREATE permission on public schema
GRANT CREATE ON SCHEMA public TO ${DB_USER};

-- Make the user owner of all future objects they create in public schema
ALTER DEFAULT PRIVILEGES IN SCHEMA public GRANT ALL ON TABLES TO ${DB_USER};
ALTER DEFAULT PRIVILEGES IN SCHEMA public GRANT ALL ON SEQUENCES TO ${DB_USER};
ALTER DEFAULT PRIVILEGES IN SCHEMA public GRANT ALL ON FUNCTIONS TO ${DB_USER};
ALTER DEFAULT PRIVILEGES IN SCHEMA public GRANT ALL ON TYPES TO ${DB_USER};

-- Alternative: Grant all privileges on schema public to the user
GRANT ALL ON SCHEMA public TO ${DB_USER};

-- Ensure the user can work with any existing objects
GRANT ALL PRIVILEGES ON ALL TABLES IN SCHEMA public TO ${DB_USER};
GRANT ALL PRIVILEGES ON ALL SEQUENCES IN SCHEMA public TO ${DB_USER};
GRANT ALL PRIVILEGES ON ALL FUNCTIONS IN SCHEMA public TO ${DB_USER};
EOF

# Additionally, connect to the specific database to ensure permissions
sudo -u postgres ${PG_BIN}/psql -p ${DB_PORT} -d ${DB_NAME} << EOF
-- Double-check permissions are set correctly in the target database
GRANT ALL ON SCHEMA public TO ${DB_USER};
GRANT CREATE ON SCHEMA public TO ${DB_USER};

-- Show current permissions for debugging
\dn+ public
EOF

# Save connection command to a file
echo "psql postgresql://${DB_USER}:${DB_PASSWORD}@localhost:${DB_PORT}/${DB_NAME}" > "${SCRIPT_DIR}/db_connection.txt"
echo "Connection string saved to ${SCRIPT_DIR}/db_connection.txt"

# Save environment variables to a file within db_visualizer directory
cat > "${DBV_DIR}/postgres.env" << EOF
export POSTGRES_URL="postgresql://localhost:${DB_PORT}/${DB_NAME}"
export POSTGRES_USER="${DB_USER}"
export POSTGRES_PASSWORD="${DB_PASSWORD}"
export POSTGRES_DB="${DB_NAME}"
export POSTGRES_PORT="${DB_PORT}"
EOF

echo "PostgreSQL setup complete!"
echo "Database: ${DB_NAME}"
echo "User: ${DB_USER}"
echo "Port: ${DB_PORT}"
echo ""

echo "Environment variables saved to ${DBV_DIR}/postgres.env"
echo "To use with Node.js viewer, run: source ${DBV_DIR}/postgres.env"

echo "To connect to the database, use one of the following commands:"
echo "psql -h localhost -U ${DB_USER} -d ${DB_NAME} -p ${DB_PORT}"
echo "$(cat "${SCRIPT_DIR}/db_connection.txt")"

###############################################################################
# Bootstrap and start the db_visualizer Node service
###############################################################################

bootstrap_db_visualizer() {
  echo ""
  echo "Bootstrapping db_visualizer (Node.js) service..."

  # Detect Node/npm availability early
  if ! command -v node >/dev/null 2>&1 || ! command -v npm >/dev/null 2>&1; then
    echo "ERROR: Node.js and/or npm not found in the base image."
    echo "Please ensure the database image includes Node.js 18+ and npm."
    echo "For example, install Node 18.x in the image before running this script."
    return 1
  fi

  # Show versions for diagnostics
  echo "Node version: $(node -v 2>/dev/null || echo 'unknown')"
  echo "npm version: $(npm -v 2>/dev/null || echo 'unknown')"

  pushd "${DBV_DIR}" >/dev/null 2>&1 || {
    echo "ERROR: Could not access ${DBV_DIR}"
    return 1
  }

  # Ensure package.json has a proper start script and express dependency
  if ! grep -q '"start": "node server.js --host 0.0.0.0"' package.json 2>/dev/null; then
    echo "WARNING: Missing or incorrect start script. Patching package.json..."
    # naive patch: ensure scripts.start exists (fallback if structure changed)
    tmpfile="$(mktemp)"
    node -e "const fs=require('fs');const f='package.json';const p=JSON.parse(fs.readFileSync(f,'utf8'));p.scripts=p.scripts||{};p.scripts.start='node server.js --host 0.0.0.0';fs.writeFileSync(f, JSON.stringify(p,null,2));" || true
  fi

  if ! grep -q '"express"' package.json 2>/dev/null; then
    echo "WARNING: express dependency missing. Adding express@^4..."
    node -e "const fs=require('fs');const f='package.json';const p=JSON.parse(fs.readFileSync(f,'utf8'));p.dependencies=p.dependencies||{};p.dependencies.express='^4.19.2';fs.writeFileSync(f, JSON.stringify(p,null,2));" || true
  fi

  # Always start from a clean install to avoid stale/broken node_modules
  if [ -d "node_modules" ]; then
    echo "Removing stale node_modules to ensure clean install..."
    rm -rf node_modules
  fi

  # Prefer npm ci when lockfile exists
  if [ -f "package-lock.json" ]; then
    echo "Installing dependencies with npm ci..."
    if ! npm ci --no-audit --no-fund; then
      echo "npm ci failed, falling back to npm install..."
      if ! npm install --no-audit --no-fund; then
        echo "ERROR: npm dependency installation failed."
        popd >/dev/null 2>&1
        return 1
      fi
    fi
  else
    echo "Installing dependencies with npm install..."
    if ! npm install --no-audit --no-fund; then
      echo "ERROR: npm dependency installation failed."
      popd >/dev/null 2>&1
      return 1
    fi
  fi

  # Validate express resolution using a runtime require() test
  if ! node -e "require('express'); console.log('express-ok')" >/dev/null 2>&1; then
    echo "Express failed to resolve after install. Capturing diagnostics..."
    echo "npm -v: $(npm -v 2>/dev/null || echo 'unknown')"
    echo "package.json:"
    cat package.json || true
    echo "Attempting explicit install: npm install express@^4 ..."
    if ! npm install express@^4 --no-audit --no-fund; then
      echo "ERROR: explicit express install failed."
      popd >/dev/null 2>&1
      return 1
    fi

    # Retry express resolution
    if ! node -e "require('express'); console.log('express-ok')" >/dev/null 2>&1; then
      echo "ERROR: Express still cannot be resolved after explicit install."
      popd >/dev/null 2>&1
      return 1
    fi
  fi

  # Export the env vars for this process
  set -a
  # shellcheck disable=SC1090
  [ -f "./postgres.env" ] && source "./postgres.env"
  set +a

  # Start the Node server only if the express check succeeded above
  if pgrep -f "node .*server.js" >/dev/null 2>&1; then
    echo "db_visualizer server already running."
  else
    echo "Starting db_visualizer server..."
    node server.js --host 0.0.0.0 >/var/log/db_visualizer.log 2>&1 &
    SERVER_PID=$!
    sleep 1
    if ps -p "$SERVER_PID" > /dev/null 2>&1; then
      echo "db_visualizer started (PID: $SERVER_PID). Logs: /var/log/db_visualizer.log"
    else
      echo "ERROR: db_visualizer failed to start. Check /var/log/db_visualizer.log"
      popd >/dev/null 2>&1
      return 1
    fi
  fi

  popd >/dev/null 2>&1 || true
}

# Call bootstrap after PostgreSQL is confirmed ready
if ! bootstrap_db_visualizer; then
  echo "db_visualizer bootstrap encountered errors; check logs."
  # Do not exit non-zero to avoid breaking DB container if Node is optional,
  # but signal clearly in logs. If strict behavior is desired, uncomment below:
  # exit 1
fi

# Ensure gradlew shims are executable if present (helps CI pipelines)
if [ -f "${SCRIPT_DIR}/../android_frontend/gradlew" ]; then chmod +x "${SCRIPT_DIR}/../android_frontend/gradlew" || true; fi
if [ -f "${SCRIPT_DIR}/../backend/gradlew" ]; then chmod +x "${SCRIPT_DIR}/../backend/gradlew" || true; fi
# Also ensure repo-level gradlew shims are executable if present
if [ -f "${SCRIPT_DIR}/../../gradlew" ]; then chmod +x "${SCRIPT_DIR}/../../gradlew" || true; fi
if [ -f "${SCRIPT_DIR}/../gradlew" ]; then chmod +x "${SCRIPT_DIR}/../gradlew" || true; fi
