# ssm-connect

Bash helper for AWS SSM port-forwarding tunnels (RDP, databases, Kubernetes) and direct EC2 shell sessions.

## Requirements

- [AWS CLI](https://aws.amazon.com/cli/) with the [Session Manager plugin](https://docs.aws.amazon.com/systems-manager/latest/userguide/session-manager-working-with-install-plugin.html)
- `fzf` — interactive picker and fuzzy name matching
- `curl` — required (Kubernetes health checks)
- `tmux` — optional; required for `--tmux` / `--tmux-kill`

## Setup

```bash
cp connections.tsv.example connections.tsv
# Edit connections.tsv with your hosts, ports, and instance IDs
chmod +x connect.sh
```

## Usage

```
connect.sh [env] [name] [--loop] [--tmux] [--tmux-kill] [--dry-run]
```

| Command | Action |
|---------|--------|
| `./connect.sh` | Interactive picker (all connections) |
| `./connect.sh prod` | Picker filtered by env |
| `./connect.sh prod redis-prod` | Connect directly |
| `./connect.sh prod web-01` | EC2 fallback: SSM shell to instance `web-01` |
| `./connect.sh prod kube-prod --loop --tmux` | Persistent tunnel in detached tmux |

Flags can appear anywhere in the argument list.

## Configuration

Connections live in `connections.tsv` (tab-separated). See `connections.tsv.example` for the format.

| Column | Description |
|--------|-------------|
| `name` | Unique slug for CLI selection |
| `env` | Environment label |
| `type` | `rdp`, `redis`, `mariadb`, `postgres`, `kubernetes` |
| `target` | EC2 instance ID (`i-…` → direct SSM target; `-` → jump host via `JUMP_HOST_TAG_TEMPLATE`) |
| `host` | Remote hostname; `-` for direct port forward to the instance (RDP) |
| `lport` | Local bind port |

**EC2 behaviour**

| `target` | `host` | Result |
|----------|--------|--------|
| `i-…` | `-` | Port-forward to that instance (RDP) |
| `-` | hostname | Jump host lookup, forward to remote host (DB, Redis, K8s) |
| *(CLI only)* | — | `./connect.sh prod web-01` → SSM shell to EC2 with `Environment=prod` and `Name=web-01` |

When `target` is `-`, the jump host EC2 `Name` tag must match `JUMP_HOST_TAG_TEMPLATE` (e.g. `acme-{env}-{region}-jmp`). RDS/ElastiCache hostnames typically use `{org}-prod-{service}` in prod and `{org}-dev-{service}` in dev.

### Environment variables

| Variable | Default | Purpose |
|----------|---------|---------|
| `AWS_PROFILE` | `default` | AWS CLI profile |
| `AWS_REGION` / `AWS_DEFAULT_REGION` | `us-east-1` | AWS region |
| `JUMP_HOST_TAG_TEMPLATE` | `jump-{env}-{region}` | Jump host Name tag; use your org prefix (e.g. `acme-{env}-{region}-jmp`) |
| `SSM_CONNECT_CONFIG` | `./connections.tsv` | Alternate config path |

## Shell completion

```bash
source completions/connect.bash   # bash
# zsh: symlink completions/connect.zsh into $fpath as _ssm-connect
# fish: cp completions/connect.fish ~/.config/fish/completions/ssm-connect.fish
```

## Tests

```bash
./tests/connect_test.sh
```
