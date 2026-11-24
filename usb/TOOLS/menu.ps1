#Requires -Version 5.1
<#
  TECH TOOLKIT - lanceur portable
  Se lance via START.bat. Catalogue des outils : tools.json (même dossier).
  Variables utilisables dans "args" de tools.json : {ROOT} (racine TOOLS), {COLLECTE} (dossier de sortie).
#>

# --- Auto-élévation ---
$principal = [Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()
if (-not $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    Start-Process powershell.exe -Verb RunAs -ArgumentList "-NoProfile -ExecutionPolicy Bypass -File `"$PSCommandPath`""
    exit
}

[Console]::OutputEncoding = [Text.Encoding]::UTF8
$Host.UI.RawUI.WindowTitle = 'TECH TOOLKIT'
$Root = $PSScriptRoot

# --- Dossier de collecte : partition Ventoy de la même clé (inscriptible) ---
function Get-CollectePath {
    try {
        $letter = (Split-Path $Root -Qualifier).TrimEnd(':')
        $disk = (Get-Partition -DriveLetter $letter -ErrorAction Stop).DiskNumber
        $v = Get-Partition -DiskNumber $disk | Get-Volume -ErrorAction SilentlyContinue |
             Where-Object { $_.FileSystemLabel -eq 'Ventoy' -and $_.DriveLetter } | Select-Object -First 1
        if ($v) {
            $p = "$($v.DriveLetter):\Collecte"
            New-Item -ItemType Directory -Path $p -Force | Out-Null
            return $p
        }
    } catch {}
    $p = Join-Path $env:PUBLIC 'Collecte-Toolkit'
    New-Item -ItemType Directory -Path $p -Force | Out-Null
    Write-Host "  [!] Partition Ventoy introuvable : collecte sur le PC dans $p" -ForegroundColor Yellow
    return $p
}

$Collecte = Get-CollectePath

try {
    $Catalog = Get-Content (Join-Path $Root 'tools.json') -Raw -Encoding UTF8 | ConvertFrom-Json
} catch {
    Write-Host "tools.json illisible : $($_.Exception.Message)" -ForegroundColor Red
    Read-Host 'Entrée pour quitter'; exit 1
}

# --- Infos machine (une seule fois) ---
$os  = Get-CimInstance Win32_OperatingSystem
$cs  = Get-CimInstance Win32_ComputerSystem
$ip  = (Get-NetIPAddress -AddressFamily IPv4 -ErrorAction SilentlyContinue |
        Where-Object { $_.IPAddress -notlike '127.*' -and $_.IPAddress -notlike '169.254.*' } |
        Select-Object -ExpandProperty IPAddress) -join ', '
$domain = if ($cs.PartOfDomain) { $cs.Domain } else { "WORKGROUP ($($cs.Workgroup))" }

function Show-Header {
    Clear-Host
    Write-Host ''
    Write-Host '  ===================  TECH TOOLKIT  ===================' -ForegroundColor Cyan
    Write-Host ("  Poste   : {0}   |   {1} (build {2})" -f $env:COMPUTERNAME, $os.Caption, $os.BuildNumber) -ForegroundColor Gray
    Write-Host ("  Domaine : {0}   |   IP : {1}" -f $domain, $ip) -ForegroundColor Gray
    Write-Host ("  Collecte: {0}" -f $Collecte) -ForegroundColor DarkGray
    Write-Host '  ======================================================' -ForegroundColor Cyan
    Write-Host ''
}

function Expand-ToolArgs([string]$a) {
    if (-not $a) { return $null }
    return $a.Replace('{ROOT}', $Root).Replace('{COLLECTE}', $Collecte)
}

function Start-Tool($t) {
    $full = Join-Path $Root $t.path
    if (-not (Test-Path -LiteralPath $full)) {
        Write-Host "  Introuvable : $full" -ForegroundColor Red
        Write-Host '  -> Dépose l''outil à cet emplacement ou corrige "path" dans tools.json.' -ForegroundColor DarkGray
        Read-Host '  Entrée pour continuer' | Out-Null
        return
    }
    $wd = Split-Path -LiteralPath $full
    $a  = Expand-ToolArgs $t.args
    try {
        switch ($t.type) {
            'script'  {
                Start-Process powershell.exe -WorkingDirectory $wd -ArgumentList (
                    "-NoProfile -ExecutionPolicy Bypass -NoExit -File `"$full`" $a")
            }
            'console' {
                Start-Process cmd.exe -WorkingDirectory $wd -ArgumentList "/k `"`"$full`" $a`""
            }
            default {
                if ($a) { Start-Process -FilePath $full -WorkingDirectory $wd -ArgumentList $a }
                else    { Start-Process -FilePath $full -WorkingDirectory $wd }
            }
        }
        Write-Host "  Lancé : $($t.name)" -ForegroundColor Green
        Start-Sleep -Milliseconds 700
    } catch {
        Write-Host "  Échec : $($_.Exception.Message)" -ForegroundColor Red
        Read-Host '  Entrée pour continuer' | Out-Null
    }
}

function Show-Category([string]$cat) {
    while ($true) {
        Show-Header
        Write-Host "  [$cat]" -ForegroundColor Yellow
        Write-Host ''
        $items = @($Catalog | Where-Object { $_.cat -eq $cat })
        for ($i = 0; $i -lt $items.Count; $i++) {
            $t = $items[$i]
            $ok = Test-Path -LiteralPath (Join-Path $Root $t.path)
            $mark  = if ($ok) { '+' } else { '-' }
            $color = if ($ok) { 'White' } else { 'DarkGray' }
            Write-Host ("  {0,2}. [{1}] {2,-28} {3}" -f ($i + 1), $mark, $t.name, $t.desc) -ForegroundColor $color
        }
        Write-Host ''
        Write-Host '   R. Retour' -ForegroundColor Cyan
        $c = Read-Host "`n  Choix"
        if ($c -match '^[rR]$' -or $c -eq '') { return }
        $n = 0
        if ([int]::TryParse($c, [ref]$n) -and $n -ge 1 -and $n -le $items.Count) { Start-Tool $items[$n - 1] }
    }
}

# --- Boucle principale ---
$cats = [System.Collections.Generic.List[string]]::new()
foreach ($t in $Catalog) { if (-not $cats.Contains($t.cat)) { $cats.Add($t.cat) } }

while ($true) {
    Show-Header
    for ($i = 0; $i -lt $cats.Count; $i++) {
        $count = @($Catalog | Where-Object { $_.cat -eq $cats[$i] }).Count
        Write-Host ("  {0,2}. {1,-20} ({2})" -f ($i + 1), $cats[$i], $count)
    }
    Write-Host ''
    Write-Host '   O. Ouvrir le dossier Collecte' -ForegroundColor Cyan
    Write-Host '   Q. Quitter' -ForegroundColor Cyan
    $c = Read-Host "`n  Choix"
    switch -Regex ($c) {
        '^[qQ]$' { exit }
        '^[oO]$' { Start-Process explorer.exe $Collecte; continue }
        default {
            $n = 0
            if ([int]::TryParse($c, [ref]$n) -and $n -ge 1 -and $n -le $cats.Count) { Show-Category $cats[$n - 1] }
        }
    }
}
