################################################################################
#  TECH TOOLKIT  -  Outil technicien Windows (tweaks, durcissement, controle)
#  Version : #{VERSION}#
#  Lancement web : irm https://raw.githubusercontent.com/Nagory-ST/tech-toolkit/main/dist/toolkit.ps1 | iex
#  Lancement USB : START.bat (partition TOOLS)
#  Fichier GENERE par Compile.ps1 - ne pas modifier dist/toolkit.ps1 a la main.
################################################################################

$TKVersion = '#{VERSION}#'
$TKWebUrl  = 'https://raw.githubusercontent.com/Nagory-ST/tech-toolkit/main/dist/toolkit.ps1'

# --- Origine du script : USB (fichier local) ou web (irm | iex) -----------------
$TKRoot = $null
if ($env:TK_ROOT)        { $TKRoot = $env:TK_ROOT.TrimEnd('\') }
elseif ($PSCommandPath)  { $TKRoot = Split-Path -Parent $PSCommandPath }

# --- Relance si besoin : admin + Windows PowerShell 5.1 + STA + lecture UTF-8 ----
$isAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole(
             [Security.Principal.WindowsBuiltInRole]::Administrator)
$needRelaunch = (-not $isAdmin) -or
                ($PSVersionTable.PSEdition -ne 'Desktop') -or
                ([Threading.Thread]::CurrentThread.ApartmentState -ne 'STA') -or
                [bool]$PSCommandPath

if ($needRelaunch) {
    if ($TKRoot -and (Test-Path -LiteralPath (Join-Path $TKRoot 'toolkit.ps1'))) {
        $file = Join-Path $TKRoot 'toolkit.ps1'
        $cmd  = "`$env:TK_ROOT='$TKRoot'; iex ([IO.File]::ReadAllText('$file',[Text.Encoding]::UTF8))"
    } else {
        $cmd  = "irm '$TKWebUrl' | iex"
    }
    $verb = if ($isAdmin) { 'Open' } else { 'RunAs' }
    try {
        Start-Process -FilePath "$env:SystemRoot\System32\WindowsPowerShell\v1.0\powershell.exe" -Verb $verb `
            -ArgumentList "-NoProfile -ExecutionPolicy Bypass -STA -Command `"$cmd`""
    } catch {
        Write-Host "Elevation refusee : Tech Toolkit doit tourner en administrateur." -ForegroundColor Red
    }
    return
}

Add-Type -AssemblyName PresentationFramework, PresentationCore, WindowsBase, System.Windows.Forms

# --- Etat partage entre l'interface et les taches de fond -----------------------
$sync = [Hashtable]::Synchronized(@{})
$sync.Version   = $TKVersion
$sync.Root      = $TKRoot
$sync.Mode      = if ($TKRoot -and (Test-Path -LiteralPath (Join-Path $TKRoot 'tools.json'))) { 'USB' } else { 'WEB' }
$sync.DataDir   = Join-Path $env:ProgramData 'TechToolkit'
$sync.LogQueue  = New-Object 'System.Collections.Concurrent.ConcurrentQueue[string]'
$sync.Jobs      = [System.Collections.ArrayList]::Synchronized((New-Object System.Collections.ArrayList))
$sync.OnDone    = @{}
$sync.Busy      = $false
$sync.Status    = 'Pret'
$sync.configs   = @{}

New-Item -ItemType Directory -Path (Join-Path $sync.DataDir 'logs') -Force | Out-Null
$sync.LogFile   = Join-Path $sync.DataDir ("logs\toolkit_{0}.log" -f (Get-Date -Format 'yyyyMMdd'))
$sync.StateFile = Join-Path $sync.DataDir 'state.json'
