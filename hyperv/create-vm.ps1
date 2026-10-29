#Requires -RunAsAdministrator

# create-vm.ps1
# Creates a lab VM from the generalized base image. Idempotent.
# Each VM gets its own identity on first boot through cloud-init (NoCloud):
# a small seed disk labeled CIDATA carries its hostname, IP and the
# automation user's public key.
param(
    [Parameter(Mandatory)]
    [string]$Name,

    [Parameter(Mandatory)]
    [ipaddress]$IpAddress,

    [int]     $PrefixLength  = 24,
    [string]  $Gateway       = "192.168.100.1",
    [string[]]$DnsServers    = @("1.1.1.1", "8.8.8.8"),
    [int]     $CpuCount      = 4,
    [long]    $Memory        = 8GB,
    [string]  $BaseImagePath = "C:\Lab\base\ubuntu-26.04-base-v2.vhdx",
    [string]  $VmFolder      = "C:\Lab\vms",
    [string]  $SwitchName    = "LabSwitch",
    # The automation key lives in the Ansible inventory: one source of truth.
    # Empty means the lab inventory next to this script.
    [string]  $GroupVarsPath
)

$ErrorActionPreference = "Stop"

# Windows PowerShell 5.1 leaves $PSScriptRoot empty inside param() defaults,
# so the default path is resolved here, in the script body.
if (-not $GroupVarsPath) {
    $GroupVarsPath = Join-Path $PSScriptRoot "..\ansible\inventories\lab\group_vars\all.yml"
}

# Writes a file as UTF-8 without BOM and with LF line endings.
# cloud-init only recognizes user-data whose first bytes are "#cloud-config":
# a BOM or CRLF line endings break that.
function Write-SeedFile([string]$Path, [string]$Content) {
    $utf8NoBom = New-Object System.Text.UTF8Encoding $false
    [System.IO.File]::WriteAllText($Path, (($Content -replace "`r`n", "`n") + "`n"), $utf8NoBom)
}

# 1. Idempotency: if the VM already exists, do nothing
if (Get-VM -Name $Name -ErrorAction SilentlyContinue) {
    Write-Host "VM '$Name' already exists. Nothing to do."
    exit 0
}

# 2. Read the automation public key from the inventory
$match = Select-String -Path $GroupVarsPath -Pattern '^automation_public_key:\s*"(.+)"'
if (-not $match) {
    throw "automation_public_key not found in $GroupVarsPath"
}
$publicKey = $match.Matches[0].Groups[1].Value

# 3. Copy the base image as the VM's own disk
New-Item -ItemType Directory -Path $VmFolder -Force | Out-Null
$diskPath = Join-Path $VmFolder "$Name.vhdx"
Write-Host "Copying the base image to $diskPath ..."
Copy-Item -Path $BaseImagePath -Destination $diskPath
# The copy inherits the read-only attribute: clear it
Set-ItemProperty -Path $diskPath -Name IsReadOnly -Value $false

# 4. Build the cloud-init seed disk (FAT32 volume labeled CIDATA)
$seedPath = Join-Path $VmFolder "$Name-seed.vhdx"
if (Test-Path $seedPath) {
    Remove-Item $seedPath
}
Write-Host "Building the cloud-init seed disk $seedPath ..."
New-VHD -Path $seedPath -SizeBytes 64MB -Dynamic | Out-Null
try {
    $disk = Mount-VHD -Path $seedPath -Passthru | Get-Disk
    Initialize-Disk -Number $disk.Number -PartitionStyle MBR
    # Format before assigning a drive letter, so Explorer does not ask to format it
    $partition = New-Partition -DiskNumber $disk.Number -UseMaximumSize
    Format-Volume -Partition $partition -FileSystem FAT32 -NewFileSystemLabel "CIDATA" -Confirm:$false | Out-Null
    $partition | Add-PartitionAccessPath -AssignDriveLetter
    $root = "$((Get-Partition -DiskNumber $disk.Number -PartitionNumber $partition.PartitionNumber).DriveLetter):\"

    # A new instance-id tells cloud-init this is a first boot
    Write-SeedFile -Path (Join-Path $root "meta-data") -Content @"
instance-id: $Name-$([guid]::NewGuid())
local-hostname: $Name
"@

    Write-SeedFile -Path (Join-Path $root "network-config") -Content @"
version: 2
ethernets:
  eth0:
    match:
      driver: hv_netvsc
    set-name: eth0
    addresses:
      - $IpAddress/$PrefixLength
    routes:
      - to: default
        via: $Gateway
    nameservers:
      addresses: [$($DnsServers -join ', ')]
"@

    Write-SeedFile -Path (Join-Path $root "user-data") -Content @"
#cloud-config
users:
  - name: ansible
    shell: /bin/bash
    sudo: "ALL=(ALL) NOPASSWD:ALL"
    lock_passwd: true
    ssh_authorized_keys:
      - $publicKey
"@
}
finally {
    Dismount-VHD -Path $seedPath
}

# 5. Create the VM with both disks
New-VM -Name $Name -Generation 2 -MemoryStartupBytes $Memory -VHDPath $diskPath -SwitchName $SwitchName | Out-Null
Add-VMHardDiskDrive -VMName $Name -Path $seedPath

# 6. Apply the settings that used to be set by hand in the Hyper-V wizard
Set-VMProcessor -VMName $Name -Count $CpuCount
Set-VMMemory -VMName $Name -DynamicMemoryEnabled $false
Set-VMFirmware -VMName $Name -SecureBootTemplate MicrosoftUEFICertificateAuthority
Set-VM -Name $Name -AutomaticCheckpointsEnabled $false

# 7. Start the VM and wait for it to report the expected IP
Start-VM -Name $Name
Write-Host "Waiting for the VM to report $IpAddress ..."
$deadline = (Get-Date).AddMinutes(3)
do {
    Start-Sleep -Seconds 5
    $ipAddresses = (Get-VMNetworkAdapter -VMName $Name).IPAddresses
} until (($ipAddresses -contains "$IpAddress") -or (Get-Date) -gt $deadline)

if ($ipAddresses -notcontains "$IpAddress") {
    throw "VM did not report $IpAddress within 3 minutes (reported: $ipAddresses)."
}

Write-Host "Done: VM '$Name' is reachable at $IpAddress"
