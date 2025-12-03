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
    "express": "^4.18.2",
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
PG_VERSION=$(ls /usr/lib/postgresql/ | head -1)
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

  # Prefer Node 18; if nvm present, try to use specified version
  if command -v nvm >/dev/null 2>&1; then
    echo "nvm detected, using Node ${NODE_VERSION}"
    # shellcheck disable=SC1090
    source "$HOME/.nvm/nvm.sh" 2>/dev/null || true
    nvm install "${NODE_VERSION}" >/dev/null 2>&1 || true
    nvm use "${NODE_VERSION}" >/dev/null 2>&1 || true
  else
    if command -v node >/dev/null 2>&1; then
      NODE_ACTUAL="$(node -v 2>/dev/null || true)"
      echo "Using system Node ${NODE_ACTUAL}"
    else
      echo "WARNING: Node.js not found in PATH. Ensure Node 18 is installed in the image."
    fi
  fi

  # Ensure npm exists
  if ! command -v npm >/dev/null 2>&1; then
    echo "ERROR: npm is not available. Cannot install db_visualizer dependencies."
    return 1
  fi

  pushd "${DBV_DIR}" >/dev/null 2>&1 || {
    echo "ERROR: Could not access ${DBV_DIR}"
    return 1
  }

  # Ensure dependencies are installed if express is missing
  if [ ! -d "node_modules/express" ]; then
    if [ -f "package-lock.json" ]; then
      echo "Installing dependencies with npm ci..."
      npm ci --no-audit --no-fund || {
        echo "npm ci failed, attempting npm install..."
        npm install --no-audit --no-fund || {
          echo "ERROR: npm dependency installation failed."
          popd >/dev/null 2>&1
          return 1
        }
      }
    else
      echo "Installing dependencies with npm install..."
      npm install --no-audit --no-fund || {
        echo "ERROR: npm dependency installation failed."
        popd >/dev/null 2>&1
        return 1
      }
    fi
  else
    echo "Dependencies already present (express found)."
  fi

  # Verify that express resolves before starting
  if ! node -e "require.resolve('express')" >/dev/null 2>&1; then
    echo "ERROR: Unable to resolve 'express' after installation."
    popd >/dev/null 2>&1
    return 1
  fi

  # Export the env vars for this process
  set -a
  # shellcheck disable=SC1090
  [ -f "./postgres.env" ] && source "./postgres.env"
  set +a

  # Start the Node server in the background if not already running
  if pgrep -f "node .*server.js" >/dev/null 2>&1; then
    echo "db_visualizer server already running."
  else
    echo "Starting db_visualizer server..."
    # Start in background and redirect output
    node server.js --host 0.0.0.0 >/var/log/db_visualizer.log 2>&1 &
    echo "db_visualizer started. Logs: /var/log/db_visualizer.log"
  fi

  popd >/dev/null 2>&1 || true
}

# Call bootstrap after PostgreSQL is confirmed ready
bootstrap_db_visualizer || echo "db_visualizer bootstrap encountered errors; check logs."

# Ensure gradlew shims are executable if present (helps CI pipelines)
chmod +x "${SCRIPT_DIR}/../android_frontend/gradlew" 2>/dev/null || true
chmod +x "${SCRIPT_DIR}/../backend/gradlew" 2>/dev/null || true
# Also ensure repo-level gradlew shims are executable if present
chmod +x "${SCRIPT_DIR}/../../gradlew" 2>/dev/null || true
chmod +x "${SCRIPT_DIR}/../gradlew" 2>/dev/null || true
