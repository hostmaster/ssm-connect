#!/usr/bin/env bash

set -uo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SCRIPT="${ROOT_DIR}/connect.sh"
FIXTURE_CONFIG="${ROOT_DIR}/tests/fixtures/connections.tsv"
export SSM_CONNECT_CONFIG="$FIXTURE_CONFIG"
export AWS_REGION=us-east-1
export AWS_DEFAULT_REGION=
BASH_BIN="$(command -v bash)"
failures=0

# DANGER: connect.sh's final foreground path (no --loop/--tmux/--dry-run) ends
# in `exec "${CMD[@]}"`. Unlike a plain call, `exec` does NOT honor this
# file's exported `aws` shell function and falls through to the REAL `aws`
# binary — confirmed the hard way: an earlier draft of a test here opened a
# live SSM port-forward against a real prod instance. Every test MUST reach
# --dry-run, --tmux, --tmux-kill, or an early error exit — never let a test
# invocation fall through to that plain foreground branch.

aws() {
    if [[ "${MOCK_AWS_FAIL:-false}" == true ]]; then
        echo "mock aws failure" >&2
        return 42
    fi
    if [[ "${1:-}" == "ec2" && "${2:-}" == "describe-instances" && -n "${MOCK_EC2_INSTANCES:-}" ]]; then
        printf '%s\n' "$MOCK_EC2_INSTANCES"
        return 0
    fi
    if [[ "${1:-}" == "ssm" && "${2:-}" == "describe-instance-information" ]]; then
        if [[ "${MOCK_PING_CHECK_FAIL:-false}" == true ]]; then
            echo "mock: access denied" >&2
            return 254
        fi
        echo "${MOCK_PING_STATUS:-Online}"
        return 0
    fi
    echo "i-mock123"
}

fzf() {
    local arg query=""
    for arg in "$@"; do
        case "$arg" in
            --filter=*) query="${arg#--filter=}" ;;
        esac
    done
    if [[ -n "$query" ]]; then
        awk -v query="$query" 'index($0, query) { print }'
    else
        sed -n '1p'
    fi
}

tmux() {
    local command="${1:-}"
    case "$command" in
        has-session)
            [[ "${MOCK_TMUX_SESSION_EXISTS:-false}" == true ]]
            ;;
        new-session)
            local session_name="${4:-}"
            local session_command="${*: -1}"
            if [[ "${MOCK_TMUX_EXECUTE_NEW:-false}" == true ]]; then
                AWS_PROFILE="${MOCK_TMUX_SERVER_AWS_PROFILE:-${AWS_PROFILE:-}}" \
                    bash -c "${session_command%%;*} --dry-run"
            else
                echo "TMUX_NEW_SESSION session=${session_name} cmd=${session_command}"
            fi
            ;;
        kill-session)
            echo "TMUX_SESSION_KILLED"
            ;;
    esac
}

export -f aws fzf tmux

assert_contains() {
    local output="$1" expected="$2"
    if [[ "$output" != *"$expected"* ]]; then
        echo "expected output to contain: $expected" >&2
        echo "actual output:" >&2
        echo "$output" >&2
        return 1
    fi
}

test_tmux_uses_resolved_selection() {
    local output
    output=$("$SCRIPT" prod --tmux 2>&1) || {
        echo "$output" >&2
        return 1
    }
    assert_contains "$output" " prod redis-prod;"
}

test_tmux_propagates_aws_profile() {
    local output
    output=$(AWS_PROFILE="profile with spaces" \
        MOCK_TMUX_SERVER_AWS_PROFILE="stale profile" \
        MOCK_TMUX_EXECUTE_NEW=true \
        "$SCRIPT" prod rdp-app --tmux 2>&1) || {
        echo "$output" >&2
        return 1
    }
    assert_contains "$output" "--profile profile with spaces --target"
}

test_tmux_kill_does_not_require_aws() (
    local test_tmp_dir mock_bin command command_path output status
    test_tmp_dir=$(mktemp -d "${TMPDIR:-/tmp}/ssm-connect-test.XXXXXX") || return 1
    trap 'rm -rf "$test_tmp_dir"' EXIT
    mock_bin="${test_tmp_dir}/bin"
    mkdir "$mock_bin" || return 1
    for command in awk dirname tr wc mkdir rm; do
        command_path=$(command -v "$command") || return 1
        ln -s "$command_path" "${mock_bin}/${command}" || return 1
    done

    # --tmux-kill only tears down a session this invocation previously marked
    # as owned (OWNED_MARKER in connect.sh, env-scoped) — simulate a prior
    # --tmux invocation having started it, scoped to this test's own state dir.
    mkdir -p "${test_tmp_dir}/ssm-connect" || return 1
    : > "${test_tmp_dir}/ssm-connect/prod-redis-prod.owned" || return 1

    output=$(
        PATH="$mock_bin" XDG_RUNTIME_DIR="$test_tmp_dir" MOCK_TMUX_SESSION_EXISTS=true \
            "$BASH_BIN" "$SCRIPT" prod redis-prod --tmux-kill 2>&1
    )
    status=$?
    if (( status != 0 )); then
        echo "expected exit status 0, got $status" >&2
        echo "$output" >&2
        return 1
    fi
    assert_contains "$output" "TMUX_SESSION_KILLED"
)

test_tmux_escapes_script_path() (
    local test_tmp_dir fixture_dir output
    test_tmp_dir=$(mktemp -d "${TMPDIR:-/tmp}/ssm-connect-test.XXXXXX") || return 1
    trap 'rm -rf "$test_tmp_dir"' EXIT
    fixture_dir="${test_tmp_dir}/dir with spaces"
    mkdir "$fixture_dir" || return 1
    ln -s "$SCRIPT" "${fixture_dir}/connect.sh" || return 1
    ln -s "$FIXTURE_CONFIG" "${fixture_dir}/connections.tsv" || return 1

    output=$(MOCK_TMUX_EXECUTE_NEW=true SSM_CONNECT_CONFIG="$FIXTURE_CONFIG" \
        "${fixture_dir}/connect.sh" prod rdp-app --tmux 2>&1)
    local status=$?

    if (( status != 0 )); then
        echo "expected exit status 0, got $status" >&2
        echo "$output" >&2
        return 1
    fi
    assert_contains "$output" "aws ssm start-session"
)

test_rejects_tmux_and_tmux_kill_together() {
    local output status
    output=$("$SCRIPT" prod redis-prod --tmux --tmux-kill 2>&1)
    status=$?
    if (( status == 0 )); then
        echo "expected non-zero exit, got 0" >&2
        echo "$output" >&2
        return 1
    fi
    assert_contains "$output" "mutually exclusive"
}

test_rejects_tmux_kill_and_dry_run_together() {
    local output status
    output=$("$SCRIPT" prod redis-prod --tmux-kill --dry-run 2>&1)
    status=$?
    if (( status == 0 )); then
        echo "expected non-zero exit, got 0" >&2
        echo "$output" >&2
        return 1
    fi
    assert_contains "$output" "mutually exclusive"
}

test_tmux_session_name_is_env_scoped() {
    local output_prod output_dev
    output_prod=$("$SCRIPT" prod db-app --tmux 2>&1) || {
        echo "$output_prod" >&2
        return 1
    }
    output_dev=$("$SCRIPT" dev db-app-dev --tmux 2>&1) || {
        echo "$output_dev" >&2
        return 1
    }
    assert_contains "$output_prod" "session=ssm-prod-db-app" && \
    assert_contains "$output_dev" "session=ssm-dev-db-app-dev"
}

test_duplicate_row_in_same_env_is_rejected() (
    local test_tmp_dir fixture_dir output status
    test_tmp_dir=$(mktemp -d "${TMPDIR:-/tmp}/ssm-connect-test.XXXXXX") || return 1
    trap 'rm -rf "$test_tmp_dir"' EXIT
    fixture_dir="${test_tmp_dir}/fixture"
    mkdir "$fixture_dir" || return 1
    ln -s "$SCRIPT" "${fixture_dir}/connect.sh" || return 1
    printf 'dup-conn\tprod\tredis\t-\thost-a\t16001\ndup-conn\tprod\tredis\t-\thost-b\t16002\n' \
        > "${fixture_dir}/connections.tsv"

    output=$(SSM_CONNECT_CONFIG="${fixture_dir}/connections.tsv" \
        "${fixture_dir}/connect.sh" prod dup-conn --dry-run 2>&1)
    status=$?
    if (( status == 0 )); then
        echo "expected non-zero exit, got 0" >&2
        echo "$output" >&2
        return 1
    fi
    assert_contains "$output" "rows resolved"
)

test_ec2_fallback_dry_run_for_unmatched_name() {
    local output status
    output=$(AWS_PROFILE=test-profile MOCK_EC2_INSTANCES=$'i-0abc123\tweb-01\trunning' \
        "$SCRIPT" prod web-01 --dry-run 2>&1)
    status=$?
    if (( status != 0 )); then
        echo "expected exit status 0, got $status" >&2
        echo "$output" >&2
        return 1
    fi
    assert_contains "$output" "aws ssm start-session --profile test-profile --target i-0abc123 --region us-east-1" && \
    [[ "$output" != *"--document-name"* ]]
}

test_ec2_fallback_multi_match_uses_interactive_picker() {
    local output status
    output=$(AWS_PROFILE=test-profile MOCK_EC2_INSTANCES=$'i-aaa\tweb-01\trunning\ni-bbb\tweb-02\trunning' \
        "$SCRIPT" prod web --dry-run 2>&1)
    status=$?
    if (( status != 0 )); then
        echo "expected exit status 0, got $status" >&2
        echo "$output" >&2
        return 1
    fi
    assert_contains "$output" "aws ssm start-session --profile test-profile --target i-aaa --region us-east-1"
}

test_ec2_fallback_reachable_when_env_has_no_tsv_rows() {
    local output status
    output=$(AWS_PROFILE=test-profile MOCK_EC2_INSTANCES=$'i-0zzz999\tweb-99\trunning' \
        "$SCRIPT" staging web-99 --dry-run 2>&1)
    status=$?
    if (( status != 0 )); then
        echo "expected exit status 0, got $status" >&2
        echo "$output" >&2
        return 1
    fi
    assert_contains "$output" "aws ssm start-session --profile test-profile --target i-0zzz999 --region us-east-1"
}

test_ec2_fallback_aws_failure_is_not_misreported_as_not_found() {
    local output status
    output=$(MOCK_AWS_FAIL=true "$SCRIPT" prod totally-unknown-name --dry-run 2>&1)
    status=$?
    if (( status == 0 )); then
        echo "expected non-zero exit, got 0" >&2
        echo "$output" >&2
        return 1
    fi
    assert_contains "$output" "aws ec2 describe-instances failed" && \
    [[ "$output" != *"no connection or EC2 instance matching"* ]]
}

test_ec2_fallback_cancel_disambiguation_picker_exits_silently() (
    fzf() {
        local arg query=""
        for arg in "$@"; do
            case "$arg" in
                --filter=*) query="${arg#--filter=}" ;;
            esac
        done
        if [[ -n "$query" ]]; then
            awk -v query="$query" 'index($0, query) { print }'
        else
            return 1
        fi
    }
    export -f fzf
    local output status
    output=$(AWS_PROFILE=test-profile MOCK_EC2_INSTANCES=$'i-aaa\tweb-01\trunning\ni-bbb\tweb-02\trunning' \
        "$SCRIPT" prod web 2>&1)
    status=$?
    if (( status != 0 )); then
        echo "expected exit status 0, got $status" >&2
        echo "$output" >&2
        return 1
    fi
    if [[ -n "$output" ]]; then
        echo "expected no output on cancel, got: $output" >&2
        return 1
    fi
)

test_kube_tmux_readiness_timeout_kills_session() (
    local test_tmp_dir fixture_dir output status
    test_tmp_dir=$(mktemp -d "${TMPDIR:-/tmp}/ssm-connect-test.XXXXXX") || return 1
    trap 'rm -rf "$test_tmp_dir"' EXIT
    fixture_dir="${test_tmp_dir}/fixture"
    mkdir "$fixture_dir" || return 1
    ln -s "$SCRIPT" "${fixture_dir}/connect.sh" || return 1
    printf 'fake-kube\tprod\tkubernetes\ti-fakejump0000\tfake.invalid.example\t59999\n' \
        > "${fixture_dir}/connections.tsv"

    output=$(HEALTH_STARTUP_TIMEOUT=1 SSM_CONNECT_CONFIG="${fixture_dir}/connections.tsv" \
        "${fixture_dir}/connect.sh" prod fake-kube --tmux 2>&1)
    status=$?
    if (( status == 0 )); then
        echo "expected non-zero exit, got 0" >&2
        echo "$output" >&2
        return 1
    fi
    assert_contains "$output" "killing session" && assert_contains "$output" "TMUX_SESSION_KILLED"
)

test_ping_status_blocks_non_online_instance() {
    local output status
    output=$(MOCK_PING_STATUS=ConnectionLost "$SCRIPT" prod rdp-app 2>&1)
    status=$?
    if (( status == 0 )); then
        echo "expected non-zero exit, got 0" >&2
        echo "$output" >&2
        return 1
    fi
    assert_contains "$output" "PingStatus is 'ConnectionLost'"
}

test_ping_status_check_failure_warns_and_proceeds() {
    local output status
    output=$(MOCK_PING_CHECK_FAIL=true "$SCRIPT" prod rdp-app --tmux 2>&1)
    status=$?
    if (( status != 0 )); then
        echo "expected exit status 0, got $status" >&2
        echo "$output" >&2
        return 1
    fi
    assert_contains "$output" "Warning: could not check SSM ping status" && \
    assert_contains "$output" "Started tmux session"
}

test_ping_status_skipped_on_dry_run() {
    local output status
    output=$(MOCK_PING_STATUS=ConnectionLost "$SCRIPT" prod rdp-app --dry-run 2>&1)
    status=$?
    if (( status != 0 )); then
        echo "expected exit status 0, got $status" >&2
        echo "$output" >&2
        return 1
    fi
    assert_contains "$output" "aws ssm start-session"
}

run_test() {
    local name="$1"
    if "$name"; then
        echo "ok - $name"
    else
        echo "not ok - $name"
        (( failures++ ))
    fi
}

run_test test_tmux_uses_resolved_selection
run_test test_tmux_propagates_aws_profile
run_test test_tmux_kill_does_not_require_aws
run_test test_tmux_escapes_script_path
run_test test_rejects_tmux_and_tmux_kill_together
run_test test_rejects_tmux_kill_and_dry_run_together
run_test test_tmux_session_name_is_env_scoped
run_test test_duplicate_row_in_same_env_is_rejected
run_test test_ec2_fallback_dry_run_for_unmatched_name
run_test test_ec2_fallback_multi_match_uses_interactive_picker
run_test test_ec2_fallback_reachable_when_env_has_no_tsv_rows
run_test test_ec2_fallback_aws_failure_is_not_misreported_as_not_found
run_test test_ec2_fallback_cancel_disambiguation_picker_exits_silently
run_test test_kube_tmux_readiness_timeout_kills_session
run_test test_ping_status_blocks_non_online_instance
run_test test_ping_status_check_failure_warns_and_proceeds
run_test test_ping_status_skipped_on_dry_run

if (( failures > 0 )); then
    echo "$failures test(s) failed" >&2
    exit 1
fi

echo "all tests passed"
