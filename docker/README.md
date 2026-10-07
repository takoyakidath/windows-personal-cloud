# docker/

Docker Engine runs **inside WSL2 Ubuntu** (not Docker Desktop), installed by
`installer/wsl/install-docker.sh`. Its API is only on the local unix socket and is never
exposed over TCP.

## Adding a service

1. Put the compose project inside the WSL filesystem, e.g. `~/services/my-app/compose.yaml`
   (keep volumes and `node_modules` in WSL, not on `D:\`, product.txt §12.1).
2. List it under `modes.SERVER.compose` in `config/services.json`:

   ```json
   "SERVER": { "start": ["tailscale", "ssh", "smb", "wsl", "docker"], "stop": [], "compose": ["~/services/my-app"] }
   ```

3. `winctl server` starts it (`docker compose up -d`).

## Blocking night sleep from a container

Containers labelled `wpc.inhibit-sleep=true` (see `power.inhibit_docker_label`) stop the
21:00 hibernate while they are running — use it for long batch jobs:

```yaml
services:
  nightly-job:
    labels:
      wpc.inhibit-sleep: "true"
```
