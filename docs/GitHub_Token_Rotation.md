---
title: GitHub PAT Rotation Runbook
description: How to rotate the GitHub personal access token used by Flux and local automation for this repository.
author: Platform Engineering
ms.date: 2026-08-28
ms.topic: how-to
keywords:
  - Flux
  - GitHub
  - Secrets
  - Token Rotation
estimated_reading_time: 4
---

## When to Rotate

Rotate the GitHub PAT immediately if it was ever pasted into a chat session,
shared in logs, committed to Git, or otherwise exposed outside your own
terminal — exposure to a chat/AI session counts as exposure, since it becomes
part of session context/logs, not just terminal scrollback.

## Where the Token Is Used

| Location | Purpose |
|---|---|
| GitHub | The token itself (Settings > Developer settings > Personal access tokens) |
| Local shell env vars (`$env:GITHUB_TOKEN` in PowerShell, `GITHUB_TOKEN` in bash) | Used by `flux bootstrap` and `scripts/bootstrap-e2e.sh` |
| `flux-system/flux-system` Secret in-cluster | Actively used by `source-controller` to authenticate Git pulls for the `flux-system` `GitRepository` |

## Step 1: Revoke the Old Token

Go to <https://github.com/settings/tokens>, find the exposed token, and
**Delete**/**Revoke** it.

## Step 2: Generate a New Token

Create a new PAT with the same scopes as before (`repo` access is required
for `flux bootstrap --token-auth` to manage the repository).

## Step 3: Enter the New Token Without It Being Visible

**PowerShell:**

```powershell
$secure = Read-Host -Prompt "Enter new GitHub token" -AsSecureString
$env:GITHUB_TOKEN = [System.Runtime.InteropServices.Marshal]::PtrToStringAuto(
    [System.Runtime.InteropServices.Marshal]::SecureStringToBSTR($secure)
)
```

**Bash:**

```bash
read -s -p "Enter new GitHub token: " GITHUB_TOKEN
export GITHUB_TOKEN
echo
```

## Step 4: Update the In-Cluster Secret

This is the credential Flux actually uses for ongoing Git reconciliation.

```bash
kubectl create secret generic flux-system -n flux-system \
  --from-literal=username=git \
  --from-literal=password="$GITHUB_TOKEN" \
  --dry-run=client -o yaml | kubectl apply -f -
```

## Step 5: Force Reconciliation

```bash
kubectl annotate gitrepository flux-system -n flux-system \
  reconcile.fluxcd.io/requestedAt="$(date -Iseconds)" --overwrite
```

## Step 6: Verify

```bash
kubectl get gitrepository flux-system -n flux-system
```

Confirm `READY` is `True` and the reported revision matches the latest commit.
