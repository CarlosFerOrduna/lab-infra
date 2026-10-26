#Requires -RunAsAdministrator

# delete-vm.ps1
# Stops and deletes a lab VM and its disk. Idempotent.
param(
    [string]$Name     = "lab",
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

# 2. The disk: delete it if it exists
$diskPath = Join-Path $VmFolder "$Name.vhdx"
if (Test-Path $diskPath) {
    Remove-Item $diskPath
    Write-Host "Disk $diskPath deleted."
}
