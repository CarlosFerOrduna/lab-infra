#Requires -RunAsAdministrator

# crear-vm.ps1
# Crea una VM del lab a partir de la imagen base. Es idempotente.
param(
    [string]$Nombre     = "lab",
    [int]   $Cpus       = 4,
    [long]  $Memoria    = 8GB,
    [string]$ImagenBase = "C:\Lab\base\ubuntu-26.04-base.vhdx",
    [string]$CarpetaVms = "C:\Lab\vms",
    [string]$Switch     = "LabSwitch"
)

$ErrorActionPreference = "Stop"

# 1. Idempotencia: si la VM ya existe, no hacemos nada
if (Get-VM -Name $Nombre -ErrorAction SilentlyContinue) {
    Write-Host "La VM '$Nombre' ya existe. No hay nada que hacer."
    exit 0
}

# 2. Copiar la imagen base como disco propio de la VM
New-Item -ItemType Directory -Path $CarpetaVms -Force | Out-Null
$disco = Join-Path $CarpetaVms "$Nombre.vhdx"
Write-Host "Copiando la imagen base a $disco ..."
Copy-Item -Path $ImagenBase -Destination $disco
# La copia hereda el atributo de solo lectura: se lo sacamos
Set-ItemProperty -Path $disco -Name IsReadOnly -Value $false

# 3. Crear la VM
New-VM -Name $Nombre -Generation 2 -MemoryStartupBytes $Memoria -VHDPath $disco -SwitchName $Switch | Out-Null

# 4. Los ajustes que hiciste a mano en el asistente
Set-VMProcessor -VMName $Nombre -Count $Cpus
Set-VMMemory -VMName $Nombre -DynamicMemoryEnabled $false
Set-VMFirmware -VMName $Nombre -SecureBootTemplate MicrosoftUEFICertificateAuthority
Set-VM -Name $Nombre -AutomaticCheckpointsEnabled $false

# 5. Arrancar y esperar a que la VM informe su IP
Start-VM -Name $Nombre
Write-Host "Esperando que la VM informe su IP ..."
$limite = (Get-Date).AddMinutes(3)
do {
    Start-Sleep -Seconds 5
    $ips = (Get-VMNetworkAdapter -VMName $Nombre).IPAddresses | Where-Object { $_ -match '^\d+\.\d+\.\d+\.\d+$' }
} until ($ips -or (Get-Date) -gt $limite)

if (-not $ips) {
    throw "La VM no informo su IP en 3 minutos."
}

Write-Host "Listo: la VM '$Nombre' responde en $ips"
