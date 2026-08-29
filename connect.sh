#!/usr/bin/env bash
set -euo pipefail

REGION="${AWS_REGION:-${AWS_DEFAULT_REGION:-us-east-1}}"
AWS_PROFILE="${AWS_PROFILE:-default}"
export AWS_PROFILE
# Jump host EC2 Name tag when target is "-". Placeholders: {env}, {region}
JUMP_HOST_TAG_TEMPLATE="${JUMP_HOST_TAG_TEMPLATE:-jump-{env}-{region}}"
SLEEP_INTERVAL="${SLEEP_INTERVAL:-5}"
HEALTH_INTERVAL="${HEALTH_INTERVAL:-30}"
HEALTH_FAIL_THRESHOLD="${HEALTH_FAIL_THRESHOLD:-3}"
HEALTH_STARTUP_TIMEOUT="${HEALTH_STARTUP_TIMEOUT:-30}"
HEALTH_GRACE_PERIOD="${HEALTH_GRACE_PERIOD:-15}"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONFIG="${SSM_CONNECT_CONFIG:-${SCRIPT_DIR}/connections.tsv}"
STATE_DIR="${XDG_RUNTIME_DIR:-${TMPDIR:-/tmp}}/ssm-connect"

usage() {
    local status="${1:-1}"
    local text
    text=$(cat <<EOF
Usage: $(basename "$0") [env] [name] [--loop] [--tmux] [--tmux-kill] [--dry-run]

  env         Filter by environment: prod or dev
  name        Connection name (slug from connections.tsv), or an EC2 instance
              Name tag if it doesn't match any connections.tsv entry — opens
              a direct SSM shell session (no port forwarding) to a running
              instance tagged Environment=<env>
  --loop      Auto-reconnect when the session exits
  --tmux      Run inside a detached tmux session named ssm-<env>-<name>
  --tmux-kill Kill the detached tmux session for the selected connection
  --dry-run   Print the SSM command without executing

Examples:
  $(basename "$0")                              # interactive fzf picker
  $(basename "$0") prod                         # fzf picker, prod only
  $(basename "$0") prod redis-prod              # connect directly
  $(basename "$0") prod kube-prod --loop        # connect and auto-reconnect
  $(basename "$0") prod kube-prod --loop --tmux # connect in detached tmux
  $(basename "$0") prod kube-prod --tmux-kill   # kill the tmux session
  $(basename "$0") prod web-01                  # direct SSM shell (EC2 fallback)
EOF
    )

    if (( status == 0 )); then
        echo "$text"
    else
        echo "$text" >&2
    fi

    exit "$status"
}

check_deps() {
    local missing=() tool
    for tool in "$@"; do
        command -v "$tool" >/dev/null 2>&1 || missing+=("$tool")
    done
    if (( ${#missing[@]} > 0 )); then
        echo "Error: missing required tools: ${missing[*]}" >&2
        exit 1
    fi
}

LOOP=false
DRY_RUN=false
TMUX_MODE=false
TMUX_KILL=false
POSITIONAL=()

for arg in "$@"; do
    case "$arg" in
        --loop)      LOOP=true ;;
        --dry-run)   DRY_RUN=true ;;
        --tmux)      TMUX_MODE=true ;;
        --tmux-kill) TMUX_KILL=true ;;
        -h|--help)   usage 0 ;;
        -*)          echo "Unknown option: $arg" >&2; usage 1 ;;
        *)           POSITIONAL+=("$arg") ;;
    esac
done

if (( ${#POSITIONAL[@]} > 2 )); then
    echo "Error: too many arguments (expected: [env] [name])" >&2
    usage 1
fi

if [[ "$TMUX_KILL" == true && "$TMUX_MODE" == true ]]; then
    echo "Error: --tmux and --tmux-kill are mutually exclusive" >&2
    exit 1
fi
if [[ "$TMUX_KILL" == true && "$DRY_RUN" == true ]]; then
    echo "Error: --tmux-kill and --dry-run are mutually exclusive" >&2
    exit 1
fi

[[ -f "$CONFIG" ]] || { echo "Error: config not found: $CONFIG" >&2; exit 1; }

deps=(fzf)
[[ "$TMUX_MODE" == true || "$TMUX_KILL" == true ]] && deps+=(tmux)
check_deps "${deps[@]}"

ENV_FILTER="${POSITIONAL[0]:-}"
NAME_FILTER="${POSITIONAL[1]:-}"

# Prints TSV rows matching env (all rows if env is empty). Uses tab FS.
filter_rows() {
    local env_filter="$1"
    awk -F'\t' -v env="$env_filter" '
        /^[[:space:]]*#/ || /^[[:space:]]*$/ { next }
        env == "" || $2 == env { print }
    ' "$CONFIG"
}

# Presents rows in fzf; prints selected name, or returns empty on cancel.
# Optional second arg pre-fills the fzf query (used for fuzzy disambiguation).
pick_connection() {
    local rows="$1"
    local query="${2:-}"
    local selected fzf_args
    fzf_args=(
        --prompt="SSM Connect > "
        --height=40%
        --reverse
        --header="$(printf '%-25s %-5s %-12s %s' NAME ENV TYPE LPORT)"
    )
    [[ -n "$query" ]] && fzf_args+=(--query="$query")
    selected=$(
        printf '%s\n' "$rows" | \
        awk -F'\t' '{printf "%-25s %-5s %-12s %s\n", $1, $2, $3, $6}' | \
        fzf "${fzf_args[@]}"
    ) || true
    [[ -z "$selected" ]] && return 0
    awk '{print $1}' <<< "$selected"
}

# Lists running EC2 instances tagged Environment=<env>. Prints TSV rows:
# instance-id<TAB>name<TAB>state (name falls back to the instance ID when no
# Name tag is set).
find_ec2_instances() {
    local env="$1"
    local output
    # shellcheck disable=SC2016  # JMESPath literal, not a shell expansion
    if ! output=$(aws ec2 describe-instances \
        --profile "$AWS_PROFILE" \
        --filters \
            "Name=tag:Environment,Values=${env}" \
            "Name=instance-state-name,Values=running" \
        --region "$REGION" \
        --query 'Reservations[].Instances[].[InstanceId,Tags[?Key==`Name`]|[0].Value,State.Name]' \
        --output text 2>&1); then
        echo "Error: aws ec2 describe-instances failed: ${output}" >&2
        return 1
    fi
    printf '%s\n' "$output" | awk -F'\t' 'BEGIN{OFS="\t"} { if ($2 == "None" || $2 == "") $2=$1; print }'
}

# Presents EC2 instances (id\tname\tstate rows) in fzf; prints the selected
# row (id\tname\tstate), or empty on cancel. Pre-formats the display line
# (name, state, id) and lets fzf search the whole thing, then looks the
# chosen line back up by instance ID — same pattern as pick_connection.
# (--nth combined with --with-nth reindexes what --nth searches, so a naive
# "--nth=2 --with-nth=2,3,1" silently searches the wrong field — avoid that.)
pick_ec2_instance() {
    local rows="$1"
    local query="${2:-}"
    local selected id fzf_args
    fzf_args=(
        --prompt="SSM Connect (EC2) > "
        --height=40%
        --reverse
        --header="$(printf '%-30s %-10s %s' NAME STATE INSTANCE-ID)"
    )
    [[ -n "$query" ]] && fzf_args+=(--query="$query")
    selected=$(
        printf '%s\n' "$rows" | \
        awk -F'\t' '{printf "%-30s %-10s %s\n", $2, $3, $1}' | \
        fzf "${fzf_args[@]}"
    ) || true
    [[ -z "$selected" ]] && return 0
    id=$(awk '{print $NF}' <<< "$selected")
    awk -F'\t' -v id="$id" '$1 == id' <<< "$rows"
}

# Fallback used when name_filter has no match in connections.tsv: looks up a
# running EC2 instance tagged Environment=<env> whose Name tag matches
# name_filter, for a direct (non-port-forwarding) SSM shell session. Prints a
# synthetic connections.tsv-style row (type=ec2-shell) on match, or nothing.
# Runs inside a `$(...)` command substitution, so `exit` here would only kill
# that subshell — callers must instead branch on the return status:
#   0 + non-empty stdout: matched, row printed
#   0 + empty stdout:     no match found — caller reports "not found"
#   1:                    the EC2 lookup itself failed (aws error already
#                         printed by find_ec2_instances) — caller should
#                         exit 1 without adding a "not found" message
#   2:                    user cancelled an interactive picker — caller
#                         should exit 0 silently
resolve_ec2_row() {
    local env="$1" name_filter="$2"
    local instances selected id name _state count

    instances=$(find_ec2_instances "$env") || return 1
    [[ -z "$instances" ]] && return 0

    selected=$(printf '%s\n' "$instances" | fzf --delimiter=$'\t' --nth=2 --filter="$name_filter" || true)
    [[ -z "$selected" ]] && return 0
    count=$(wc -l <<< "$selected" | tr -d ' ')
    if (( count > 1 )); then
        selected=$(pick_ec2_instance "$instances" "$name_filter")
        [[ -z "$selected" ]] && return 2
    fi

    IFS=$'\t' read -r id name _state <<< "$selected"
    # name comes from an arbitrary, untrusted EC2 Name tag — sanitize before
    # it becomes C_NAME, since C_NAME is later used unescaped as a tmux
    # session name (':' is the tmux session:window separator) and as a
    # STATE_DIR marker filename component ('/' would create a bogus path).
    local safe_name
    safe_name=$(printf '%s' "$name" | tr -c 'A-Za-z0-9._-' '_')
    printf '%s\t%s\t%s\t%s\t%s\t%s\n' "$safe_name" "$env" "ec2-shell" "$id" "-" "-"
}

rport_for_type() {
    case "$1" in
        redis)      echo 6379 ;;
        rdp)        echo 3389 ;;
        mariadb)    echo 3306 ;;
        postgres)   echo 5432 ;;
        kubernetes) echo 443  ;;
        *)
            echo "Error: unknown connection type '${1}'" >&2
            exit 1
            ;;
    esac
}

# Looks up a connections.tsv row by name slug.
row_by_name() {
    awk -F'\t' -v name="$1" '$1 == name' <<< "$2"
}

ROWS=$(filter_rows "$ENV_FILTER")

# Only fatal when there's no name to fall back to an EC2 lookup with — the
# interactive picker below needs at least one row to browse.
if [[ -z "$ROWS" && -z "$NAME_FILTER" ]]; then
    echo "Error: no connections found for env: '${ENV_FILTER}'" >&2
    exit 1
fi

ROW=""
if [[ -n "$NAME_FILTER" ]]; then
    MATCHED=$(printf '%s\n' "$ROWS" | awk -F'\t' '{print $1}' | fzf --filter="$NAME_FILTER" || true)
    if [[ -z "$MATCHED" ]]; then
        check_deps aws
        ec2_status=0
        ROW=$(resolve_ec2_row "$ENV_FILTER" "$NAME_FILTER") || ec2_status=$?
        if (( ec2_status == 2 )); then
            exit 0
        elif (( ec2_status == 1 )); then
            exit 1
        fi
        [[ -z "$ROW" ]] && {
            echo "Error: no connection or EC2 instance matching '${NAME_FILTER}' in env '${ENV_FILTER}'" >&2
            exit 1
        }
    elif [[ $(wc -l <<< "$MATCHED" | tr -d ' ') -eq 1 ]]; then
        ROW=$(row_by_name "$MATCHED" "$ROWS")
    else
        SELECTED_NAME=$(pick_connection "$ROWS" "$NAME_FILTER")
        [[ -z "$SELECTED_NAME" ]] && exit 0
        ROW=$(row_by_name "$SELECTED_NAME" "$ROWS")
    fi
else
    SELECTED_NAME=$(pick_connection "$ROWS")
    [[ -z "$SELECTED_NAME" ]] && exit 0
    ROW=$(row_by_name "$SELECTED_NAME" "$ROWS")
fi

if [[ -z "$ROW" ]]; then
    echo "Error: internal: resolved name not found in connections.tsv" >&2
    exit 1
fi

ROW_COUNT=$(wc -l <<< "$ROW" | tr -d ' ')
if (( ROW_COUNT > 1 )); then
    echo "Error: ${ROW_COUNT} rows resolved for this selection — fix the duplicate name in connections.tsv" >&2
    exit 1
fi

IFS=$'\t' read -r C_NAME C_ENV C_TYPE C_TARGET C_HOST C_LPORT <<< "$ROW"

if [[ -z "$C_NAME" || -z "$C_ENV" || -z "$C_TYPE" || -z "$C_TARGET" || -z "$C_HOST" || -z "$C_LPORT" ]]; then
    echo "Error: malformed row in connections.tsv (missing fields): $ROW" >&2
    exit 1
fi

TMUX_SESSION="ssm-${C_ENV}-${C_NAME}"
mkdir -p "$STATE_DIR"
chmod 700 "$STATE_DIR" 2>/dev/null || true
OWNED_MARKER="${STATE_DIR}/${C_ENV}-${C_NAME}.owned"

if [[ "$TMUX_KILL" == true ]]; then
    if [[ ! -f "$OWNED_MARKER" ]]; then
        echo "This invocation never started a tunnel for '${C_NAME}' — leaving it alone." >&2
        exit 0
    fi
    rm -f "$OWNED_MARKER"
    if tmux has-session -t "$TMUX_SESSION" 2>/dev/null; then
        tmux kill-session -t "$TMUX_SESSION"
        echo "Killed tmux session '${TMUX_SESSION}'." >&2
    else
        echo "No tmux session '${TMUX_SESSION}' found." >&2
    fi
    exit 0
fi

if [[ "$C_TYPE" != "ec2-shell" ]]; then
    RPORT=$(rport_for_type "$C_TYPE")
    if ! [[ "$C_LPORT" =~ ^[0-9]+$ ]]; then
        echo "Error: local port is not numeric for '${C_NAME}': '${C_LPORT}'" >&2
        exit 1
    fi
fi

kube_tunnel_alive() {
    local host="$1" port="$2"
    # Skip TLS verify: EKS cert is issued for :443, not the local forward port.
    curl -skf --connect-timeout 3 --max-time 5 \
        --resolve "${host}:${port}:127.0.0.1" \
        "https://${host}:${port}/livez" >/dev/null 2>&1
}

ssm_plugins_for_port() {
    local port="$1"
    # Backstop only (stop_ssm_session kills by PID/PGID first). Anchored on
    # both sides of the port digits (skipping non-digit separators like
    # '=' or '":[' after "localPortNumber") so port 443 can't substring-match
    # a plugin actually bound to 8443 or 4430.
    pgrep -f "localPortNumber[^0-9]*${port}([^0-9]|\$)" 2>/dev/null || true
}

# True only if $pid is both alive and still the same process we recorded in
# SSM_PID_STARTED — guards against the OS recycling $pid for an unrelated
# process between when we backgrounded the session and when we check on it.
pid_matches_started() {
    local pid="$1"
    [[ -z "${SSM_PID_STARTED:-}" ]] && return 0
    local now
    now=$(ps -o lstart= -p "$pid" 2>/dev/null)
    [[ -n "$now" && "$now" == "$SSM_PID_STARTED" ]]
}

ssm_session_alive() {
    local port="$1" pid="$2"
    if [[ -n "$pid" ]] && kill -0 "$pid" 2>/dev/null && pid_matches_started "$pid"; then
        return 0
    fi
    [[ -n "$(ssm_plugins_for_port "$port")" ]]
}

stop_ssm_session() {
    local port="$1" pid="${2:-}"
    if [[ -n "$pid" ]] && kill -0 "$pid" 2>/dev/null && pid_matches_started "$pid"; then
        kill -TERM "$pid" 2>/dev/null || true
        pkill -TERM -P "$pid" 2>/dev/null || true
        wait "$pid" 2>/dev/null || true
    fi
    local plugin_pids plugin_pid
    plugin_pids=$(ssm_plugins_for_port "$port")
    [[ -z "$plugin_pids" ]] && return 0
    while IFS= read -r plugin_pid; do
        [[ -n "$plugin_pid" ]] && kill -TERM "$plugin_pid" 2>/dev/null || true
    done <<< "$plugin_pids"
    sleep 1
    while IFS= read -r plugin_pid; do
        [[ -n "$plugin_pid" ]] && kill -KILL "$plugin_pid" 2>/dev/null || true
    done < <(ssm_plugins_for_port "$port")
}

wait_for_kube_tunnel() {
    local host="$1" port="$2" ssm_pid="$3"
    local deadline=$(( SECONDS + HEALTH_STARTUP_TIMEOUT ))
    while (( SECONDS < deadline )); do
        ssm_session_alive "$port" "$ssm_pid" || return 1
        if kube_tunnel_alive "$host" "$port"; then
            return 0
        fi
        sleep 2
    done
    return 1
}

# Returns EC2 instance ID. If target starts with i-, returns it directly.
# Otherwise looks up jump host by EC2 Name tag (JUMP_HOST_TAG_TEMPLATE).
resolve_instance() {
    local target="$1" env="$2"
    if [[ "$target" == i-* ]]; then
        echo "$target"
        return
    fi
    local tag="${JUMP_HOST_TAG_TEMPLATE//\{env\}/$env}"
    tag="${tag//\{region\}/$REGION}"
    local id
    id=$(aws ec2 describe-instances \
        --profile "$AWS_PROFILE" \
        --filters \
            "Name=tag:Name,Values=${tag}" \
            "Name=instance-state-name,Values=running" \
        --query 'Reservations[].Instances[].[InstanceId]' \
        --region "$REGION" \
        --output text)
    if [[ -z "$id" || "$id" == "None" ]]; then
        echo "Error: no running instance found for tag Name=${tag}" >&2
        exit 1
    fi
    local count
    count=$(wc -l <<< "$id" | tr -d ' ')
    if (( count > 1 )); then
        echo "Error: ${count} instances match tag Name=${tag} — expected exactly 1" >&2
        exit 1
    fi
    echo "$id"
}

# Checks the SSM agent's PingStatus for an instance before connecting, so a
# non-Online agent (crashed, missing instance profile, no network to the SSM
# endpoint) reports clearly instead of surfacing as an opaque start-session
# failure. If the check itself can't be performed (e.g. missing
# ssm:DescribeInstanceInformation permission), warns and proceeds rather than
# blocking a connection that might otherwise work.
check_ssm_ping_status() {
    local instance_id="$1"
    local ping_status
    if ! ping_status=$(aws ssm describe-instance-information \
        --profile "$AWS_PROFILE" \
        --filters "Key=InstanceIds,Values=${instance_id}" \
        --region "$REGION" \
        --query 'InstanceInformationList[0].PingStatus' \
        --output text 2>&1); then
        echo "Warning: could not check SSM ping status for '${instance_id}': ${ping_status}" >&2
        return 0
    fi
    if [[ -z "$ping_status" || "$ping_status" == "None" ]]; then
        echo "Error: instance '${instance_id}' is not registered with SSM (no PingStatus) — check the SSM agent and instance profile" >&2
        exit 1
    fi
    if [[ "$ping_status" != "Online" ]]; then
        echo "Error: instance '${instance_id}' SSM PingStatus is '${ping_status}' (not Online) — connection would fail" >&2
        exit 1
    fi
}

check_deps aws

if [[ "$DRY_RUN" == true && "$C_TARGET" != i-* ]]; then
    INSTANCE_ID="<jump-host-id>"
else
    INSTANCE_ID=$(resolve_instance "$C_TARGET" "$C_ENV")
fi

[[ "$DRY_RUN" == true ]] || check_ssm_ping_status "$INSTANCE_ID"

CMD=(aws ssm start-session --profile "$AWS_PROFILE" --target "$INSTANCE_ID" --region "$REGION")

if [[ "$C_TYPE" == "ec2-shell" ]]; then
    : # plain interactive shell session — no document/parameters needed
elif [[ "$C_HOST" == "-" ]]; then
    CMD+=(
        --document-name AWS-StartPortForwardingSession
        --parameters "localPortNumber=${C_LPORT},portNumber=${RPORT}"
    )
else
    CMD+=(
        --document-name AWS-StartPortForwardingSessionToRemoteHost
        --parameters "host=${C_HOST},portNumber=${RPORT},localPortNumber=${C_LPORT}"
    )
fi

if [[ "$DRY_RUN" == true ]]; then
    echo "${CMD[*]}"
    exit 0
fi

if [[ "$TMUX_MODE" == true ]]; then
    if [[ "$C_TYPE" == kubernetes ]]; then
        check_deps curl
        if kube_tunnel_alive "$C_HOST" "$C_LPORT"; then
            echo "Tunnel for '${C_NAME}' is already up and healthy — reusing it." >&2
            exit 0
        fi
    fi

    # Build the args to pass to the recursive call, minus --tmux
    TMUX_ARGS=("$C_ENV" "$C_NAME")
    [[ "$LOOP" == true ]] && TMUX_ARGS+=(--loop)
    if tmux has-session -t "$TMUX_SESSION" 2>/dev/null; then
        echo "Session '${TMUX_SESSION}' already exists. Attaching..." >&2
        exec tmux attach-session -t "$TMUX_SESSION"
    fi
    # printf %q for each arg is portable back to bash 3.x (macOS default).
    # A new tmux session's environment comes from the tmux server's global
    # environment (captured when the server first started), not this client's
    # live shell — every var the child script reads via ${VAR:-default} must
    # be forwarded explicitly here or an operator's override silently reverts
    # to the default inside the detached session.
    TMUX_CMD_STR="AWS_PROFILE=$(printf '%q' "$AWS_PROFILE")"
    TMUX_CMD_STR+=" AWS_REGION=$(printf '%q' "$REGION")"
    TMUX_CMD_STR+=" JUMP_HOST_TAG_TEMPLATE=$(printf '%q' "$JUMP_HOST_TAG_TEMPLATE")"
    [[ -n "${SSM_CONNECT_CONFIG:-}" ]] && \
        TMUX_CMD_STR+=" SSM_CONNECT_CONFIG=$(printf '%q' "$SSM_CONNECT_CONFIG")"
    TMUX_CMD_STR+=" SLEEP_INTERVAL=$(printf '%q' "$SLEEP_INTERVAL")"
    TMUX_CMD_STR+=" HEALTH_INTERVAL=$(printf '%q' "$HEALTH_INTERVAL")"
    TMUX_CMD_STR+=" HEALTH_FAIL_THRESHOLD=$(printf '%q' "$HEALTH_FAIL_THRESHOLD")"
    TMUX_CMD_STR+=" HEALTH_STARTUP_TIMEOUT=$(printf '%q' "$HEALTH_STARTUP_TIMEOUT")"
    TMUX_CMD_STR+=" HEALTH_GRACE_PERIOD=$(printf '%q' "$HEALTH_GRACE_PERIOD")"
    TMUX_CMD_STR+=" $(printf '%q' "${BASH_SOURCE[0]}")"
    for a in "${TMUX_ARGS[@]}"; do
        TMUX_CMD_STR+=" $(printf '%q' "$a")"
    done
    if ! tmux new-session -d -s "$TMUX_SESSION" \
        "${TMUX_CMD_STR}; read -rp 'Press Enter to close...'"; then
        # A concurrent invocation may have won the race between our
        # has-session check above and this new-session call.
        if tmux has-session -t "$TMUX_SESSION" 2>/dev/null; then
            echo "Session '${TMUX_SESSION}' was just started by a concurrent invocation. Attaching..." >&2
            exec tmux attach-session -t "$TMUX_SESSION"
        fi
        echo "Error: failed to start tmux session '${TMUX_SESSION}'" >&2
        exit 1
    fi
    echo "Started tmux session '${TMUX_SESSION}'." >&2
    echo "Attach with: tmux attach -t ${TMUX_SESSION}" >&2

    if [[ "$C_TYPE" == kubernetes ]]; then
        echo -n "Waiting for tunnel to become ready..." >&2
        deadline=$(( SECONDS + HEALTH_STARTUP_TIMEOUT ))
        until kube_tunnel_alive "$C_HOST" "$C_LPORT"; do
            if (( SECONDS >= deadline )); then
                echo >&2
                echo "Error: tunnel did not become ready within ${HEALTH_STARTUP_TIMEOUT}s — killing session '${TMUX_SESSION}'" >&2
                tmux kill-session -t "$TMUX_SESSION" 2>/dev/null || true
                exit 1
            fi
            echo -n "." >&2
            sleep 2
        done
        echo " ready." >&2
    fi
    touch "$OWNED_MARKER"
    exit 0
fi

print_connection_info() {
    if [[ "$C_TYPE" == "ec2-shell" ]]; then
        echo "Connection: name=${C_NAME} env=${C_ENV} instance=${C_TARGET} (type=ec2-shell, direct session)" >&2
    else
        echo "Connection: name=${C_NAME} env=${C_ENV} local_port=${C_LPORT} (type=${C_TYPE})" >&2
    fi
}

handle_loop_reconnect() {
    local start_ts="$1"
    local elapsed=$(( $(date +%s) - start_ts ))
    if (( elapsed < 10 )); then
        (( quick_failures++ )) || true
    else
        quick_failures=0
    fi
    if (( quick_failures >= 3 )); then
        echo "Error: 3 consecutive quick failures — possible auth or config issue. Stopping loop." >&2
        exit 1
    fi
    echo "Session ended. Reconnecting in ${SLEEP_INTERVAL}s..." >&2
    sleep "$SLEEP_INTERVAL"
}

if [[ "$LOOP" == true ]]; then
    echo "Loop mode — Ctrl+C to stop." >&2
    quick_failures=0
    ssm_pid=""
    SSM_PID_STARTED=""
    cleanup() {
        stop_ssm_session "$C_LPORT" "$ssm_pid"
        exit 130
    }
    trap cleanup INT TERM
    if [[ "$C_TYPE" == kubernetes ]]; then
        check_deps curl
        echo "Kubernetes health checks enabled (/livez every ${HEALTH_INTERVAL}s)." >&2
    fi
    while true; do
        print_connection_info
        start_ts=$(date +%s)
        if [[ "$C_TYPE" == kubernetes ]]; then
            health_failures=0
            stop_ssm_session "$C_LPORT"
            "${CMD[@]}" &
            ssm_pid=$!
            SSM_PID_STARTED=$(ps -o lstart= -p "$ssm_pid" 2>/dev/null)
            if wait_for_kube_tunnel "$C_HOST" "$C_LPORT" "$ssm_pid"; then
                echo "Tunnel ready (kubernetes /livez OK)." >&2
                # Reference point for the grace period is when the tunnel
                # actually became ready, not when this loop iteration started
                # — using start_ts here made the grace period dead code,
                # since wait_for_kube_tunnel (up to HEALTH_STARTUP_TIMEOUT)
                # plus the first HEALTH_INTERVAL sleep already exceeds it.
                ready_ts=$(date +%s)
                while ssm_session_alive "$C_LPORT" "$ssm_pid"; do
                    sleep "$HEALTH_INTERVAL"
                    ssm_session_alive "$C_LPORT" "$ssm_pid" || break
                    if (( $(date +%s) - ready_ts < HEALTH_GRACE_PERIOD )); then
                        continue
                    fi
                    if kube_tunnel_alive "$C_HOST" "$C_LPORT"; then
                        health_failures=0
                    else
                        (( health_failures++ )) || true
                        echo "Health check failed (${health_failures}/${HEALTH_FAIL_THRESHOLD})" >&2
                        if (( health_failures >= HEALTH_FAIL_THRESHOLD )); then
                            echo "Tunnel unhealthy — reconnecting." >&2
                            stop_ssm_session "$C_LPORT" "$ssm_pid"
                            break
                        fi
                    fi
                done
            else
                if ssm_session_alive "$C_LPORT" "$ssm_pid"; then
                    echo "Warning: tunnel did not become ready within ${HEALTH_STARTUP_TIMEOUT}s — reconnecting." >&2
                    stop_ssm_session "$C_LPORT" "$ssm_pid"
                fi
            fi
            stop_ssm_session "$C_LPORT" "$ssm_pid"
        else
            "${CMD[@]}" || true
        fi
        handle_loop_reconnect "$start_ts"
    done
else
    print_connection_info
    exec "${CMD[@]}"
fi
