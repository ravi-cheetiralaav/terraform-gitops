---
title: Tofu Controller GitOps Guide
description: Operate Flux IAC Tofu Controller resources and inspect plans, status, logs, and Terraform outputs.
author: Platform Engineering
ms.date: 2026-08-27
ms.topic: how-to
keywords:
  - Flux
  - OpenTofu
  - Terraform
  - Kubernetes
  - GitOps
estimated_reading_time: 8
---

## Overview

Tofu Controller is a Flux controller that runs OpenTofu or Terraform from a
Kubernetes cluster. It turns an IaC configuration in Git into a Kubernetes
`Terraform` custom resource. Flux reconciles that resource, and Tofu Controller
performs the requested OpenTofu or Terraform actions in a runner Pod.

The workflow is:

1. Store OpenTofu or Terraform configuration and a `Terraform` custom resource
   in Git.
2. Flux synchronizes the resource to the Kubernetes cluster.
3. Tofu Controller watches the resource and starts a runner Pod.
4. The runner initializes providers, creates a plan, and optionally applies it.
5. The controller records the reconciliation result in the resource status.
6. The controller repeats reconciliation at the configured interval and can
   detect and remediate drift.

The controller stores its Terraform state as a Kubernetes Secret. You can also
configure selected Terraform output values to be written to a separate Secret.

> [!IMPORTANT]
> A Kubernetes Secret encodes data using Base64. Base64 is not encryption. Use
> Kubernetes RBAC and a suitable secrets-management approach to protect
> sensitive output values.

## Example Terraform Resource

The following resource instructs the controller to source configuration from a
Flux `GitRepository`, reconcile every ten minutes, and automatically apply
approved plans.

```yaml
apiVersion: infra.contrib.fluxcd.io/v1alpha2
kind: Terraform
metadata:
  name: network
  namespace: flux-system
spec:
  interval: 10m
  path: ./infrastructure/network
  approvePlan: auto
  sourceRef:
    kind: GitRepository
    name: platform-config
    namespace: flux-system
```

`approvePlan: auto` enables automatic plan and apply. To require approval,
remove that setting. The controller places the generated plan identifier in
`status.plan.pending`. Commit that exact identifier into `spec.approvePlan` to
approve and apply the plan through GitOps.

## Inspect Reconciliation Status

Confirm that the controller custom resource definition is installed, then list
all managed Terraform resources.

```bash
kubectl get crd terraforms.infra.contrib.fluxcd.io
kubectl get terraform -A
```

Inspect a particular resource in the `flux-system` namespace.

```bash
kubectl get terraform network -n flux-system
kubectl describe terraform network -n flux-system
kubectl get terraform network -n flux-system -o yaml
```

Check the condition messages in a compact form.

```bash
kubectl get terraform network -n flux-system \
  -o jsonpath='{range .status.conditions[*]}{.type}={.status}; {.reason}; {.message}{"\n"}{end}'
```

Review these fields in `status`:

* `conditions` indicates success, failure, and the controller message
* `lastAppliedRevision` identifies the Git revision successfully applied
* `lastAttemptedRevision` identifies the revision from the latest attempt
* `plan.pending` contains an unapproved plan identifier
* `lastDriftDetectedAt` records the latest drift detection time
* `availableOutputs` lists published Terraform output names
* `reconciliationFailures` counts failures since the last successful reconcile

View Kubernetes events when a reconciliation fails or is waiting for a
dependency, credential, or plan approval.

```bash
kubectl get events -n flux-system --sort-by=.lastTimestamp
```

## Inspect Runner Logs

Tofu Controller performs OpenTofu or Terraform operations in runner Pods. List
the most recent Pods and then retrieve logs from the relevant runner.

```bash
kubectl get pods -n flux-system --sort-by=.metadata.creationTimestamp
kubectl logs -n flux-system <runner-pod-name> --all-containers
```

Runner Pods are cleaned up after reconciliation by default. Keep them during an
investigation by adding the following to the `Terraform` resource, then commit
and reconcile the Git change:

```yaml
spec:
  alwaysCleanupRunnerPod: false
```

Set `alwaysCleanupRunnerPod` back to `true` after troubleshooting to prevent
completed runner Pods from accumulating.

## Publish and Read Terraform Outputs

Use `writeOutputsToSecret` in the `Terraform` resource to publish selected
Terraform outputs to a Kubernetes Secret.

```yaml
spec:
  writeOutputsToSecret:
    name: network-outputs
    outputs:
      - vnet_id
      - subnet_id
```

After a successful reconciliation, inspect the Secret:

```bash
kubectl get secret network-outputs -n flux-system -o yaml
```

Secret values are Base64-encoded. Decode a single output using its key:

```bash
kubectl get secret network-outputs -n flux-system \
  -o jsonpath='{.data.vnet_id}' | base64 --decode; echo
```

For the existing `helloworld-output` Secret, decode the `hello_world` output:

```bash
kubectl get secret helloworld-output -n flux-system \
  -o jsonpath='{.data.hello_world}' | base64 --decode; echo
```

The encoded value `SGVsbG8gV29ybGQh` decodes to:

```text
Hello, World!
```

Decode every output in a Secret when `jq` is installed:

```bash
kubectl get secret helloworld-output -n flux-system -o json |
  jq -r '.data | to_entries[] | "\(.key)=\(.value | @base64d)"'
```

## Trigger an Immediate Reconciliation

The controller normally follows `spec.interval`. Request an immediate Flux
reconciliation without changing the desired Terraform configuration:

```bash
kubectl annotate terraform network -n flux-system \
  reconcile.fluxcd.io/requestedAt="$(date -Iseconds)" --overwrite
```

Then watch the resource state change:

```bash
kubectl get terraform network -n flux-system --watch
```

## Optional tfctl Commands

The `tfctl` command-line tool provides controller-specific operations including
`get`, `plan`, `reconcile`, `suspend`, and `resume`. It uses the active
Kubernetes context unless a kubeconfig and namespace are specified.

```bash
tfctl get --namespace flux-system
tfctl reconcile network --namespace flux-system
```

Use `tfctl --help` and `tfctl <command> --help` to confirm the supported
arguments for the installed version.

## Reference Links

* [Tofu Controller overview](https://flux-iac.github.io/tofu-controller/)
* [Getting started](https://flux-iac.github.io/tofu-controller/getting_started/)
* [Tofu Controller usage guides](https://flux-iac.github.io/tofu-controller/use-tf-controller/)
* [Terraform custom resource API reference](https://flux-iac.github.io/tofu-controller/References/terraform/)
* [tfctl command-line reference](https://flux-iac.github.io/tofu-controller/tfctl/)
* [Flux documentation](https://fluxcd.io/flux/)