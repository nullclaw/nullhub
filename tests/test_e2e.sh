#!/bin/bash
set -euo pipefail

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
NC='\033[0m'

PASSED=0
FAILED=0
PORT=19800  # Use high port to avoid conflicts
BASE="http://127.0.0.1:$PORT"
TEST_HOME=$(mktemp -d "${TMPDIR:-/tmp}/nullhub-e2e.XXXXXX")
SERVER_LOG="$TEST_HOME/nullhub-server.log"

server_is_running() {
    kill -0 "$SERVER_PID" 2>/dev/null
}

fail_if_server_exited() {
    local context="$1"

    if server_is_running; then
        return 0
    fi

    local exit_code=0
    set +e
    wait "$SERVER_PID"
    exit_code=$?
    set -e

    echo -e "${RED}FAIL${NC}: nullhub exited unexpectedly during $context (exit $exit_code)"
    if [ -f "$SERVER_LOG" ]; then
        echo "--- nullhub server log ---"
        cat "$SERVER_LOG"
        echo "--- end nullhub server log ---"
    fi
    exit 1
}

# Build
echo "Building nullhub..."
zig build
EXPECTED_VERSION=$(./zig-out/bin/nullhub --version 2>&1 | awk '{print $2}' | sed 's/^v//')

# Start server in background
echo "Starting nullhub on port $PORT..."
HOME="$TEST_HOME" ./zig-out/bin/nullhub serve --port "$PORT" --no-open >"$SERVER_LOG" 2>&1 &
SERVER_PID=$!

# Cleanup on exit
cleanup() {
    echo "Stopping server..."
    if [ -n "${SERVER_PID:-}" ]; then
        kill "$SERVER_PID" 2>/dev/null || true
        wait "$SERVER_PID" 2>/dev/null || true
    fi
    rm -rf "$TEST_HOME"
}
trap cleanup EXIT

# Wait for server to be ready (retry loop instead of fixed sleep)
echo "Waiting for server..."
for i in $(seq 1 20); do
    fail_if_server_exited "startup"
    if curl -s -o /dev/null -w "%{http_code}" "$BASE/health" 2>/dev/null | grep -q "200"; then
        echo "Server ready after ${i} attempt(s)."
        break
    fi
    if [ "$i" -eq 20 ]; then
        echo "Server failed to start after 20 attempts"
        exit 1
    fi
    sleep 0.25
done

# Test helper
assert_status() {
    local description="$1"
    local expected="$2"
    local method="$3"
    local url="$4"
    local body="${5:-}"

    fail_if_server_exited "$description (before request)"

    if [ -n "$body" ]; then
        actual=$(curl -s -o /dev/null -w "%{http_code}" -X "$method" -H "Content-Type: application/json" -d "$body" "$url")
    else
        actual=$(curl -s -o /dev/null -w "%{http_code}" -X "$method" "$url")
    fi

    fail_if_server_exited "$description (after request)"

    if [ "$actual" = "$expected" ]; then
        echo -e "${GREEN}PASS${NC}: $description (HTTP $actual)"
        PASSED=$((PASSED + 1))
    else
        echo -e "${RED}FAIL${NC}: $description (expected $expected, got $actual)"
        FAILED=$((FAILED + 1))
    fi
}

assert_json_field() {
    local description="$1"
    local url="$2"
    local field="$3"
    local expected="$4"

    fail_if_server_exited "$description (before request)"
    local response=$(curl -s "$url")
    fail_if_server_exited "$description (after request)"
    local actual=$(echo "$response" | python3 -c "import sys,json; print(json.load(sys.stdin)$field)" 2>/dev/null || echo "PARSE_ERROR")

    if [ "$actual" = "$expected" ]; then
        echo -e "${GREEN}PASS${NC}: $description ($field = $actual)"
        PASSED=$((PASSED + 1))
    else
        echo -e "${RED}FAIL${NC}: $description (expected $expected, got $actual)"
        FAILED=$((FAILED + 1))
    fi
}

echo ""
echo "=== Health ==="
assert_status "GET /health returns 200" "200" GET "$BASE/health"

echo ""
echo "=== Status API ==="
assert_status "GET /api/status returns 200" "200" GET "$BASE/api/status"
assert_json_field "Status has hub version" "$BASE/api/status" "['hub']['version']" "$EXPECTED_VERSION"

echo ""
echo "=== Components API ==="
assert_status "GET /api/components returns 200" "200" GET "$BASE/api/components"
assert_status "POST /api/components/refresh returns 200" "200" POST "$BASE/api/components/refresh"

echo ""
echo "=== Instances API ==="
assert_status "GET /api/instances returns 200" "200" GET "$BASE/api/instances"

echo ""
echo "=== Wizard API ==="
assert_status "GET /api/wizard/nullclaw returns 200" "200" GET "$BASE/api/wizard/nullclaw"
assert_status "GET /api/wizard/unknown returns 404" "404" GET "$BASE/api/wizard/unknown"

echo ""
echo "=== Updates API ==="
assert_status "GET /api/updates returns 200" "200" GET "$BASE/api/updates"

echo ""
echo "=== Settings API ==="
assert_status "GET /api/settings returns 200" "200" GET "$BASE/api/settings"
assert_status "PUT /api/settings returns 200" "200" PUT "$BASE/api/settings" '{"port":19800}'

echo ""
echo "=== Service API ==="
assert_status "GET /api/service/status returns 200" "200" GET "$BASE/api/service/status"

echo ""
echo "=== Unknown routes ==="
assert_status "GET /api/nonexistent returns 404" "404" GET "$BASE/api/nonexistent"

echo ""
echo "================================"
echo -e "Results: ${GREEN}$PASSED passed${NC}, ${RED}$FAILED failed${NC}"
echo "================================"

fail_if_server_exited "final result collection"

if [ $FAILED -gt 0 ]; then
    exit 1
fi
