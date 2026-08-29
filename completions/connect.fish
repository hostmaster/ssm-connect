# Fish completion for connect.sh / ssm-connect
#
# Install:
#   cp completions/connect.fish ~/.config/fish/completions/ssm-connect.fish
#
# For connect.sh when invoked from PATH (without ./):
#   cp completions/connect.fish ~/.config/fish/completions/connect.sh.fish

function __ssm_connect_config
    if set -q SSM_CONNECT_CONFIG
        echo $SSM_CONNECT_CONFIG
        return
    end
    set -l cmd (commandline -opc)[1]
    set -l full (command -v $cmd 2>/dev/null; or echo $cmd)
    set -l real (realpath $full 2>/dev/null; or echo $full)
    echo (dirname $real)/connections.tsv
end

function __ssm_connect_positional_count
    set -l count 0
    for t in (commandline -opc)[2..-1]
        string match -q -- '-*' $t; or set count (math $count + 1)
    end
    echo $count
end

function __ssm_connect_env_arg
    for t in (commandline -opc)[2..-1]
        string match -q -- '-*' $t; or begin; echo $t; return; end
    end
end

function __ssm_connect_envs
    set -l config (__ssm_connect_config)
    if test -f $config
        awk -F'\t' '!/^[[:space:]]*#/ && NF { print $2 }' $config | sort -u
    else
        printf '%s\n' prod dev
    end
end

function __ssm_connect_names
    set -l config (__ssm_connect_config)
    test -f $config; or return
    set -l env (__ssm_connect_env_arg)
    awk -F'\t' -v e="$env" \
        '!/^[[:space:]]*#/ && NF && (e == "" || $2 == e) { print $1 }' $config
end

for _cmd in ssm-connect connect.sh
    complete -c $_cmd -f
    complete -c $_cmd -l loop      -d 'Auto-reconnect when the session exits'
    complete -c $_cmd -l tmux      -d 'Run inside a detached tmux session'
    complete -c $_cmd -l tmux-kill -d 'Kill the detached tmux session for this connection'
    complete -c $_cmd -l dry-run   -d 'Print the SSM command without executing'
    complete -c $_cmd -s h -l help -d 'Show usage'
    complete -c $_cmd -n 'test (__ssm_connect_positional_count) -eq 0' \
        -a '(__ssm_connect_envs)'
    complete -c $_cmd -n 'test (__ssm_connect_positional_count) -eq 1' \
        -a '(__ssm_connect_names)'
end
