#Requires -RunAsAdministrator

# borrar-vm.ps1
# Apaga y borra una VM del lab y su disco. Es idempotente.
param(
    [string]$Nombre     = "lab",
    [string]$CarpetaVms = "C:\Lab\vms"
)

$ErrorActionPreference = "Stop"

# 1. La VM: apagarla si esta prendida, y borrarla
$vm = Get-VM -Name $Nombre -ErrorAction SilentlyContinue
if ($vm) {
    if ($vm.State -ne "Off") {
        Write-Host "Apagando la VM '$Nombre' ..."
        Stop-VM -Name $Nombre -Force
    }
    Remove-VM -Name $Nombre -Force
    Write-Host "VM '$Nombre' borrada."
} else {
    Write-Host "La VM '$Nombre' no existe."
}

# 2. El disco: borrarlo si existe
$disco = Join-Path $CarpetaVms "$Nombre.vhdx"
if (Test-Path $disco) {
    Remove-Item $disco
    Write-Host "Disco $disco borrado."
}
