#!/usr/bin/env bash
# sandbox-test.sh — Verify your bubblewrap sandbox is actually working
#
# Run this INSIDE the sandbox to confirm isolation:
#   bwrap [your args] /bin/bash sandbox-test.sh
#
# Or just run claude-sandbox.sh and paste these commands manually.

set -uo pipefail

PASS=0
FAIL=0

check() {
    local desc="$1"
    local expected="$2"  # "blocked" or "allowed"
    local cmd="$3"

    if eval "$cmd" &>/dev/null 2>&1; then
        result="allowed"
    else
        result="blocked"
    fi

    if [[ "$result" == "$expected" ]]; then
        echo "  ✅ PASS: $desc ($expected)"
        ((PASS++))
    else
        echo "  ❌ FAIL: $desc (expected $expected, got $result)"
        ((FAIL++))
    fi
}

echo ""
echo "═══════════════════════════════════════════════"
echo "  Bubblewrap Sandbox Verification Tests"
echo "═══════════════════════════════════════════════"
echo ""

echo "── Filesystem Write Tests ──"
check "Write to project dir"      "allowed"  "touch ./sandbox-test-canary && rm ./sandbox-test-canary"
check "Write to /tmp"             "allowed"  "touch /tmp/sandbox-test-canary && rm /tmp/sandbox-test-canary"
check "Write to /usr"             "blocked"  "touch /usr/sandbox-test-canary"
check "Write to /etc"             "blocked"  "touch /etc/sandbox-test-canary"

echo ""
echo "── Filesystem Read Tests ──"
check "Read /usr/bin/env"         "allowed"  "cat /usr/bin/env > /dev/null"
check "Read /etc/hosts"           "allowed"  "cat /etc/hosts > /dev/null"

echo ""
echo "── Sensitive Path Tests ──"
check "Read ~/.gnupg/private-keys-v1.d"  "blocked"  "ls ~/.gnupg/private-keys-v1.d 2>/dev/null"
check "Read ~/.password-store"           "blocked"  "ls ~/.password-store 2>/dev/null"

echo ""
echo "── Network Tests ──"
check "Reach github.com"          "allowed"  "curl -s --connect-timeout 3 https://github.com > /dev/null"
check "Reach AWS"                 "allowed"  "curl -s --connect-timeout 3 https://sts.amazonaws.com > /dev/null"
check "DNS resolution"            "allowed"  "getent hosts github.com"

echo ""
echo "── Tool Access Tests ──"
check "git available"             "allowed"  "git --version"
check "node available"            "allowed"  "node --version"
check "aws cli available"         "allowed"  "aws --version"

echo ""
echo "═══════════════════════════════════════════════"
echo "  Results: $PASS passed, $FAIL failed"
echo "═══════════════════════════════════════════════"
echo ""

if [[ $FAIL -gt 0 ]]; then
    echo "⚠️  Some tests failed. Review the output above"
    echo "   and adjust claude-sandbox.sh paths as needed."
    exit 1
else
    echo "🎉 All tests passed. Sandbox is working as expected."
    exit 0
fi
