# lab-infra

Builds the infrastructure of the lab: an on-prem Kubernetes platform simulated on a single Windows host with Hyper-V, Ansible, k3s, ArgoCD and GitHub Actions.

## Status

Today:

- PowerShell scripts that create and delete lab VMs on Hyper-V from a generalized base image. Each VM gets its hostname, IP, SSH host keys and automation user on first boot through cloud-init.
- An Ansible playbook that configures the base system and installs a single-node k3s cluster.
- One command that rebuilds a VM and its cluster.

Next: a bastion VM that operates the cluster.

## How it fits together

```
Windows host (Hyper-V)                         WSL (control node)
  hyperv/create-vm.ps1                           ansible/site.yml
    base image + seed disk (cloud-init)  --->      roles: base, k3s
    = VM with name, IP and the ansible user        = configured VM + k3s
                                                   + ~/.kube/<host>.yaml
```

- **Hyper-V scripts** play the role of IT: they hand over a VM that is reachable over SSH by the automation user, and nothing else.
- **cloud-init** sets only what makes the VM reachable: hostname, network and the `ansible` user with its key.
- **Ansible** declares the full state of the system and keeps it that way.

## Capacity and hardware

What a machine needs to replicate the lab. The figures are estimates with some headroom; only the k3s baseline below is measured.

### Host requirements

| Resource | Current stage (one VM)                          | Full lab (three clusters and a bastion) |
| -------- | ----------------------------------------------- | --------------------------------------- |
| OS       | Windows 10/11 Pro or Enterprise (Hyper-V)       | Same                                    |
| CPU      | 4 cores with virtualization enabled in firmware | 8 cores or more                         |
| RAM      | 16 GB (8 GB for the VM, the rest for the host)  | 32 GB                                   |
| Disk     | SSD with 60 GB free                             | SSD with 150 GB free                    |

### VM sizing

| VM                                                | vCPU | RAM  | Notes                                             |
| ------------------------------------------------- | ---- | ---- | ------------------------------------------------- |
| `lab-vm` (single-node k3s, later the dev cluster) | 4    | 8 GB | Hosts the apps, Kafka, ArgoCD and the CI runners. |
| bastion (planned)                                 | 2    | 2 GB | Tools only, no cluster.                           |
| stage and prod clusters (planned)                 | 2–4  | 4 GB | Without CI runners.                               |

Memory is static (dynamic memory is disabled), so a running VM always takes its full amount from the host.

### Measured baseline

An empty k3s node uses about **1 GB of RAM and 0.1 CPU**. Most of it is the k3s process itself (API server, scheduler, controllers, kubelet and the datastore run in a single binary, not as pods) plus Ubuntu. That is the fixed cost of every cluster before the first app.

### Disk

Each VM gets a full copy of the base image (no differencing disks), so a VM starts at the size of the base image and grows with container images and volumes. Budget about 30 GB per VM. The seed disk adds 64 MB.

### What competes for the host's memory

Windows itself, WSL (by default it may take up to half of the host's RAM; cap it with `memory=` in `.wslconfig`), Docker Desktop and the browser. Check the host before adding a VM: if Windows starts paging, lower the VM's `-Memory` or stop a VM.

## Host setup (once)

### Hyper-V network

An internal switch with NAT. The host is the gateway at `192.168.100.1` and the VMs live in `192.168.100.0/24`, a range that does not clash with typical home networks or with WSL. Windows allows only one NAT: check `Get-NetNat` first.

```powershell
New-VMSwitch -Name "LabSwitch" -SwitchType Internal
New-NetIPAddress -IPAddress 192.168.100.1 -PrefixLength 24 -InterfaceAlias "vEthernet (LabSwitch)"
New-NetNat -Name "LabNAT" -InternalIPInterfaceAddressPrefix 192.168.100.0/24
```

There is no DHCP on this network: every VM gets a static IP from its seed disk.

### WSL

WSL uses mirrored networking, so it reaches the VMs and shares `localhost` with Windows. In `%UserProfile%\.wslconfig`:

```ini
[wsl2]
networkingMode=mirrored
```

Run `wsl --shutdown` after changing it, and restart Docker Desktop after any network change.

### Control node (WSL)

- Ansible: `pipx install --include-deps ansible`.
- `kubectl`, within one minor version of the cluster.
- The automation key pair. The public key goes in `ansible/inventories/lab/group_vars/all.yml`; the private key never leaves WSL and is never committed:

    ```bash
    ssh-keygen -t ed25519 -C "ansible@lab" -f ~/.ssh/lab_ansible -N ""
    ```

## Base image

`C:\Lab\base\ubuntu-26.04-base-v2.vhdx`, read-only, with its SHA256 next to it in `ubuntu-26.04-base-v2.vhdx.sha256` (ASCII). It is **generalized**: it has no IP, no SSH host keys, no machine-id and no cloud-init state. A VM created from it without a seed disk boots without network, on purpose.

The version is part of the file name. A new version never overwrites the previous one, which stays as a fallback until the new one is proven.

### Building it

1. **Install Ubuntu Server 26.04** on a Generation 2 VM attached to `LabSwitch`, with the `MicrosoftUEFICertificateAuthority` secure boot template:
    - A static IP in the lab range (it is removed later), gateway `192.168.100.1`.
    - An admin user with a password, for console access and `sudo`.
    - "Install OpenSSH server", importing your SSH key from GitHub.
2. **Install the Hyper-V integration tools**, so the VM reports its IP to the host (`hv-kvp-daemon`):

    ```bash
    sudo apt install -y linux-cloud-tools-virtual
    ```

3. **Generalize** it. Starting from an existing base image, create a builder VM with the previous version of the image instead of steps 1 and 2. Then, over SSH:

    ```bash
    # Re-enable cloud-init and drop the installer's config
    sudo rm /etc/cloud/cloud-init.disabled
    sudo rm /etc/cloud/cloud.cfg.d/99-installer.cfg \
            /etc/cloud/cloud.cfg.d/00-subiquity-disable-cloudinit-networking.cfg
    echo 'datasource_list: [ NoCloud, None ]' | sudo tee /etc/cloud/cloud.cfg.d/90-datasource.cfg

    # The network comes from each VM's seed disk
    sudo rm /etc/netplan/00-installer-config.yaml

    # Patch the template before sealing it
    sudo apt-get update && sudo apt-get -y full-upgrade && sudo apt-get clean

    # Generalize: cloud-init state, logs, seed, machine-id, SSH host keys
    sudo cloud-init clean --logs --seed --machine-id
    sudo rm -f /etc/ssh/ssh_host_*

    rm -f ~/.bash_history && history -c
    sudo poweroff
    ```

    Power off, never reboot: on the next boot cloud-init would run and the image would no longer be clean.

4. **Seal it** on Windows, with the next version number:

    ```powershell
    $base = "C:\Lab\base\ubuntu-26.04-base-v2.vhdx"
    Copy-Item C:\Lab\vms\image-builder.vhdx $base
    Set-ItemProperty -Path $base -Name IsReadOnly -Value $true
    (Get-FileHash $base -Algorithm SHA256).Hash | Out-File "$base.sha256" -Encoding ascii
    .\hyperv\delete-vm.ps1 -Name image-builder
    ```

    Copy the disk before deleting the builder: `delete-vm.ps1` deletes it too.

## Hyper-V VM scripts

The scripts live in `hyperv/` and run on Windows in an elevated Windows PowerShell 5.1 (`#Requires -RunAsAdministrator`). `create-vm.ps1` and `delete-vm.ps1` are idempotent: running them twice leaves the host in the same state. `rebuild-vm.ps1` is not, on purpose: every run destroys the VM and creates a new one. From WSL's copy of the repo:

```powershell
powershell -ExecutionPolicy Bypass -File \\wsl.localhost\Ubuntu\home\<user>\lab\lab-infra\hyperv\create-vm.ps1 -Name lab-vm -IpAddress 192.168.100.10
```

### create-vm.ps1

```powershell
.\hyperv\create-vm.ps1 -Name lab-vm -IpAddress 192.168.100.10
```

| Parameter        | Default                                  | Description                                                              |
| ---------------- | ---------------------------------------- | ------------------------------------------------------------------------ |
| `-Name`          | required                                 | VM name, hostname and name of its disks. Use the inventory hostname.     |
| `-IpAddress`     | required                                 | Static IPv4 address of the VM.                                           |
| `-PrefixLength`  | `24`                                     | Network prefix length.                                                   |
| `-Gateway`       | `192.168.100.1`                          | Default gateway: the host's address on `LabSwitch`.                      |
| `-DnsServers`    | `1.1.1.1`, `8.8.8.8`                     | DNS servers.                                                             |
| `-CpuCount`      | `4`                                      | Virtual processors.                                                      |
| `-Memory`        | `8GB`                                    | Startup memory. Dynamic memory is disabled, so this is the fixed amount. |
| `-BaseImagePath` | `C:\Lab\base\ubuntu-26.04-base-v2.vhdx`  | Generalized base disk copied for each VM.                                |
| `-VmFolder`      | `C:\Lab\vms`                             | Folder that holds the VM disks.                                          |
| `-SwitchName`    | `LabSwitch`                              | Virtual switch the VM connects to.                                       |
| `-GroupVarsPath` | the lab inventory's `group_vars/all.yml` | File the automation public key is read from.                             |

What it does:

1. Exits without changes if a VM with that name already exists.
2. Reads `automation_public_key` from the Ansible inventory, so the key has a single source of truth.
3. Copies the base image to `<VmFolder>\<Name>.vhdx` and clears the read-only attribute the copy inherits.
4. Builds the cloud-init seed disk `<VmFolder>\<Name>-seed.vhdx`: a FAT32 volume labeled `CIDATA` with
    - `meta-data`: a new `instance-id` (so cloud-init treats the boot as a first boot) and the hostname;
    - `network-config`: the static IP, gateway and DNS, matched by the Hyper-V network driver;
    - `user-data`: the `ansible` user with its public key, passwordless `sudo` and no password.

    The files are written as UTF-8 without BOM and with LF line endings: cloud-init ignores a `user-data` that does not start exactly with `#cloud-config`.

5. Creates a Generation 2 VM with both disks, sets the CPU count, static memory, the `MicrosoftUEFICertificateAuthority` secure boot template (required to boot Linux), and disables automatic checkpoints.
6. Starts the VM and waits up to 3 minutes for it to report the requested IP. It fails if it does not.

Each new VM has new SSH host keys. Before connecting to a recreated VM, forget the old ones in WSL:

```bash
ssh-keygen -R 192.168.100.10
```

### delete-vm.ps1

```powershell
.\hyperv\delete-vm.ps1 -Name lab-vm
```

| Parameter   | Default      | Description                     |
| ----------- | ------------ | ------------------------------- |
| `-Name`     | required     | VM to delete.                   |
| `-VmFolder` | `C:\Lab\vms` | Folder that holds the VM disks. |

What it does:

1. Stops the VM if it is running, then removes it. Reports when it does not exist.
2. Deletes `<VmFolder>\<Name>.vhdx` and `<VmFolder>\<Name>-seed.vhdx` if they exist.

## Ansible

Runs from WSL, in `ansible/`. The connection settings live in the inventory (`inventories/lab/hosts.yml`), so a plain run is enough:

```bash
cd ansible
ansible-playbook site.yml
```

A VM created by `create-vm.ps1` is ready for this from its first boot: the `ansible` user and its key come from cloud-init.

| Role   | What it declares                                                                                                                                                                                                                                                   |
| ------ | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------ |
| `base` | The automation user, its key and `sudo` rule; the hostname; base packages; unattended security upgrades; swap off; the kernel modules and parameters Kubernetes needs; a `ufw` firewall that allows only SSH, the Kubernetes API and the pod and service networks. |
| `k3s`  | k3s at a pinned version (`k3s_version` in the role defaults), its config file, and the kubeconfig copied to the control node as `~/.kube/<host>.yaml`, pointing to the VM's IP.                                                                                    |

Ubuntu 26.04 ships `sudo-rs` as `sudo`, and Ansible times out waiting for its prompt. `ansible.cfg` sets `become_exe = sudo.ws` to use the classic `sudo` until Ansible supports `sudo-rs`.

Then point `kubectl` to the cluster:

```bash
export KUBECONFIG=~/.kube/lab-vm.yaml
kubectl get nodes
```

## Rebuilding a VM and its cluster

One command, from an elevated Windows PowerShell:

```powershell
powershell -ExecutionPolicy Bypass -File \\wsl.localhost\Ubuntu\home\<user>\lab\lab-infra\hyperv\rebuild-vm.ps1 -Name lab-vm
```

| Parameter   | Default  | Description                                    |
| ----------- | -------- | ---------------------------------------------- |
| `-Name`     | required | Inventory hostname of the VM to rebuild.       |
| `-CpuCount` | `4`      | Virtual processors, passed to `create-vm.ps1`. |
| `-Memory`   | `8GB`    | Startup memory, passed to `create-vm.ps1`.     |

What it does:

1. Finds the WSL distribution and the `ansible/` folder from its own `\\wsl.localhost` path, so Ansible runs in the same clone. It fails if run from a copy outside WSL.
2. Reads the VM's IP from the inventory with `ansible-inventory --host`: the inventory is the single source of truth. It fails before deleting anything if the host is not in the inventory.
3. Runs `delete-vm.ps1` and `create-vm.ps1`.
4. Forgets the old SSH host keys of that IP in WSL.
5. Waits with `wait_for_connection` until SSH accepts the automation user, trusting the new host key on first use (`StrictHostKeyChecking=accept-new`). A key that changes afterwards is still rejected.
6. Runs `ansible-playbook site.yml --limit <Name>`.

Commands in WSL run through a login shell (`bash -lc`), so tools installed with pipx are on the `PATH`, and their exit codes are checked: a failing step stops the script.

Then:

```bash
kubectl get nodes
```

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

| Repository                                                              | Role                                                                                                                                   |
| ----------------------------------------------------------------------- | -------------------------------------------------------------------------------------------------------------------------------------- |
| [lab-infra](https://github.com/CarlosFerOrduna/lab-infra)               | Builds the infrastructure: Hyper-V VMs, their base image, and Ansible for the system and k3s. Holds the repository settings checklist. |
| [lab-gitops](https://github.com/CarlosFerOrduna/lab-gitops)             | Desired state of the clusters. ArgoCD applies whatever is in this repo.                                                                |
| [lab-ci-workflows](https://github.com/CarlosFerOrduna/lab-ci-workflows) | Reusable GitHub Actions workflows shared by every lab repo.                                                                            |
| [lab-processor](https://github.com/CarlosFerOrduna/lab-processor)       | Shared processor service, namespace `platform`.                                                                                        |
| [lab-producer-a](https://github.com/CarlosFerOrduna/lab-producer-a)     | Producer service, namespace `producer-a`.                                                                                              |
| [lab-producer-b](https://github.com/CarlosFerOrduna/lab-producer-b)     | Producer service, namespace `producer-b`.                                                                                              |
