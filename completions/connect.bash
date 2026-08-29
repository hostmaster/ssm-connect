# Bash completion for connect.sh / ssm-connect
#
# Install (pick one):
#   source "$(pwd)/completions/connect.bash"        # per-session
#   echo 'source /path/to/completions/connect.bash' >> ~/.bashrc
#   cp completions/connect.bash /etc/bash_completion.d/ssm-connect
#   cp completions/connect.bash ~/.local/share/bash-completion/completions/ssm-connect

_ssm_connect_config() {
    if [[ -n "$SSM_CONNECT_CONFIG" ]]; then
        printf '%s' "$SSM_CONNECT_CONFIG"
        return
    fi
    local cmd_path real
    cmd_path=$(command -v "${COMP_WORDS[0]}" 2>/dev/null || echo "${COMP_WORDS[0]}")
    real=$(realpath "$cmd_path" 2>/dev/null || echo "$cmd_path")
    printf '%s/connections.tsv' "$(dirname "$real")"
}

_ssm_connect() {
    local cur words cword
    if declare -f _init_completion >/dev/null 2>&1; then
        _init_completion || return
    else
        cur="${COMP_WORDS[COMP_CWORD]}"
        words=("${COMP_WORDS[@]}")
        cword="$COMP_CWORD"
    fi

    # Flags at any position
    if [[ "$cur" == --* ]]; then
        COMPREPLY=($(compgen -W "--loop --tmux --tmux-kill --dry-run --help" -- "$cur"))
        return
    fi

    # Collect positional args already present (skip command and flags)
    local positionals=() i
    for (( i = 1; i < cword; i++ )); do
        [[ "${words[i]}" == --* ]] || positionals+=("${words[i]}")
    done

    local config
    config=$(_ssm_connect_config)

    case ${#positionals[@]} in
        0)  # completing env
            local envs="prod dev"
            if [[ -f "$config" ]]; then
                envs=$(awk -F'\t' '!/^[[:space:]]*#/ && NF { print $2 }' "$config" | sort -u)
            fi
            COMPREPLY=($(compgen -W "$envs" -- "$cur"))
            ;;
        1)  # completing name, filtered by env
            if [[ -f "$config" ]]; then
                local env="${positionals[0]}" names
                names=$(awk -F'\t' -v e="$env" \
                    '!/^[[:space:]]*#/ && NF && (e == "" || $2 == e) { print $1 }' "$config")
                COMPREPLY=($(compgen -W "$names" -- "$cur"))
            fi
            ;;
    esac
}

complete -F _ssm_connect connect.sh ssm-connect
