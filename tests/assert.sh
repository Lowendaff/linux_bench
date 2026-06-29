#!/usr/bin/env bash
# 极简纯 Bash 断言库,无第三方依赖。
TESTS_RUN=0
TESTS_FAILED=0

assert_eq() { # got want msg
    TESTS_RUN=$((TESTS_RUN+1))
    if [ "$1" = "$2" ]; then
        echo "ok: $3"
    else
        echo "FAIL: $3 (expected '$2', got '$1')"
        TESTS_FAILED=$((TESTS_FAILED+1))
    fi
}

assert_contains() { # haystack needle msg
    TESTS_RUN=$((TESTS_RUN+1))
    if [[ "$1" == *"$2"* ]]; then
        echo "ok: $3"
    else
        echo "FAIL: $3 (string '$1' does not contain '$2')"
        TESTS_FAILED=$((TESTS_FAILED+1))
    fi
}

assert_success() { # cmd...
    TESTS_RUN=$((TESTS_RUN+1))
    if "$@" >/dev/null 2>&1; then
        echo "ok: success [$*]"
    else
        echo "FAIL: expected success [$*]"
        TESTS_FAILED=$((TESTS_FAILED+1))
    fi
}

assert_fail() { # cmd...
    TESTS_RUN=$((TESTS_RUN+1))
    if "$@" >/dev/null 2>&1; then
        echo "FAIL: expected failure [$*]"
        TESTS_FAILED=$((TESTS_FAILED+1))
    else
        echo "ok: failed as expected [$*]"
    fi
}

finish() {
    echo "----"
    echo "${TESTS_RUN} run, ${TESTS_FAILED} failed"
    [ "$TESTS_FAILED" -eq 0 ]
}
