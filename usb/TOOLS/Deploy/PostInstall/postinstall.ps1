#Requires -RunAsAdministrator
<#  Post-installation d'un poste neuf. Adapte la liste $apps et les réglages au client.
    Réseau requis (winget + Windows Update). Les installeurs hors ligne vont dans Deploy\Apps-Offline. #>

[Console]::OutputEncoding = [Text.Encoding]::UTF8

$apps = @(
    '7zip.7zip',
    'Notepad++.Notepad++',
    'Mozilla.Firefox',
    'Google.Chrome',
    'Adobe.Acrobat.Reader.64-bit',
    'VideoLAN.VLC'
)

if (-not (Get-Command winget -ErrorAction SilentlyContinue)) {
    Write-Host 'winget absent : mets à jour "Programme d''installation d''application" via le Store.' -ForegroundColor Yellow
} else {
    foreach ($a in $apps) {
        Write-Host "-> $a" -ForegroundColor Cyan
        winget install --id $a -e --silent --accept-package-agreements --accept-source-agreements
    }
}

# Installeurs hors ligne (MSI silencieux)
$offline = Join-Path (Split-Path (Split-Path $PSScriptRoot -Parent) -Parent) 'Deploy\Apps-Offline'
Get-ChildItem $offline -Filter *.msi -ErrorAction SilentlyContinue | ForEach-Object {
    Write-Host "-> $($_.Name)" -ForegroundColor Cyan
    Start-Process msiexec.exe -ArgumentList "/i `"$($_.FullName)`" /qn /norestart" -Wait
}

# Réglages de base
powercfg /change standby-timeout-ac 0
powercfg /change monitor-timeout-ac 15

# Windows Update
Write-Host 'Recherche des mises à jour...' -ForegroundColor Cyan
if (-not (Get-Module -ListAvailable PSWindowsUpdate)) {
    Install-PackageProvider -Name NuGet -Force | Out-Null
    Install-Module PSWindowsUpdate -Force -Scope AllUsers
}
Import-Module PSWindowsUpdate
Get-WindowsUpdate -AcceptAll -Install -IgnoreReboot

# Nom du poste / domaine (décommente si besoin)
# Rename-Computer -NewName 'PC-XXX'
# Add-Computer -DomainName 'domaine.local' -Credential (Get-Credential) -Restart

Write-Host "`nTerminé. Redémarre le poste." -ForegroundColor Green
