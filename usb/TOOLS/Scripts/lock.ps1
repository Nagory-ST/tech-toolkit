#Requires -RunAsAdministrator
<#  Verrouille (lecture seule) ou déverrouille la partition TOOLS.
    lock.ps1           -> lecture seule
    lock.ps1 -Unlock   -> écriture autorisée (MAJ des outils sur TON poste)  #>
param([switch]$Unlock)

$vol = Get-Volume -FileSystemLabel 'TOOLS' -ErrorAction SilentlyContinue | Select-Object -First 1
if (-not $vol) { Write-Host 'Partition TOOLS introuvable.' -ForegroundColor Red; return }
$part = $vol | Get-Partition

Set-Partition -DiskNumber $part.DiskNumber -PartitionNumber $part.PartitionNumber -IsReadOnly (-not $Unlock)
$state = (Get-Partition -DiskNumber $part.DiskNumber -PartitionNumber $part.PartitionNumber).IsReadOnly
if ($state) { Write-Host "TOOLS ($($vol.DriveLetter):) : LECTURE SEULE" -ForegroundColor Green }
else        { Write-Host "TOOLS ($($vol.DriveLetter):) : ÉCRITURE AUTORISÉE - pense à reverrouiller" -ForegroundColor Yellow }
Write-Host 'Si l''état ne s''applique pas tout de suite : débranche / rebranche la clé.' -ForegroundColor DarkGray
