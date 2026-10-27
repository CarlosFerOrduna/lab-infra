# lab-infra

Builds the infrastructure of the lab: an on-prem Kubernetes platform simulated on a single Windows host with Hyper-V, Ansible, k3s, ArgoCD and GitHub Actions.

## Status

Today: two PowerShell scripts that create and delete the lab VMs on Hyper-V.

Planned: Ansible playbooks that configure the VMs and install k3s.

## Hyper-V VM scripts

Both scripts live in `hyperv/`, run on Windows in an elevated PowerShell (`#Requires -RunAsAdministrator`) and are idempotent: running them twice leaves the host in the same state.

### Prerequisites

- The Hyper-V Windows feature enabled.
- The base disk at `C:\Lab\base\ubuntu-26.04-base.vhdx` (or the path passed in `-BaseImagePath`).
- An existing Hyper-V virtual switch named `LabSwitch` (or the name passed in `-SwitchName`).

### create-vm.ps1

```powershell
.\hyperv\create-vm.ps1 -Name lab
```

| Parameter        | Default                              | Description                                                              |
| ---------------- | ------------------------------------ | ------------------------------------------------------------------------ |
| `-Name`          | `lab`                                | VM name. Also the name of its disk.                                      |
| `-CpuCount`      | `4`                                  | Virtual processors.                                                      |
| `-Memory`        | `8GB`                                | Startup memory. Dynamic memory is disabled, so this is the fixed amount. |
| `-BaseImagePath` | `C:\Lab\base\ubuntu-26.04-base.vhdx` | Base disk copied for each VM.                                            |
| `-VmFolder`      | `C:\Lab\vms`                         | Folder that holds the VM disks.                                          |
| `-SwitchName`    | `LabSwitch`                          | Virtual switch the VM connects to.                                       |

What it does:

1. Exits without changes if a VM with that name already exists.
2. Copies the base image to `<VmFolder>\<Name>.vhdx` and clears the read-only attribute the copy inherits.
3. Creates a Generation 2 VM attached to that disk and switch.
4. Sets the CPU count, static memory, the `MicrosoftUEFICertificateAuthority` secure boot template (required to boot Linux), and disables automatic checkpoints.
5. Starts the VM and waits up to 3 minutes for it to report an IPv4 address. It fails if none appears.

### delete-vm.ps1

```powershell
.\hyperv\delete-vm.ps1 -Name lab
```

| Parameter   | Default      | Description                    |
| ----------- | ------------ | ------------------------------ |
| `-Name`     | `lab`        | VM to delete.                  |
| `-VmFolder` | `C:\Lab\vms` | Folder that holds the VM disk. |

What it does:

1. Stops the VM if it is running, then removes it. Reports when it does not exist.
2. Deletes `<VmFolder>\<Name>.vhdx` if it exists.

## Repository settings

GitHub settings are applied by hand. Check them when creating a lab repository.

All repositories:

- [ ] Public.
- [ ] Secret scanning enabled.
- [ ] Push protection enabled.

Infrastructure repositories (lab-infra, lab-gitops, lab-ci-workflows):

- [ ] Branch protection on `main`: pull requests required with 0 approvals, linear history required, no bypass.
- [ ] Only rebase merging allowed.
- [ ] Head branches deleted automatically after merge.

Service repositories (lab-processor, lab-producer-a, lab-producer-b):

- [ ] A ruleset named `fixed-branches` that targets `main`, `development` and `stage`, restricts deletions and blocks force pushes. It does not require pull requests: changes are merged locally and pushed.

## Lab repositories

| Repository                                                              | Role                                                                                                         |
| ----------------------------------------------------------------------- | ------------------------------------------------------------------------------------------------------------ |
| [lab-infra](https://github.com/CarlosFerOrduna/lab-infra)               | Builds the infrastructure: Hyper-V VMs today, Ansible and k3s next. Holds the repository settings checklist. |
| [lab-gitops](https://github.com/CarlosFerOrduna/lab-gitops)             | Desired state of the clusters. ArgoCD applies whatever is in this repo.                                      |
| [lab-ci-workflows](https://github.com/CarlosFerOrduna/lab-ci-workflows) | Reusable GitHub Actions workflows shared by every lab repo.                                                  |
| [lab-processor](https://github.com/CarlosFerOrduna/lab-processor)       | Shared processor service, namespace `platform`.                                                              |
| [lab-producer-a](https://github.com/CarlosFerOrduna/lab-producer-a)     | Producer service, namespace `producer-a`.                                                                    |
| [lab-producer-b](https://github.com/CarlosFerOrduna/lab-producer-b)     | Producer service, namespace `producer-b`.                                                                    |
