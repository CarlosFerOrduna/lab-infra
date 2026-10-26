#Requires -RunAsAdministrator

# create-vm.ps1
# Creates a lab VM from the base image. Idempotent.
param(
    [string]$Name          = "lab",
    [int]   $CpuCount      = 4,
    [long]  $Memory        = 8GB,
    [string]$BaseImagePath = "C:\Lab\base\ubuntu-26.04-base.vhdx",
    [string]$VmFolder      = "C:\Lab\vms",
    [string]$SwitchName    = "LabSwitch"
)

$ErrorActionPreference = "Stop"

# 1. Idempotency: if the VM already exists, do nothing
if (Get-VM -Name $Name -ErrorAction SilentlyContinue) {
    Write-Host "VM '$Name' already exists. Nothing to do."
    exit 0
}

# 2. Copy the base image as the VM's own disk
New-Item -ItemType Directory -Path $VmFolder -Force | Out-Null
$diskPath = Join-Path $VmFolder "$Name.vhdx"
Write-Host "Copying the base image to $diskPath ..."
Copy-Item -Path $BaseImagePath -Destination $diskPath
# The copy inherits the read-only attribute: clear it
Set-ItemProperty -Path $diskPath -Name IsReadOnly -Value $false

# 3. Create the VM
New-VM -Name $Name -Generation 2 -MemoryStartupBytes $Memory -VHDPath $diskPath -SwitchName $SwitchName | Out-Null

# 4. Apply the settings that used to be set by hand in the Hyper-V wizard
Set-VMProcessor -VMName $Name -Count $CpuCount
Set-VMMemory -VMName $Name -DynamicMemoryEnabled $false
Set-VMFirmware -VMName $Name -SecureBootTemplate MicrosoftUEFICertificateAuthority
Set-VM -Name $Name -AutomaticCheckpointsEnabled $false

# 5. Start the VM and wait for it to report its IP
Start-VM -Name $Name
Write-Host "Waiting for the VM to report its IP ..."
$deadline = (Get-Date).AddMinutes(3)
do {
    Start-Sleep -Seconds 5
    $ipAddresses = (Get-VMNetworkAdapter -VMName $Name).IPAddresses | Where-Object { $_ -match '^\d+\.\d+\.\d+\.\d+$' }
} until ($ipAddresses -or (Get-Date) -gt $deadline)

if (-not $ipAddresses) {
    throw "VM did not report its IP within 3 minutes."
}

Write-Host "Done: VM '$Name' is reachable at $ipAddresses"
