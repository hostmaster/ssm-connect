#compdef connect.sh ssm-connect

# Zsh completion for connect.sh / ssm-connect
#
# Install (pick one):
#   ln -s "$(pwd)/completions/connect.zsh" ~/.zsh/completions/_ssm-connect
#   Then add to ~/.zshrc (if not already present):
#     fpath=(~/.zsh/completions $fpath)
#     autoload -Uz compinit && compinit

_ssm_connect() {
    local cmd_path real config

    if [[ -n "$SSM_CONNECT_CONFIG" ]]; then
        config="$SSM_CONNECT_CONFIG"
    else
        cmd_path=$(whence -p "${words[1]}" 2>/dev/null || echo "${words[1]}")
        real=$(realpath "$cmd_path" 2>/dev/null || echo "$cmd_path")
        config="$(dirname "$real")/connections.tsv"
    fi

    # Collect positional args before the cursor (skip flags)
    local -a positionals
    local w
    for w in "${(@)words[2,CURRENT-1]}"; do
        [[ "$w" == -* ]] || positionals+=("$w")
    done

    # Flags at any position
    if [[ "${words[CURRENT]}" == -* ]]; then
        compadd -- --loop --tmux --tmux-kill --dry-run --help
        return
    fi

    case ${#positionals} in
        0)  # completing env
            local -a envs
            if [[ -f "$config" ]]; then
                envs=(${(f)"$(awk -F'\t' '!/^[[:space:]]*#/ && NF { print $2 }' "$config" | sort -u)"})
            else
                envs=(prod dev)
            fi
            compadd -- "${envs[@]}"
            ;;
        1)  # completing name, filtered by env
            if [[ -f "$config" ]]; then
                local env_filter="${positionals[1]}"
                local -a names
                names=(${(f)"$(awk -F'\t' -v e="$env_filter" \
                    '!/^[[:space:]]*#/ && NF && (e == "" || $2 == e) { print $1 }' "$config")"})
                compadd -- "${names[@]}"
            fi
            ;;
    esac
}

_ssm_connect
