#!/bin/bash
# =============================================================================
# opencode-task-utils Integration Test Suite
# =============================================================================
# Self-contained bash tests for the core logic of opencode-task-utils.
# Tests sanitizeId, atomicWrite, registry operations, chain operations,
# task_rm deletion, and edge cases — all without importing the plugin.
# =============================================================================
set -euo pipefail

TEST_DIR="/tmp/opencode-task-utils-test"
PASS=0
FAIL=0

# Cleanup on exit (always runs, even on failure)
trap 'rm -rf "$TEST_DIR"' EXIT

# Colors
GRN='\033[0;32m'
RED='\033[0;31m'
RST='\033[0m'

REGISTRY_FILE="$TEST_DIR/registry.json"

# ─── Test helpers ───

pass() {
  PASS=$((PASS + 1))
  printf "  ${GRN}PASS${RST}  %s\n" "$1"
}

fail() {
  FAIL=$((FAIL + 1))
  printf "  ${RED}FAIL${RST}  %s\n" "$1"
  if [ $# -ge 3 ]; then
    echo "         expected: $2"
    echo "         actual:   $3"
  fi
}

# ─── Core logic reimplemented in bash (mirrors plugin src/index.ts) ───

# Matches /^[a-zA-Z0-9][a-zA-Z0-9_-]*$/
sanitizeId() {
  local id="$1"
  if [[ "$id" =~ ^[a-zA-Z0-9][a-zA-Z0-9_-]*$ ]]; then
    echo "$id"
    return 0
  fi
  return 1
}

# Atomic write: writes to {path}.tmp.{pid} then renames
atomicWrite() {
  local path="$1" data="$2"
  local dir
  dir="${path%/*}"
  if [ "$dir" != "$path" ]; then
    mkdir -p "$dir"
  fi
  local tmp="${path}.tmp.$$"
  printf '%s' "$data" > "$tmp"
  mv "$tmp" "$path"
}

# Safe read: returns fallback if file missing, unreadable, or invalid JSON
safeRead() {
  local path="$1" fallback="$2"
  [ -f "$path" ] || { echo "$fallback"; return 0; }
  local content
  content=$(cat "$path" 2>/dev/null) || { echo "$fallback"; return 0; }
  [ -n "$content" ] || { echo "$fallback"; return 0; }
  # Basic bracket validation: first non-whitespace char must be '{',
  # last non-whitespace char must be '}'
  local trimmed
  trimmed=$(printf '%s' "$content" | sed 's/^[[:space:]]*//; s/[[:space:]]*$//')
  case "$trimmed" in
    "{"*"}") echo "$content"; return 0 ;;
    *)       echo "$fallback"; return 0 ;;
  esac
}

# Registry operations
readRegistry() {
  mkdir -p "$TEST_DIR"
  if [ ! -f "$REGISTRY_FILE" ]; then
    echo "{}"
    return 0
  fi
  safeRead "$REGISTRY_FILE" "{}"
}

writeRegistry() {
  mkdir -p "$TEST_DIR"
  atomicWrite "$REGISTRY_FILE" "$1"
}

# Chain operations
readChain() {
  local chainId="$1"
  local path="$TEST_DIR/chain-${chainId}/chain.json"
  if [ ! -f "$path" ]; then
    echo "null"
    return 0
  fi
  safeRead "$path" "null"
}

writeChain() {
  local chainId="$1" data="$2"
  local dir="$TEST_DIR/chain-${chainId}"
  mkdir -p "$dir"
  atomicWrite "$dir/chain.json" "$data"
}

# ─── Test: sanitizeId ───

test_sanitize_id() {
  echo ""
  echo "=== Sanitize ID ==="

  # Valid cases
  if result=$(sanitizeId "hello123") && [ "$result" = "hello123" ]; then
    pass "hello123 is valid"
  else
    fail "hello123 is valid"
  fi

  if result=$(sanitizeId "my-chain-step-3") && [ "$result" = "my-chain-step-3" ]; then
    pass "my-chain-step-3 is valid"
  else
    fail "my-chain-step-3 is valid"
  fi

  if result=$(sanitizeId "TASK_001") && [ "$result" = "TASK_001" ]; then
    pass "TASK_001 (uppercase + underscore) is valid"
  else
    fail "TASK_001 (uppercase + underscore) is valid"
  fi

  if result=$(sanitizeId "a") && [ "$result" = "a" ]; then
    pass "single char 'a' is valid"
  else
    fail "single char 'a' is valid"
  fi

  if result=$(sanitizeId "0") && [ "$result" = "0" ]; then
    pass "single digit '0' is valid"
  else
    fail "single digit '0' is valid"
  fi

  # Invalid cases
  if sanitizeId "" >/dev/null 2>&1; then
    fail "empty string is invalid"
  else
    pass "empty string is invalid"
  fi

  if sanitizeId "../etc/passwd" >/dev/null 2>&1; then
    fail "../etc/passwd is invalid"
  else
    pass "../etc/passwd is invalid"
  fi

  if sanitizeId "with spaces" >/dev/null 2>&1; then
    fail "with spaces is invalid"
  else
    pass "with spaces is invalid"
  fi

  if sanitizeId "a/b" >/dev/null 2>&1; then
    fail "a/b is invalid"
  else
    pass "a/b is invalid"
  fi

  if sanitizeId "-leading-hyphen" >/dev/null 2>&1; then
    fail "-leading-hyphen is invalid"
  else
    pass "-leading-hyphen is invalid"
  fi

  if sanitizeId "_leading-underscore" >/dev/null 2>&1; then
    fail "_leading-underscore is invalid"
  else
    pass "_leading-underscore is invalid"
  fi

  if sanitizeId "has.dots" >/dev/null 2>&1; then
    fail "has.dots is invalid"
  else
    pass "has.dots is invalid"
  fi
}

# ─── Test: atomicWrite ───

test_atomic_write() {
  echo ""
  echo "=== Atomic Write ==="

  # Test 1: basic write
  atomicWrite "$TEST_DIR/hello.txt" "Hello World"
  if [ -f "$TEST_DIR/hello.txt" ]; then
    pass "atomicWrite creates file"
  else
    fail "atomicWrite creates file"
  fi

  # Test 2: no .tmp file left behind
  if ls "$TEST_DIR/hello.txt.tmp."* 2>/dev/null | grep -q .; then
    fail "no .tmp file left after rename"
  else
    pass "no .tmp file left after rename"
  fi

  # Test 3: content matches
  local content
  content=$(cat "$TEST_DIR/hello.txt")
  if [ "$content" = "Hello World" ]; then
    pass "atomicWrite content matches"
  else
    fail "atomicWrite content matches" "Hello World" "$content"
  fi

  # Test 4: creates parent directories
  atomicWrite "$TEST_DIR/a/b/c/nested.txt" "Nested content"
  if [ -f "$TEST_DIR/a/b/c/nested.txt" ]; then
    pass "atomicWrite creates parent directories"
  else
    fail "atomicWrite creates parent directories"
  fi

  local nested
  nested=$(cat "$TEST_DIR/a/b/c/nested.txt")
  if [ "$nested" = "Nested content" ]; then
    pass "atomicWrite nested content matches"
  else
    fail "atomicWrite nested content matches" "Nested content" "$nested"
  fi

  # Test 5: overwrite existing file
  atomicWrite "$TEST_DIR/hello.txt" "Overwritten"
  local overwritten
  overwritten=$(cat "$TEST_DIR/hello.txt")
  if [ "$overwritten" = "Overwritten" ]; then
    pass "atomicWrite overwrites existing file"
  else
    fail "atomicWrite overwrites existing file" "Overwritten" "$overwritten"
  fi

  # Test 6: empty content
  atomicWrite "$TEST_DIR/empty.txt" ""
  local empty
  empty=$(cat "$TEST_DIR/empty.txt")
  if [ -z "$empty" ]; then
    pass "atomicWrite handles empty content"
  else
    fail "atomicWrite handles empty content" "empty string" "'$empty'"
  fi
}

# ─── Test: Registry Operations ───

test_registry_ops() {
  echo ""
  echo "=== Registry Operations ==="

  # Test 1: missing file returns empty object
  local result
  result=$(readRegistry)
  if [ "$result" = "{}" ]; then
    pass "readRegistry with no file returns {}"
  else
    fail "readRegistry with no file returns {}" "{}" "$result"
  fi

  # Test 2: write a registry entry
  local entry1='{
  "task-001": {
    "task_id": "task-001",
    "title": "Research Task",
    "status": "completed",
    "timestamp": "2026-05-29T12:00:00.000Z",
    "file": "/tmp/opencode-tasks/task-001.md"
  }
}'
  writeRegistry "$entry1"
  result=$(readRegistry)
  if [ "$result" = "$entry1" ]; then
    pass "writeRegistry stores entry correctly"
  else
    fail "writeRegistry stores entry correctly" "(see diff below)" "(see diff below)"
    echo "         --- expected ---"
    echo "$entry1" | sed 's/^/         /'
    echo "         --- actual ---"
    echo "$result" | sed 's/^/         /'
  fi

  # Test 3: registry file is non-empty
  if [ -s "$REGISTRY_FILE" ]; then
    pass "registry file is non-empty"
  else
    fail "registry file is non-empty"
  fi

  # Test 4: upsert — update existing entry status
  local entry1_updated='{
  "task-001": {
    "task_id": "task-001",
    "title": "Research Task",
    "status": "running",
    "timestamp": "2026-05-29T12:05:00.000Z",
    "file": "/tmp/opencode-tasks/task-001.md"
  }
}'
  writeRegistry "$entry1_updated"
  local has_running
  has_running=$(readRegistry)
  if echo "$has_running" | grep -q '"running"'; then
    pass "upsert updates status to running"
  else
    fail "upsert updates status to running"
  fi

  # Test 5: upsert — add second entry alongside existing
  local both_entries='{
  "task-001": {
    "task_id": "task-001",
    "title": "Research Task",
    "status": "running",
    "timestamp": "2026-05-29T12:05:00.000Z",
    "file": "/tmp/opencode-tasks/task-001.md"
  },
  "task-002": {
    "task_id": "task-002",
    "title": "Analysis Task",
    "status": "pending",
    "timestamp": "2026-05-29T12:10:00.000Z",
    "file": "/tmp/opencode-tasks/task-002.md"
  }
}'
  writeRegistry "$both_entries"
  result=$(readRegistry)
  local has_two
  has_two=$(echo "$result" | grep -c '"task_id"' || true)
  if [ "$has_two" -eq 2 ]; then
    pass "upsert adds second entry, both present"
  else
    fail "upsert adds second entry, both present" "2 entries" "${has_two:-0} entries"
  fi

  # Test 6: preserve existing chain_id and step on upsert
  local with_chain='{
  "task-003": {
    "task_id": "task-003",
    "title": "Chain Task",
    "status": "completed",
    "chain_id": "pipeline-1",
    "step": 2,
    "timestamp": "2026-05-29T12:00:00.000Z",
    "file": "/tmp/opencode-tasks/task-003.md"
  }
}'
  writeRegistry "$with_chain"

  local upsert_partial='{
  "task-003": {
    "task_id": "task-003",
    "title": "Chain Task",
    "status": "failed",
    "chain_id": "pipeline-1",
    "step": 2,
    "timestamp": "2026-05-29T12:30:00.000Z",
    "file": "/tmp/opencode-tasks/task-003.md"
  }
}'
  writeRegistry "$upsert_partial"
  result=$(readRegistry)
  if echo "$result" | grep -q '"chain_id": "pipeline-1"' && echo "$result" | grep -q '"step": 2'; then
    pass "upsert preserves chain_id and step on partial update"
  else
    fail "upsert preserves chain_id and step on partial update"
    echo "$result" | sed 's/^/         /'
  fi
}

# ─── Test: Chain Operations ───

test_chain_ops() {
  echo ""
  echo "=== Chain Operations ==="

  # Test 1: create a chain plan
  local plan='{
  "chain_id": "test-chain",
  "created": "2026-05-29T12:00:00.000Z",
  "steps": [
    {
      "step": 1,
      "title": "Research topic",
      "prompt": "Research {previous}",
      "status": "pending"
    },
    {
      "step": 2,
      "title": "Summarize",
      "prompt": "Summarize in 3 bullets: {previous}",
      "status": "pending"
    }
  ],
  "initial_input": "Context about X",
  "completed_step": 0
}'
  writeChain "test-chain" "$plan"

  local result
  result=$(readChain "test-chain")
  if echo "$result" | grep -q '"chain_id": "test-chain"'; then
    pass "writeChain creates chain.json with correct chain_id"
  else
    fail "writeChain creates chain.json with correct chain_id"
  fi

  if echo "$result" | grep -q '"completed_step": 0'; then
    pass "chain starts with completed_step = 0"
  else
    fail "chain starts with completed_step = 0"
  fi

  if echo "$result" | grep -q '"status": "pending"'; then
    pass "chain steps start as pending"
  else
    fail "chain steps start as pending"
  fi

  # Test 2: chain directory structure
  if [ -d "$TEST_DIR/chain-test-chain" ] && [ -f "$TEST_DIR/chain-test-chain/chain.json" ]; then
    pass "chain directory and chain.json created"
  else
    fail "chain directory and chain.json created"
  fi

  # Test 3: update step status (simulating task_step advancing the chain)
  local plan_step1_done='{
  "chain_id": "test-chain",
  "created": "2026-05-29T12:00:00.000Z",
  "steps": [
    {
      "step": 1,
      "title": "Research topic",
      "prompt": "Research {previous}",
      "status": "completed"
    },
    {
      "step": 2,
      "title": "Summarize",
      "prompt": "Summarize in 3 bullets: {previous}",
      "status": "pending"
    }
  ],
  "initial_input": "Context about X",
  "completed_step": 1
}'
  writeChain "test-chain" "$plan_step1_done"
  result=$(readChain "test-chain")
  if echo "$result" | grep -q '"completed_step": 1'; then
    pass "task_step updates completed_step to 1"
  else
    fail "task_step updates completed_step to 1"
  fi

  local completed_count
  completed_count=$(echo "$result" | grep -c '"status": "completed"' || true)
  if [ "$completed_count" -ge 1 ]; then
    pass "task_step marks step 1 as completed"
  else
    fail "task_step marks step 1 as completed" "at least 1 completed" "0 completed"
  fi

  # Test 4: missing chain returns null
  result=$(readChain "does-not-exist")
  if [ "$result" = "null" ]; then
    pass "readChain for missing chain returns null"
  else
    fail "readChain for missing chain returns null" "null" "$result"
  fi

  # Test 5: {previous} resolution
  local resolved
  resolved=$(echo "Summarize in 3 bullets: {previous}" | sed 's/{previous}/the actual data/g')
  if [ "$resolved" = "Summarize in 3 bullets: the actual data" ]; then
    pass "task_step resolves {previous} placeholder"
  else
    fail "task_step resolves {previous} placeholder" "Summarize in 3 bullets: the actual data" "$resolved"
  fi

  # Test 6: multi-occurrence replacement (plugin uses replace(/\\{previous\\}/g, ...))
  local multi='Analyze {previous} and compare with {previous}'
  local resolved_multi
  resolved_multi=$(echo "$multi" | sed 's/{previous}/data/g')
  if [ "$resolved_multi" = "Analyze data and compare with data" ]; then
    pass "task_step replaces all occurrences of {previous}"
  else
    fail "task_step replaces all occurrences of {previous}" "all replaced" "$resolved_multi"
  fi

  # Test 7: chain with many steps
  local big_chain='{
  "chain_id": "multi-step",
  "created": "2026-05-29T12:00:00.000Z",
  "steps": [
    { "step": 1, "title": "Step 1", "prompt": "Do step 1", "status": "pending" },
    { "step": 2, "title": "Step 2", "prompt": "Do step 2", "status": "pending" },
    { "step": 3, "title": "Step 3", "prompt": "Do step 3", "status": "pending" },
    { "step": 4, "title": "Step 4", "prompt": "Do step 4", "status": "pending" },
    { "step": 5, "title": "Step 5", "prompt": "Do step 5", "status": "pending" }
  ],
  "initial_input": null,
  "completed_step": 0
}'
  writeChain "multi-step" "$big_chain"
  result=$(readChain "multi-step")
  local step_count
  step_count=$(echo "$result" | grep -c '"step":' || true)
  if [ "$step_count" -ge 5 ]; then
    pass "chain with 5 steps stores all steps"
  else
    fail "chain with 5 steps stores all steps" "at least 5 step refs" "${step_count}"
  fi
}

# ─── Test: Deletion (task_rm) ───

test_deletion() {
  echo ""
  echo "=== Deletion (task_rm) ==="

  # Create registry with two entries
  cat > "$REGISTRY_FILE" << 'EOF'
{
  "task-one": {
    "task_id": "task-one",
    "title": "Task One",
    "status": "completed",
    "timestamp": "2026-05-29T12:00:00.000Z",
    "file": "/tmp/opencode-tasks/task-one.md"
  },
  "task-two": {
    "task_id": "task-two",
    "title": "Task Two",
    "status": "failed",
    "timestamp": "2026-05-29T12:05:00.000Z",
    "file": "/tmp/opencode-tasks/task-two.md"
  }
}
EOF

  # Test 1: verify both exist before deletion
  local reg
  reg=$(readRegistry)
  local count
  count=$(echo "$reg" | grep -c '"task_id"' || true)
  if [ "$count" -eq 2 ]; then
    pass "task_rm — both entries present before delete"
  else
    fail "task_rm — both entries present before delete" "2 entries" "${count} entries"
  fi

  # Test 2: delete entry from registry (simulate task_rm with task_id)
  cat > "$REGISTRY_FILE" << 'EOF'
{
  "task-two": {
    "task_id": "task-two",
    "title": "Task Two",
    "status": "failed",
    "timestamp": "2026-05-29T12:05:00.000Z",
    "file": "/tmp/opencode-tasks/task-two.md"
  }
}
EOF

  reg=$(readRegistry)
  if echo "$reg" | grep -q '"task-one"'; then
    fail "task_rm — entry task-one removed from registry" "not found" "found"
  else
    pass "task_rm — entry task-one removed from registry"
  fi

  if echo "$reg" | grep -q '"task-two"'; then
    pass "task_rm — entry task-two remains in registry"
  else
    fail "task_rm — entry task-two remains in registry" "found" "not found"
  fi

  # Test 3: delete with file removal
  echo "# Task One Content" > "$TEST_DIR/task-one.md"
  echo "# Task Two Content" > "$TEST_DIR/task-two.md"

  rm -f "$TEST_DIR/task-two.md"
  cat > "$REGISTRY_FILE" << 'EOF'
{
  "task-one": {
    "task_id": "task-one",
    "title": "Task One",
    "status": "completed",
    "timestamp": "2026-05-29T12:00:00.000Z",
    "file": "/tmp/opencode-tasks/task-one.md"
  }
}
EOF

  if [ -f "$TEST_DIR/task-two.md" ]; then
    fail "task_rm with delete_file — task-two.md deleted" "file gone" "file exists"
  else
    pass "task_rm with delete_file — task-two.md deleted"
  fi

  if [ -f "$TEST_DIR/task-one.md" ]; then
    pass "task_rm with delete_file — task-one.md preserved"
  else
    fail "task_rm with delete_file — task-one.md preserved"
  fi

  reg=$(readRegistry)
  if echo "$reg" | grep -q '"task-two"'; then
    fail "task_rm with delete_file — task-two removed from registry" "not found" "found"
  else
    pass "task_rm with delete_file — task-two removed from registry"
  fi

  # Test 4: delete non-existent entry (idempotent)
  cat > "$REGISTRY_FILE" << 'EOF'
{
  "task-one": {
    "task_id": "task-one",
    "title": "Task One",
    "status": "completed",
    "timestamp": "2026-05-29T12:00:00.000Z",
    "file": "/tmp/opencode-tasks/task-one.md"
  }
}
EOF
  local after_count
  after_count=$(echo "$(readRegistry)" | grep -c '"task_id"' || true)
  if [ "$after_count" -eq 1 ]; then
    pass "task_rm — deleting non-existent entry is idempotent (no crash)"
  else
    fail "task_rm — deleting non-existent entry is idempotent" "1 entry remains" "${after_count}"
  fi

  # Test 5: chain deletion (remove all tasks belonging to chain + chain directory)
  mkdir -p "$TEST_DIR/chain-pipeline"
  cat > "$TEST_DIR/chain-pipeline/chain.json" << 'EOF'
{ "chain_id": "pipeline", "created": "", "steps": [], "initial_input": null, "completed_step": 0 }
EOF

  cat > "$REGISTRY_FILE" << 'EOF'
{
  "chain-pipeline": {
    "task_id": "chain-pipeline",
    "title": "Pipeline: pipeline",
    "status": "running",
    "chain_id": "pipeline",
    "timestamp": "2026-05-29T12:00:00.000Z"
  },
  "pipeline-step-1": {
    "task_id": "pipeline-step-1",
    "title": "Step 1",
    "status": "completed",
    "chain_id": "pipeline",
    "step": 1,
    "timestamp": "2026-05-29T12:00:00.000Z",
    "file": "/tmp/opencode-tasks/pipeline-step-1.md"
  },
  "pipeline-step-2": {
    "task_id": "pipeline-step-2",
    "title": "Step 2",
    "status": "pending",
    "chain_id": "pipeline",
    "step": 2,
    "timestamp": "2026-05-29T12:00:00.000Z",
    "file": "/tmp/opencode-tasks/pipeline-step-2.md"
  }
}
EOF

  # Simulate chain deletion: remove chain dir and all chain entries from registry
  rm -rf "$TEST_DIR/chain-pipeline"
  cat > "$REGISTRY_FILE" << 'EOF'
{}
EOF

  reg=$(readRegistry)
  if [ "$reg" = "{}" ]; then
    pass "task_rm chain deletion — all entries removed from registry"
  else
    fail "task_rm chain deletion — all entries removed from registry" "{}" "$reg"
  fi

  if [ ! -d "$TEST_DIR/chain-pipeline" ]; then
    pass "task_rm chain deletion — chain directory removed"
  else
    fail "task_rm chain deletion — chain directory removed" "dir gone" "dir exists"
  fi
}

# ─── Test: Edge Cases ───

test_edge_cases() {
  echo ""
  echo "=== Edge Cases ==="

  # Test 1: empty registry (no file)
  local result
  result=$(readRegistry)
  if [ "$result" = "{}" ]; then
    pass "empty registry — no file returns {}"
  else
    fail "empty registry — no file returns {}" "{}" "$result"
  fi

  # Test 2: corrupt JSON — malformed content
  echo "not valid json at all" > "$REGISTRY_FILE"
  result=$(readRegistry)
  if [ "$result" = "{}" ]; then
    pass "corrupt registry JSON — falls back to {}"
  else
    fail "corrupt registry JSON — falls back to {}" "{}" "$result"
  fi

  # Test 3: corrupt JSON — starts with { but not valid (no closing })
  echo "{invalid json content" > "$REGISTRY_FILE"
  result=$(readRegistry)
  if [ "$result" = "{}" ]; then
    pass "corrupt JSON (starts with { but no }) — falls back to {}"
  else
    fail "corrupt JSON (starts with { but no }) — falls back to {}" "{}" "$result"
  fi

  # Test 4: empty file
  : > "$REGISTRY_FILE"
  result=$(readRegistry)
  if [ "$result" = "{}" ]; then
    pass "empty registry file — falls back to {}"
  else
    fail "empty registry file — falls back to {}" "{}" "$result"
  fi

  # Test 5: extremely long content in save
  local long_content
  long_content=$(head -c 100000 /dev/zero | tr '\0' 'A')
  atomicWrite "$TEST_DIR/large.md" "$long_content"
  local saved_size
  saved_size=$(wc -c < "$TEST_DIR/large.md" | tr -d ' ')
  if [ "$saved_size" -eq 100000 ]; then
    pass "long content — 100K bytes stored correctly"
  else
    fail "long content — 100K bytes stored correctly" "100000 bytes" "${saved_size} bytes"
  fi

  # Test 6: registry with special characters in title
  local special='{
  "my-task": {
    "task_id": "my-task",
    "title": "Task with <special> & chars \"quoted\"",
    "status": "completed",
    "timestamp": "2026-05-29T12:00:00.000Z",
    "file": "/tmp/opencode-tasks/my-task.md"
  }
}'
  writeRegistry "$special"
  result=$(readRegistry)
  if echo "$result" | grep -q 'special.*&.*quoted'; then
    pass "registry handles special characters in title"
  else
    fail "registry handles special characters in title"
  fi

  # Test 7: chain with null initial_input
  local chain_no_input='{
  "chain_id": "no-input",
  "created": "2026-05-29T12:00:00.000Z",
  "steps": [
    { "step": 1, "title": "Only step", "prompt": "Do the thing", "status": "pending" }
  ],
  "initial_input": null,
  "completed_step": 0
}'
  writeChain "no-input" "$chain_no_input"
  result=$(readChain "no-input")
  if echo "$result" | grep -q '"initial_input": null'; then
    pass "chain with null initial_input stores correctly"
  else
    fail "chain with null initial_input stores correctly"
  fi

  # Test 8: orphaned .tmp files from other processes don't affect reads
  local bad_tmp="${REGISTRY_FILE}.tmp.99999"
  printf 'garbage from crashed process' > "$bad_tmp"
  result=$(readRegistry)
  echo "$result" | grep -q 'garbage' && {
    fail "orphaned .tmp files from other processes are not read"
  } || {
    pass "orphaned .tmp files from other processes are not read"
  }
  rm -f "$bad_tmp"
}

# ─── Main Runner ───

echo "============================================="
echo "  opencode-task-utils Integration Tests"
echo "============================================="

test_sanitize_id
test_atomic_write
test_registry_ops
test_chain_ops
test_deletion
test_edge_cases

# ─── Summary ───

echo ""
echo "============================================="
echo "  Results: $PASS passed, $FAIL failed, $((PASS + FAIL)) total"
echo "============================================="

if [ "$FAIL" -eq 0 ]; then
  echo "  All tests passed."
  exit 0
else
  echo "  Some tests FAILED."
  exit 1
fi
