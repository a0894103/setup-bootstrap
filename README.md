# setup-bootstrap

New-machine bootstrap for the owner's own PCs (public: contains only install scripts and a public SSH key, no secrets).

On a fresh Windows, open PowerShell **as administrator** and run (one UAC):

```powershell
irm https://raw.githubusercontent.com/a0894103/setup-bootstrap/main/bootstrap.ps1 | iex
```

Build machine: run `$Roles = 'user,dev,build'` first. Source of truth: `tools/setup/` in the private AI_AGENT_ULTRA repo.