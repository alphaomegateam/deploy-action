# Deploy Action

Composite GitHub Action for deploying Docker Compose applications via SSH.

## Usage

```yaml
- uses: alphaomegateam/deploy-action@v1
  with:
    tool-name: my-app
    server-path: ~/tools/my-app
    health-url: https://my-app.example.com/health
  env:
    SSH_HOST: ${{ secrets.SSH_HOST }}
    SSH_USER: ${{ secrets.SSH_USER }}
    SSH_PRIVATE_KEY: ${{ secrets.SSH_PRIVATE_KEY }}
    SLACK_WEBHOOK_URL: ${{ secrets.SLACK_WEBHOOK_URL }}
```

## Inputs

| Input | Required | Default | Description |
|-------|----------|---------|-------------|
| `tool-name` | Yes | - | Name of the tool (e.g., `n8n`, `calcom`) |
| `server-path` | Yes | - | Path to tool on server (e.g., `~/tools/n8n`) |
| `health-url` | Yes | - | URL to check for health after deployment |
| `build` | No | `false` | Run `docker compose build` before `up` |

## Required Secrets

These must be set at the organization level:

- `SSH_HOST` - Server IP address
- `SSH_USER` - SSH username (typically `deploy`)
- `SSH_PRIVATE_KEY` - Private SSH key for authentication
- `SLACK_WEBHOOK_URL` - Slack webhook for failure notifications

## What It Does

1. Connects to server via SSH
2. Saves current commit hash (for rollback)
3. Pulls latest changes from main
4. Pulls Docker images
5. (Optional) Builds Docker images if `build: true`
6. Restarts containers with `docker compose up -d`
7. Waits 30 seconds for startup
8. Runs health check
9. On failure: rolls back to previous commit and notifies Slack

## Example: Custom Image (with build)

```yaml
- uses: alphaomegateam/deploy-action@v1
  with:
    tool-name: my-custom-app
    server-path: ~/tools/my-custom-app
    health-url: https://my-custom-app.example.com/health
    build: true
  env:
    SSH_HOST: ${{ secrets.SSH_HOST }}
    SSH_USER: ${{ secrets.SSH_USER }}
    SSH_PRIVATE_KEY: ${{ secrets.SSH_PRIVATE_KEY }}
    SLACK_WEBHOOK_URL: ${{ secrets.SLACK_WEBHOOK_URL }}
```

## Deploy over the tailnet

`tailnet: 'true'` makes the runner join the tailnet as a short-lived `tag:ci` node and SSH to `aot` over its tailnet address (`100.118.68.8`) instead of `SSH_HOST`. Login is GitHub OIDC (Tailscale federated identity `TbMv9UXgdr11CNTRL-kTjbcbLzBJ11CNTRL`, created 2026-11-14): no secret. Only `main` branches of `alphaomegateam` repos can use it, and the tailnet policy (homelab `docs/tailscale/policy.hujson`) lets `tag:ci` reach only `tag:monitoring:22`.

```yaml
jobs:
  deploy:
    runs-on: ubuntu-latest
    permissions:
      id-token: write
      contents: read
    steps:
      - uses: actions/checkout@v4
      - uses: alphaomegateam/deploy-action@v1
        with:
          tool-name: Kener
          server-path: ~/tools/kener
          health-url: https://status.alphaomegateam.co/healthcheck
          tailnet: 'true'
        env: { SSH_HOST: ..., SSH_USER: ..., SSH_PRIVATE_KEY: ..., SLACK_WEBHOOK_URL: ... }
```

Token exchange errors show only on the identity's page in the Tailscale console (Settings, Trust credentials).
