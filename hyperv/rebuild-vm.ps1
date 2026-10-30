#Requires -RunAsAdministrator

# rebuild-vm.ps1
# Rebuilds a lab VM from scratch and configures it with Ansible:
# delete the VM, create it again, trust its new SSH host key, run the playbook.
# Run it from the repository clone inside WSL, through its \\wsl.localhost path:
# Ansible runs in that same clone.
param(
    [Parameter(Mandatory)]
    [string]$Name,

    [int] $CpuCount = 4,
    [long]$Memory   = 8GB
)

$ErrorActionPreference = "Stop"

# 1. Find the WSL distribution and the Ansible folder from this script's own path
if ($PSScriptRoot -notmatch '^\\\\wsl(?:\.localhost|\$)\\([^\\]+)(\\.+)\\hyperv$') {
    throw "Run this script from the repository clone inside WSL (\\wsl.localhost\<distro>\...), not from '$PSScriptRoot'."
}
$distro     = $Matches[1]
$ansibleDir = ($Matches[2] -replace '\\', '/') + "/ansible"

# Runs a command in WSL, in the Ansible folder, through a login shell
# (so tools installed with pipx are on the PATH). Fails if the command fails.
function Invoke-Wsl([string]$Command) {
    wsl.exe -d $distro --cd $ansibleDir -- bash -lc $Command
    if ($LASTEXITCODE -ne 0) {
        throw "Command failed in WSL (exit code $LASTEXITCODE): $Command"
    }
}

# 2. The inventory is the source of truth for the VM's IP
Write-Host "Reading '$Name' from the Ansible inventory ..."
$hostVars  = (Invoke-Wsl "ansible-inventory --host '$Name'") -join "`n" | ConvertFrom-Json
$ipAddress = $hostVars.ansible_host
if (-not $ipAddress) {
    throw "'$Name' has no ansible_host in the inventory."
}

# 3. Delete and create the VM
& (Join-Path $PSScriptRoot "delete-vm.ps1") -Name $Name
& (Join-Path $PSScriptRoot "create-vm.ps1") -Name $Name -IpAddress $ipAddress -CpuCount $CpuCount -Memory $Memory

# 4. The new VM has new SSH host keys: forget the old ones
Invoke-Wsl "ssh-keygen -R '$ipAddress' > /dev/null 2>&1 || true"

# 5. Wait until SSH accepts the automation user, trusting the new host key on
#    first use (accept-new): the VM was created seconds ago on the lab's
#    internal switch. A changed key would still be rejected.
Write-Host "Waiting for SSH on $ipAddress ..."
Invoke-Wsl "ansible '$Name' -m ansible.builtin.wait_for_connection -a timeout=300 --ssh-extra-args='-o StrictHostKeyChecking=accept-new'"

# 6. Configure the VM. --limit keeps the run on this host only.
Invoke-Wsl "ansible-playbook site.yml --limit '$Name'"

Write-Host "Done: '$Name' rebuilt at $ipAddress"
