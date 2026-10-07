# SSH public keys

Public keys only. **Never put private keys here.**

- `authorized_keys` — your own keys (Mac etc.), one per line. Full shell access.
- `controller.pub` — the Raspberry Pi controller's key. Installed with a forced
  command (`winctl remote`), so it can only run allowlisted winctl commands.

Both files are optional. If no key is present, the installer leaves
password authentication enabled and prints a warning.
