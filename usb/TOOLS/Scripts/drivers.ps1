#Requires -RunAsAdministrator
<#  Pilotes : export du poste courant (vers Collecte) ou injection depuis TOOLS\Drivers\Exports  #>
param([string]$Collecte = "$env:PUBLIC\Collecte-Toolkit")

[Console]::OutputEncoding = [Text.Encoding]::UTF8
$Root = Split-Path $PSScriptRoot -Parent
$model = ((Get-CimInstance Win32_ComputerSystem).Model -replace '[\\/:*?"<>|]', '').Trim()
$maker = ((Get-CimInstance Win32_ComputerSystem).Manufacturer -replace '[\\/:*?"<>|]', '').Trim()

Write-Host "`n  Poste : $maker $model`n" -ForegroundColor Cyan
Write-Host '  E. Exporter les pilotes de ce poste'
Write-Host '  I. Injecter des pilotes depuis la clé'
$c = Read-Host "`n  Choix"

if ($c -match '^[eE]$') {
    $dst = Join-Path $Collecte "Drivers\$maker-$model"
    New-Item -ItemType Directory -Path $dst -Force | Out-Null
    pnputil /export-driver * "$dst"
    Write-Host "`n  Exporté dans $dst" -ForegroundColor Green
    Write-Host '  -> Sur ton poste : déverrouille TOOLS et déplace ce dossier dans Drivers\Exports.' -ForegroundColor DarkGray
}
elseif ($c -match '^[iI]$') {
    $base = Join-Path $Root 'Drivers\Exports'
    $dirs = @(Get-ChildItem $base -Directory -ErrorAction SilentlyContinue)
    if (-not $dirs) { Write-Host '  Aucun pack dans Drivers\Exports.' -ForegroundColor Yellow; return }
    for ($i = 0; $i -lt $dirs.Count; $i++) {
        $hint = if ($dirs[$i].Name -like "*$model*") { '  <- correspond à ce poste' } else { '' }
        Write-Host ("  {0,2}. {1}{2}" -f ($i + 1), $dirs[$i].Name, $hint)
    }
    $n = [int](Read-Host "`n  Pack à injecter")
    if ($n -ge 1 -and $n -le $dirs.Count) {
        pnputil /add-driver "$($dirs[$n-1].FullName)\*.inf" /subdirs /install
    }
}
