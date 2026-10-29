#Requires -RunAsAdministrator

# delete-vm.ps1
# Stops and deletes a lab VM, its disk and its cloud-init seed disk. Idempotent.
param(
    [Parameter(Mandatory)]
    [string]$Name,

    [string]$VmFolder = "C:\Lab\vms"
)

$ErrorActionPreference = "Stop"

# 1. The VM: stop it if it is running, then delete it
$vm = Get-VM -Name $Name -ErrorAction SilentlyContinue
if ($vm) {
    if ($vm.State -ne "Off") {
        Write-Host "Stopping VM '$Name' ..."
        Stop-VM -Name $Name -Force
    }
    Remove-VM -Name $Name -Force
    Write-Host "VM '$Name' deleted."
} else {
    Write-Host "VM '$Name' does not exist."
}

# 2. The disks: delete them if they exist
foreach ($diskName in "$Name.vhdx", "$Name-seed.vhdx") {
    $diskPath = Join-Path $VmFolder $diskName
    if (Test-Path $diskPath) {
        Remove-Item $diskPath
        Write-Host "Disk $diskPath deleted."
    }
}
