################################################################################
#  TECH TOOLKIT  -  Outil technicien Windows (tweaks, durcissement, controle)
#  Version : 26.11.24
#  Lancement web : irm https://raw.githubusercontent.com/Nagory-ST/tech-toolkit/main/dist/toolkit.ps1 | iex
#  Lancement USB : START.bat (partition TOOLS)
#  Fichier GENERE par Compile.ps1 - ne pas modifier dist/toolkit.ps1 a la main.
################################################################################

$TKVersion = '26.11.24'
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

# ---------------------------------------------------------------- configs
$sync.configs.cleanup = @'
[
  { "id": "CL_Temp", "group": "Nettoyage", "name": "Fichiers temporaires",
    "description": "Vide %TEMP% de l'utilisateur et C:\\Windows\\Temp (les fichiers verrouill\u00e9s sont ignor\u00e9s).",
    "script": "$before = 0; $paths = @($env:TEMP, \"$env:SystemRoot\\Temp\"); foreach ($p in $paths) { $before += (Get-ChildItem $p -Recurse -Force -File -ErrorAction SilentlyContinue | Measure-Object Length -Sum).Sum; Get-ChildItem $p -Force -ErrorAction SilentlyContinue | Remove-Item -Recurse -Force -ErrorAction SilentlyContinue }; $after = 0; foreach ($p in $paths) { $after += (Get-ChildItem $p -Recurse -Force -File -ErrorAction SilentlyContinue | Measure-Object Length -Sum).Sum }; Write-TKLog ('Temporaires : {0:N0} Mo lib\u00e9r\u00e9s' -f (($before - $after) / 1MB)) 'OK'" },
  { "id": "CL_Recycle", "group": "Nettoyage", "name": "Corbeille",
    "description": "Vide la corbeille de tous les lecteurs.",
    "script": "Clear-RecycleBin -Force -ErrorAction SilentlyContinue; Write-TKLog 'Corbeille vid\u00e9e.' 'OK'" },
  { "id": "CL_DNS", "group": "Nettoyage", "name": "Cache DNS",
    "description": "Purge le cache du r\u00e9solveur DNS (utile apr\u00e8s nettoyage d'un fichier hosts ou d'un DNS d\u00e9tourn\u00e9).",
    "script": "Clear-DnsClientCache; Write-TKLog 'Cache DNS purg\u00e9.' 'OK'" },
  { "id": "CL_WUCache", "group": "Nettoyage", "name": "Cache Windows Update",
    "description": "Arr\u00eate les services, vide SoftwareDistribution\\Download, red\u00e9marre. D\u00e9bloque les MAJ coinc\u00e9es.",
    "script": "Stop-Service wuauserv, bits -Force -ErrorAction SilentlyContinue; Get-ChildItem \"$env:SystemRoot\\SoftwareDistribution\\Download\" -Force -ErrorAction SilentlyContinue | Remove-Item -Recurse -Force -ErrorAction SilentlyContinue; Start-Service bits, wuauserv -ErrorAction SilentlyContinue; Write-TKLog 'Cache Windows Update vid\u00e9.' 'OK'" },
  { "id": "CL_DeliveryOpt", "group": "Nettoyage", "name": "Cache d'optimisation de distribution",
    "description": "Supprime le cache de partage pair-\u00e0-pair des mises \u00e0 jour.",
    "script": "Delete-DeliveryOptimizationCache -Force -ErrorAction SilentlyContinue; Write-TKLog 'Cache d''optimisation de distribution vid\u00e9.' 'OK'" },
  { "id": "CL_Component", "group": "Nettoyage", "name": "Magasin de composants (WinSxS)",
    "description": "DISM StartComponentCleanup : supprime les anciennes versions de composants. Plusieurs minutes.",
    "script": "& dism.exe /Online /Cleanup-Image /StartComponentCleanup /Quiet | Out-Null; Write-TKLog ('WinSxS nettoy\u00e9 (code {0}).' -f $LASTEXITCODE) $(if ($LASTEXITCODE -eq 0) { 'OK' } else { 'WARN' })" },

  { "id": "RP_DISM", "group": "R\u00e9paration", "name": "R\u00e9parer l'image Windows (DISM)",
    "description": "DISM /RestoreHealth via Windows Update. \u00c0 lancer AVANT SFC. 5 \u00e0 20 min, r\u00e9seau requis.",
    "script": "& dism.exe /Online /Cleanup-Image /RestoreHealth | Out-Null; Write-TKLog ('DISM RestoreHealth termin\u00e9 (code {0}).' -f $LASTEXITCODE) $(if ($LASTEXITCODE -eq 0) { 'OK' } else { 'WARN' })" },
  { "id": "RP_SFC", "group": "R\u00e9paration", "name": "V\u00e9rifier les fichiers syst\u00e8me (SFC)",
    "description": "sfc /scannow. D\u00e9tail dans C:\\Windows\\Logs\\CBS\\CBS.log. 5 \u00e0 15 min.",
    "script": "& sfc.exe /scannow | Out-Null; Write-TKLog ('SFC termin\u00e9 (code {0}). D\u00e9tail : CBS.log' -f $LASTEXITCODE) $(if ($LASTEXITCODE -eq 0) { 'OK' } else { 'WARN' })" },
  { "id": "RP_Network", "group": "R\u00e9paration", "name": "R\u00e9initialiser la pile r\u00e9seau",
    "description": "winsock reset + ip reset + flush DNS. Red\u00e9marrage requis. Les IP fixes sont conserv\u00e9es sur les cartes, mais v\u00e9rifie apr\u00e8s.",
    "script": "& netsh.exe winsock reset | Out-Null; & netsh.exe int ip reset | Out-Null; & ipconfig.exe /flushdns | Out-Null; Write-TKLog 'Pile r\u00e9seau r\u00e9initialis\u00e9e : red\u00e9marrage n\u00e9cessaire.' 'WARN'" },
  { "id": "RP_Proxy", "group": "R\u00e9paration", "name": "Supprimer les proxys (utilisateur + WinHTTP)",
    "description": "Retire un proxy ou script PAC impos\u00e9 par un malware. Ne pas utiliser si l'entreprise impose un proxy l\u00e9gitime.",
    "script": "$k = 'HKCU:\\Software\\Microsoft\\Windows\\CurrentVersion\\Internet Settings'; Set-ItemProperty $k ProxyEnable 0; Remove-ItemProperty $k -Name ProxyServer, AutoConfigURL -ErrorAction SilentlyContinue; & netsh.exe winhttp reset proxy | Out-Null; Write-TKLog 'Proxys utilisateur et WinHTTP supprim\u00e9s.' 'OK'" },

  { "id": "AV_Update", "group": "Antivirus", "name": "Mettre \u00e0 jour Defender",
    "description": "T\u00e9l\u00e9charge les derni\u00e8res signatures Microsoft Defender.",
    "script": "Update-MpSignature -ErrorAction Stop; Write-TKLog 'Signatures Defender \u00e0 jour.' 'OK'" },
  { "id": "AV_Quick", "group": "Antivirus", "name": "Analyse rapide Defender",
    "description": "Zones de d\u00e9marrage, m\u00e9moire, emplacements courants. Quelques minutes.",
    "script": "Start-MpScan -ScanType QuickScan -ErrorAction Stop; $d = @(Get-MpThreatDetection -ErrorAction SilentlyContinue | Where-Object { $_.InitialDetectionTime -gt (Get-Date).AddHours(-2) }); Write-TKLog ('Analyse rapide termin\u00e9e : {0} d\u00e9tection(s).' -f $d.Count) $(if ($d.Count) { 'WARN' } else { 'OK' })" },
  { "id": "AV_Full", "group": "Antivirus", "name": "Analyse compl\u00e8te Defender",
    "description": "Tout le disque. Peut durer plus d'une heure.",
    "script": "Start-MpScan -ScanType FullScan -ErrorAction Stop; $d = @(Get-MpThreatDetection -ErrorAction SilentlyContinue | Where-Object { $_.InitialDetectionTime -gt (Get-Date).AddHours(-6) }); Write-TKLog ('Analyse compl\u00e8te termin\u00e9e : {0} d\u00e9tection(s).' -f $d.Count) $(if ($d.Count) { 'WARN' } else { 'OK' })" },
  { "id": "AV_Offline", "group": "Antivirus", "name": "Analyse hors ligne Defender (RED\u00c9MARRE)",
    "description": "Red\u00e9marre imm\u00e9diatement le PC pour analyser hors de Windows (rootkits). Enregistre ton travail avant.",
    "confirm": true,
    "script": "Write-TKLog 'Lancement de l''analyse hors ligne : red\u00e9marrage imminent.' 'WARN'; Start-MpWDOScan" }
]
'@ | ConvertFrom-Json
$sync.configs.presets = @'
[
  { "name": "SAV standard", "description": "Confort technicien + s\u00e9curit\u00e9 de base, sans risque de casse.",
    "tweaks": ["TK_FileExt", "TK_FastStartup", "TK_VerboseStatus", "TK_EndTask", "TK_AutorunOff", "TK_Firewall"] },
  { "name": "Confidentialit\u00e9", "description": "T\u00e9l\u00e9m\u00e9trie, publicit\u00e9, Bing, Copilot/Recall.",
    "tweaks": ["TK_Telemetry", "TK_AdvertisingID", "TK_Suggestions", "TK_BingSearch", "TK_ActivityHistory", "TK_CopilotRecall"] },
  { "name": "Durcissement poste", "description": "Baseline s\u00e9curit\u00e9 applicable partout.",
    "tweaks": ["TK_FileExt", "TK_Firewall", "TK_SMB1Off", "TK_LLMNROff", "TK_AutorunOff", "TK_WDigestOff", "TK_PUA", "TK_RemoteAssistOff", "TK_PSv2Off", "TK_AuditLogging"] },
  { "name": "Durcissement renforc\u00e9", "description": "Baseline + mesures \u00e0 tester avant (vieux NAS, copieurs, pilotes).",
    "tweaks": ["TK_FileExt", "TK_Firewall", "TK_SMB1Off", "TK_LLMNROff", "TK_AutorunOff", "TK_WDigestOff", "TK_PUA", "TK_RemoteAssistOff", "TK_PSv2Off", "TK_AuditLogging", "TK_NetBIOSOff", "TK_SMBSigning", "TK_NTLMv2Only", "TK_LSAPPL", "TK_UACMax", "TK_ASRAudit"] }
]
'@ | ConvertFrom-Json
$sync.configs.tweaks = @'
[
  {
    "id": "TK_FileExt", "category": "Confort & SAV", "risk": "low",
    "name": "Afficher les extensions de fichiers",
    "description": "Rend visibles les .exe/.js d\u00e9guis\u00e9s en documents (facture.pdf.exe). Utile en SAV comme en s\u00e9curit\u00e9.",
    "restartExplorer": true,
    "registry": [
      { "path": "HKCU:\\Software\\Microsoft\\Windows\\CurrentVersion\\Explorer\\Advanced", "name": "HideFileExt", "type": "DWord", "value": "0", "original": "1" }
    ]
  },
  {
    "id": "TK_HiddenFiles", "category": "Confort & SAV", "risk": "low",
    "name": "Afficher les fichiers cach\u00e9s",
    "description": "Affiche les fichiers et dossiers cach\u00e9s dans l'Explorateur (AppData, ProgramData...).",
    "restartExplorer": true,
    "registry": [
      { "path": "HKCU:\\Software\\Microsoft\\Windows\\CurrentVersion\\Explorer\\Advanced", "name": "Hidden", "type": "DWord", "value": "1", "original": "2" }
    ]
  },
  {
    "id": "TK_FastStartup", "category": "Confort & SAV", "risk": "low",
    "name": "D\u00e9sactiver le d\u00e9marrage rapide",
    "description": "Un arr\u00eat devient un vrai arr\u00eat : fini les pilotes et mises \u00e0 jour bloqu\u00e9s par l'hibernation hybride.",
    "registry": [
      { "path": "HKLM:\\SYSTEM\\CurrentControlSet\\Control\\Session Manager\\Power", "name": "HiberbootEnabled", "type": "DWord", "value": "0", "original": "1" }
    ]
  },
  {
    "id": "TK_VerboseStatus", "category": "Confort & SAV", "risk": "low",
    "name": "Messages de d\u00e9marrage d\u00e9taill\u00e9s",
    "description": "Affiche ce que Windows fait au d\u00e9marrage/arr\u00eat (au lieu de \u00ab Veuillez patienter \u00bb). Aide \u00e0 rep\u00e9rer un blocage.",
    "registry": [
      { "path": "HKLM:\\SOFTWARE\\Microsoft\\Windows\\CurrentVersion\\Policies\\System", "name": "VerboseStatus", "type": "DWord", "value": "1", "original": "<RemoveEntry>" }
    ]
  },
  {
    "id": "TK_EndTask", "category": "Confort & SAV", "risk": "low",
    "name": "\u00ab Fin de t\u00e2che \u00bb dans la barre des t\u00e2ches",
    "description": "Windows 11 : clic droit sur une appli de la barre des t\u00e2ches > Fin de t\u00e2che.",
    "registry": [
      { "path": "HKCU:\\Software\\Microsoft\\Windows\\CurrentVersion\\Explorer\\Advanced\\TaskbarDeveloperSettings", "name": "TaskbarEndTask", "type": "DWord", "value": "1", "original": "<RemoveEntry>" }
    ]
  },
  {
    "id": "TK_ClassicMenu", "category": "Confort & SAV", "risk": "low",
    "name": "Menu contextuel classique (Windows 11)",
    "description": "R\u00e9tablit le clic droit complet sans passer par \u00ab Afficher plus d'options \u00bb.",
    "restartExplorer": true,
    "invoke": "New-Item -Path 'HKCU:\\Software\\Classes\\CLSID\\{86ca1aa0-34aa-4e8b-a509-50c905bae2a2}\\InprocServer32' -Value '' -Force | Out-Null",
    "undo": "Remove-Item -Path 'HKCU:\\Software\\Classes\\CLSID\\{86ca1aa0-34aa-4e8b-a509-50c905bae2a2}' -Recurse -Force -ErrorAction SilentlyContinue",
    "test": "Test-Path 'HKCU:\\Software\\Classes\\CLSID\\{86ca1aa0-34aa-4e8b-a509-50c905bae2a2}\\InprocServer32'"
  },

  {
    "id": "TK_Telemetry", "category": "Confidentialit\u00e9", "risk": "low",
    "name": "T\u00e9l\u00e9m\u00e9trie au minimum",
    "description": "Strat\u00e9gie de collecte au niveau le plus bas autoris\u00e9 par l'\u00e9dition + services DiagTrack et dmwappushservice d\u00e9sactiv\u00e9s.",
    "registry": [
      { "path": "HKLM:\\SOFTWARE\\Policies\\Microsoft\\Windows\\DataCollection", "name": "AllowTelemetry", "type": "DWord", "value": "0", "original": "<RemoveEntry>" }
    ],
    "services": [
      { "name": "DiagTrack", "startup": "Disabled", "original": "Automatic" },
      { "name": "dmwappushservice", "startup": "Disabled", "original": "Manual" }
    ]
  },
  {
    "id": "TK_AdvertisingID", "category": "Confidentialit\u00e9", "risk": "low",
    "name": "D\u00e9sactiver l'identifiant publicitaire",
    "description": "Emp\u00eache les applications d'utiliser l'ID publicitaire pour le profilage.",
    "registry": [
      { "path": "HKCU:\\Software\\Microsoft\\Windows\\CurrentVersion\\AdvertisingInfo", "name": "Enabled", "type": "DWord", "value": "0", "original": "1" },
      { "path": "HKLM:\\SOFTWARE\\Policies\\Microsoft\\Windows\\AdvertisingInfo", "name": "DisabledByGroupPolicy", "type": "DWord", "value": "1", "original": "<RemoveEntry>" }
    ]
  },
  {
    "id": "TK_Suggestions", "category": "Confidentialit\u00e9", "risk": "low",
    "name": "Supprimer suggestions et applis sponsoris\u00e9es",
    "description": "Bloque l'installation silencieuse d'applis promues et les \u00ab conseils \u00bb dans D\u00e9marrer/Param\u00e8tres.",
    "registry": [
      { "path": "HKCU:\\Software\\Microsoft\\Windows\\CurrentVersion\\ContentDeliveryManager", "name": "SilentInstalledAppsEnabled", "type": "DWord", "value": "0", "original": "1" },
      { "path": "HKCU:\\Software\\Microsoft\\Windows\\CurrentVersion\\ContentDeliveryManager", "name": "SystemPaneSuggestionsEnabled", "type": "DWord", "value": "0", "original": "1" },
      { "path": "HKCU:\\Software\\Microsoft\\Windows\\CurrentVersion\\ContentDeliveryManager", "name": "SoftLandingEnabled", "type": "DWord", "value": "0", "original": "1" },
      { "path": "HKCU:\\Software\\Microsoft\\Windows\\CurrentVersion\\ContentDeliveryManager", "name": "SubscribedContent-338388Enabled", "type": "DWord", "value": "0", "original": "1" },
      { "path": "HKCU:\\Software\\Microsoft\\Windows\\CurrentVersion\\ContentDeliveryManager", "name": "SubscribedContent-338389Enabled", "type": "DWord", "value": "0", "original": "1" }
    ]
  },
  {
    "id": "TK_BingSearch", "category": "Confidentialit\u00e9", "risk": "low",
    "name": "Retirer Bing de la recherche D\u00e9marrer",
    "description": "La recherche du menu D\u00e9marrer reste locale (fichiers, applis, param\u00e8tres).",
    "restartExplorer": true,
    "registry": [
      { "path": "HKCU:\\Software\\Policies\\Microsoft\\Windows\\Explorer", "name": "DisableSearchBoxSuggestions", "type": "DWord", "value": "1", "original": "<RemoveEntry>" }
    ]
  },
  {
    "id": "TK_ActivityHistory", "category": "Confidentialit\u00e9", "risk": "low",
    "name": "D\u00e9sactiver l'historique d'activit\u00e9",
    "description": "Windows n'enregistre plus ni n'envoie la chronologie des applis et documents ouverts.",
    "registry": [
      { "path": "HKLM:\\SOFTWARE\\Policies\\Microsoft\\Windows\\System", "name": "EnableActivityFeed", "type": "DWord", "value": "0", "original": "<RemoveEntry>" },
      { "path": "HKLM:\\SOFTWARE\\Policies\\Microsoft\\Windows\\System", "name": "PublishUserActivities", "type": "DWord", "value": "0", "original": "<RemoveEntry>" },
      { "path": "HKLM:\\SOFTWARE\\Policies\\Microsoft\\Windows\\System", "name": "UploadUserActivities", "type": "DWord", "value": "0", "original": "<RemoveEntry>" }
    ]
  },
  {
    "id": "TK_CopilotRecall", "category": "Confidentialit\u00e9", "risk": "low",
    "name": "D\u00e9sactiver Copilot (strat\u00e9gie) et Recall",
    "description": "Strat\u00e9gies de d\u00e9sactivation de Windows Copilot et de l'analyse d'instantan\u00e9s Recall. L'appli Copilot du Store, si install\u00e9e, reste \u00e0 d\u00e9sinstaller.",
    "registry": [
      { "path": "HKCU:\\Software\\Policies\\Microsoft\\Windows\\WindowsCopilot", "name": "TurnOffWindowsCopilot", "type": "DWord", "value": "1", "original": "<RemoveEntry>" },
      { "path": "HKLM:\\SOFTWARE\\Policies\\Microsoft\\Windows\\WindowsAI", "name": "DisableAIDataAnalysis", "type": "DWord", "value": "1", "original": "<RemoveEntry>" }
    ]
  },

  {
    "id": "TK_Firewall", "category": "Durcissement", "risk": "low",
    "name": "Pare-feu actif sur tous les profils",
    "description": "Active le pare-feu Windows (domaine, priv\u00e9, public). Volontairement non annul\u00e9.",
    "invoke": "Set-NetFirewallProfile -All -Enabled True",
    "undo": "Write-TKLog 'Pare-feu : annulation volontairement ignor\u00e9e.' 'WARN'",
    "test": "@(Get-NetFirewallProfile | Where-Object { -not $_.Enabled }).Count -eq 0"
  },
  {
    "id": "TK_SMB1Off", "category": "Durcissement", "risk": "low", "reboot": true,
    "name": "D\u00e9sactiver SMBv1",
    "description": "Protocole obsol\u00e8te exploit\u00e9 par WannaCry/NotPetya. Attention aux tr\u00e8s vieux NAS/copieurs qui en d\u00e9pendent encore.",
    "invoke": "Set-SmbServerConfiguration -EnableSMB1Protocol $false -Force -ErrorAction SilentlyContinue; $f = Get-WindowsOptionalFeature -Online -FeatureName SMB1Protocol -ErrorAction SilentlyContinue; if ($f -and $f.State -eq 'Enabled') { Disable-WindowsOptionalFeature -Online -FeatureName SMB1Protocol -NoRestart -ErrorAction SilentlyContinue | Out-Null }",
    "undo": "Set-SmbServerConfiguration -EnableSMB1Protocol $true -Force -ErrorAction SilentlyContinue",
    "test": "-not (Get-SmbServerConfiguration).EnableSMB1Protocol"
  },
  {
    "id": "TK_LLMNROff", "category": "Durcissement", "risk": "low",
    "name": "D\u00e9sactiver LLMNR",
    "description": "Coupe la r\u00e9solution de noms multicast, cible classique de l'empoisonnement (Responder) pour voler des hash NTLM.",
    "registry": [
      { "path": "HKLM:\\SOFTWARE\\Policies\\Microsoft\\Windows NT\\DNSClient", "name": "EnableMulticast", "type": "DWord", "value": "0", "original": "<RemoveEntry>" }
    ]
  },
  {
    "id": "TK_AutorunOff", "category": "Durcissement", "risk": "low",
    "name": "D\u00e9sactiver l'ex\u00e9cution automatique",
    "description": "Aucune ex\u00e9cution automatique \u00e0 l'insertion d'une cl\u00e9 USB, d'un CD ou d'un partage.",
    "registry": [
      { "path": "HKLM:\\SOFTWARE\\Microsoft\\Windows\\CurrentVersion\\Policies\\Explorer", "name": "NoDriveTypeAutoRun", "type": "DWord", "value": "255", "original": "<RemoveEntry>" },
      { "path": "HKLM:\\SOFTWARE\\Microsoft\\Windows\\CurrentVersion\\Policies\\Explorer", "name": "NoAutorun", "type": "DWord", "value": "1", "original": "<RemoveEntry>" }
    ]
  },
  {
    "id": "TK_WDigestOff", "category": "Durcissement", "risk": "low",
    "name": "Interdire les mots de passe en clair (WDigest)",
    "description": "Emp\u00eache LSASS de garder les mots de passe en clair en m\u00e9moire (cible privil\u00e9gi\u00e9e des outils de vol d'identifiants).",
    "registry": [
      { "path": "HKLM:\\SYSTEM\\CurrentControlSet\\Control\\SecurityProviders\\WDigest", "name": "UseLogonCredential", "type": "DWord", "value": "0", "original": "<RemoveEntry>" }
    ]
  },
  {
    "id": "TK_PUA", "category": "Durcissement", "risk": "low",
    "name": "Defender : bloquer les applis ind\u00e9sirables (PUA)",
    "description": "Bloque adwares, bundlers et outils potentiellement ind\u00e9sirables. Sans effet si un antivirus tiers remplace Defender.",
    "invoke": "Set-MpPreference -PUAProtection Enabled -ErrorAction Stop",
    "undo": "Set-MpPreference -PUAProtection Disabled -ErrorAction SilentlyContinue",
    "test": "(Get-MpPreference -ErrorAction Stop).PUAProtection -eq 1"
  },
  {
    "id": "TK_RemoteAssistOff", "category": "Durcissement", "risk": "low",
    "name": "D\u00e9sactiver l'Assistance \u00e0 distance",
    "description": "Ferme l'invitation d'Assistance \u00e0 distance Windows (souvent abus\u00e9e par les faux supports techniques). N'affecte pas le RDP.",
    "registry": [
      { "path": "HKLM:\\SYSTEM\\CurrentControlSet\\Control\\Remote Assistance", "name": "fAllowToGetHelp", "type": "DWord", "value": "0", "original": "1" }
    ]
  },
  {
    "id": "TK_PSv2Off", "category": "Durcissement", "risk": "low",
    "name": "Retirer PowerShell 2.0",
    "description": "PowerShell 2 ne journalise rien : il sert \u00e0 contourner les protections. D\u00e9j\u00e0 absent sur les Windows 11 r\u00e9cents.",
    "invoke": "$f = Get-WindowsOptionalFeature -Online -FeatureName MicrosoftWindowsPowerShellV2Root -ErrorAction SilentlyContinue; if ($f -and $f.State -eq 'Enabled') { Disable-WindowsOptionalFeature -Online -FeatureName MicrosoftWindowsPowerShellV2Root -NoRestart -ErrorAction SilentlyContinue | Out-Null }",
    "undo": "Enable-WindowsOptionalFeature -Online -FeatureName MicrosoftWindowsPowerShellV2Root -NoRestart -ErrorAction SilentlyContinue | Out-Null",
    "test": "$f = Get-WindowsOptionalFeature -Online -FeatureName MicrosoftWindowsPowerShellV2Root -ErrorAction SilentlyContinue; (-not $f) -or ($f.State -ne 'Enabled')"
  },
  {
    "id": "TK_AuditLogging", "category": "Durcissement", "risk": "low",
    "name": "Journalisation de s\u00e9curit\u00e9 renforc\u00e9e",
    "description": "Audit de cr\u00e9ation de processus avec ligne de commande (4688), journalisation des blocs de script PowerShell (4104), journal S\u00e9curit\u00e9 \u00e0 512 Mo. Indispensable pour enqu\u00eater apr\u00e8s un incident.",
    "registry": [
      { "path": "HKLM:\\SOFTWARE\\Microsoft\\Windows\\CurrentVersion\\Policies\\System\\Audit", "name": "ProcessCreationIncludeCmdLine_Enabled", "type": "DWord", "value": "1", "original": "<RemoveEntry>" },
      { "path": "HKLM:\\SOFTWARE\\Policies\\Microsoft\\Windows\\PowerShell\\ScriptBlockLogging", "name": "EnableScriptBlockLogging", "type": "DWord", "value": "1", "original": "<RemoveEntry>" }
    ],
    "invoke": "auditpol.exe /set /subcategory:'{0CCE922B-69AE-11D9-BED3-505054503030}' /success:enable /failure:enable | Out-Null; wevtutil.exe sl Security /ms:536870912",
    "undo": "auditpol.exe /set /subcategory:'{0CCE922B-69AE-11D9-BED3-505054503030}' /success:disable /failure:disable | Out-Null"
  },

  {
    "id": "TK_NetBIOSOff", "category": "Durcissement renforc\u00e9", "risk": "medium",
    "name": "D\u00e9sactiver NetBIOS sur TCP/IP",
    "description": "M\u00eame logique que LLMNR. Peut casser la d\u00e9couverte de tr\u00e8s vieux NAS/imprimantes par leur nom court.",
    "invoke": "Get-ChildItem 'HKLM:\\SYSTEM\\CurrentControlSet\\Services\\NetBT\\Parameters\\Interfaces' | ForEach-Object { Set-ItemProperty -Path $_.PSPath -Name NetbiosOptions -Value 2 -Type DWord }",
    "undo": "Get-ChildItem 'HKLM:\\SYSTEM\\CurrentControlSet\\Services\\NetBT\\Parameters\\Interfaces' | ForEach-Object { Set-ItemProperty -Path $_.PSPath -Name NetbiosOptions -Value 0 -Type DWord }",
    "test": "@(Get-ChildItem 'HKLM:\\SYSTEM\\CurrentControlSet\\Services\\NetBT\\Parameters\\Interfaces' | Where-Object { (Get-ItemProperty $_.PSPath).NetbiosOptions -ne 2 }).Count -eq 0"
  },
  {
    "id": "TK_SMBSigning", "category": "Durcissement renforc\u00e9", "risk": "medium",
    "name": "Signature SMB obligatoire",
    "description": "Bloque le relais NTLM sur SMB. D\u00e9j\u00e0 le d\u00e9faut sur Windows 11 24H2. Vieux NAS/copieurs : tester avant.",
    "registry": [
      { "path": "HKLM:\\SYSTEM\\CurrentControlSet\\Services\\LanmanWorkstation\\Parameters", "name": "RequireSecuritySignature", "type": "DWord", "value": "1", "original": "0" },
      { "path": "HKLM:\\SYSTEM\\CurrentControlSet\\Services\\LanmanServer\\Parameters", "name": "RequireSecuritySignature", "type": "DWord", "value": "1", "original": "0" }
    ]
  },
  {
    "id": "TK_NTLMv2Only", "category": "Durcissement renforc\u00e9", "risk": "medium",
    "name": "NTLMv2 uniquement (refus LM et NTLMv1)",
    "description": "LmCompatibilityLevel = 5. Peut casser l'authentification de tr\u00e8s vieux \u00e9quipements.",
    "registry": [
      { "path": "HKLM:\\SYSTEM\\CurrentControlSet\\Control\\Lsa", "name": "LmCompatibilityLevel", "type": "DWord", "value": "5", "original": "<RemoveEntry>" }
    ]
  },
  {
    "id": "TK_LSAPPL", "category": "Durcissement renforc\u00e9", "risk": "medium", "reboot": true,
    "name": "Protection LSA (RunAsPPL)",
    "description": "LSASS tourne en processus prot\u00e9g\u00e9 : bloque l'extraction d'identifiants. Certains vieux pilotes/AV peuvent ne pas aimer : tester.",
    "registry": [
      { "path": "HKLM:\\SYSTEM\\CurrentControlSet\\Control\\Lsa", "name": "RunAsPPL", "type": "DWord", "value": "1", "original": "<RemoveEntry>" }
    ]
  },
  {
    "id": "TK_UACMax", "category": "Durcissement renforc\u00e9", "risk": "medium",
    "name": "UAC au niveau maximal",
    "description": "Demande de confirmation sur le bureau s\u00e9curis\u00e9 pour toute \u00e9l\u00e9vation, y compris les r\u00e9glages Windows.",
    "registry": [
      { "path": "HKLM:\\SOFTWARE\\Microsoft\\Windows\\CurrentVersion\\Policies\\System", "name": "ConsentPromptBehaviorAdmin", "type": "DWord", "value": "2", "original": "5" },
      { "path": "HKLM:\\SOFTWARE\\Microsoft\\Windows\\CurrentVersion\\Policies\\System", "name": "PromptOnSecureDesktop", "type": "DWord", "value": "1", "original": "1" }
    ]
  },
  {
    "id": "TK_ASRAudit", "category": "Durcissement renforc\u00e9", "risk": "low",
    "name": "R\u00e8gles ASR Defender (mode audit)",
    "description": "6 r\u00e8gles anti-macros, anti-scripts et anti-vol LSASS en mode AUDIT : journalise (\u00e9v\u00e9nement 1122) sans bloquer. Passe en blocage apr\u00e8s analyse. N\u00e9cessite Defender actif.",
    "invoke": "$ids = 'D4F940AB-401B-4EFC-AADC-AD5F3C50688A','BE9BA2D9-53EA-4CDC-84E5-9B1EEEE46550','9E6C4E1F-7D60-472F-BA1A-A39EF669E4B2','D3E037E1-3EB8-44C8-A917-57927947596D','5BEB7EFE-FD9A-4556-801D-275E5FFC04CC','92E97FA1-2EDF-4476-BDD6-9DD0B4DDDC7B'; Add-MpPreference -AttackSurfaceReductionRules_Ids $ids -AttackSurfaceReductionRules_Actions (@('AuditMode') * $ids.Count) -ErrorAction Stop",
    "undo": "$ids = 'D4F940AB-401B-4EFC-AADC-AD5F3C50688A','BE9BA2D9-53EA-4CDC-84E5-9B1EEEE46550','9E6C4E1F-7D60-472F-BA1A-A39EF669E4B2','D3E037E1-3EB8-44C8-A917-57927947596D','5BEB7EFE-FD9A-4556-801D-275E5FFC04CC','92E97FA1-2EDF-4476-BDD6-9DD0B4DDDC7B'; Remove-MpPreference -AttackSurfaceReductionRules_Ids $ids -ErrorAction SilentlyContinue",
    "test": "$cur = @((Get-MpPreference -ErrorAction Stop).AttackSurfaceReductionRules_Ids) | ForEach-Object { $_.ToUpper() }; @('D4F940AB-401B-4EFC-AADC-AD5F3C50688A','BE9BA2D9-53EA-4CDC-84E5-9B1EEEE46550','9E6C4E1F-7D60-472F-BA1A-A39EF669E4B2','D3E037E1-3EB8-44C8-A917-57927947596D','5BEB7EFE-FD9A-4556-801D-275E5FFC04CC','92E97FA1-2EDF-4476-BDD6-9DD0B4DDDC7B' | Where-Object { $cur -notcontains $_ }).Count -eq 0"
  }
]
'@ | ConvertFrom-Json
# ---------------------------------------------------------------- xaml
$inputXML = @'
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
        xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
        Title="Tech Toolkit" Width="1180" Height="800" MinWidth="960" MinHeight="640"
        WindowStartupLocation="CenterScreen" Background="#0D1117" Foreground="#C9D1D9"
        FontFamily="Segoe UI" FontSize="13">
  <Window.Resources>
    <SolidColorBrush x:Key="Accent" Color="#58A6FF"/>
    <SolidColorBrush x:Key="Panel" Color="#161B22"/>
    <SolidColorBrush x:Key="Line" Color="#30363D"/>
    <SolidColorBrush x:Key="Muted" Color="#8B949E"/>

    <Style x:Key="Btn" TargetType="Button">
      <Setter Property="Background" Value="#21262D"/>
      <Setter Property="Foreground" Value="#C9D1D9"/>
      <Setter Property="BorderBrush" Value="#30363D"/>
      <Setter Property="BorderThickness" Value="1"/>
      <Setter Property="Padding" Value="12,7"/>
      <Setter Property="Margin" Value="0,3"/>
      <Setter Property="Cursor" Value="Hand"/>
      <Setter Property="HorizontalContentAlignment" Value="Left"/>
      <Setter Property="Template">
        <Setter.Value>
          <ControlTemplate TargetType="Button">
            <Border x:Name="Bd" Background="{TemplateBinding Background}" BorderBrush="{TemplateBinding BorderBrush}"
                    BorderThickness="{TemplateBinding BorderThickness}" CornerRadius="6" Padding="{TemplateBinding Padding}">
              <ContentPresenter HorizontalAlignment="{TemplateBinding HorizontalContentAlignment}" VerticalAlignment="Center"/>
            </Border>
            <ControlTemplate.Triggers>
              <Trigger Property="IsMouseOver" Value="True">
                <Setter TargetName="Bd" Property="BorderBrush" Value="#58A6FF"/>
              </Trigger>
              <Trigger Property="IsEnabled" Value="False">
                <Setter TargetName="Bd" Property="Opacity" Value="0.45"/>
              </Trigger>
            </ControlTemplate.Triggers>
          </ControlTemplate>
        </Setter.Value>
      </Setter>
    </Style>
    <Style x:Key="BtnAccent" TargetType="Button" BasedOn="{StaticResource Btn}">
      <Setter Property="Background" Value="#1F6FEB"/>
      <Setter Property="Foreground" Value="White"/>
      <Setter Property="BorderBrush" Value="#388BFD"/>
      <Setter Property="FontWeight" Value="SemiBold"/>
    </Style>
    <Style x:Key="BtnDanger" TargetType="Button" BasedOn="{StaticResource Btn}">
      <Setter Property="Foreground" Value="#F85149"/>
    </Style>

    <Style TargetType="CheckBox">
      <Setter Property="Foreground" Value="#E6EDF3"/>
      <Setter Property="Margin" Value="0,2"/>
      <Setter Property="Cursor" Value="Hand"/>
    </Style>

    <Style TargetType="TabControl">
      <Setter Property="Background" Value="Transparent"/>
      <Setter Property="BorderThickness" Value="0"/>
      <Setter Property="Padding" Value="0"/>
    </Style>
    <Style TargetType="TabItem">
      <Setter Property="Foreground" Value="#8B949E"/>
      <Setter Property="Template">
        <Setter.Value>
          <ControlTemplate TargetType="TabItem">
            <Border x:Name="Bd" BorderThickness="0,0,0,2" BorderBrush="Transparent" Padding="16,10" Margin="0,0,4,0" Cursor="Hand">
              <ContentPresenter ContentSource="Header" TextElement.FontSize="14"/>
            </Border>
            <ControlTemplate.Triggers>
              <Trigger Property="IsSelected" Value="True">
                <Setter TargetName="Bd" Property="BorderBrush" Value="#58A6FF"/>
                <Setter Property="Foreground" Value="#E6EDF3"/>
              </Trigger>
              <Trigger Property="IsMouseOver" Value="True">
                <Setter Property="Foreground" Value="#E6EDF3"/>
              </Trigger>
            </ControlTemplate.Triggers>
          </ControlTemplate>
        </Setter.Value>
      </Setter>
    </Style>

    <Style TargetType="DataGridColumnHeader">
      <Setter Property="Background" Value="#161B22"/>
      <Setter Property="Foreground" Value="#8B949E"/>
      <Setter Property="Padding" Value="8,6"/>
      <Setter Property="BorderBrush" Value="#30363D"/>
      <Setter Property="BorderThickness" Value="0,0,0,1"/>
      <Setter Property="FontWeight" Value="SemiBold"/>
    </Style>
  </Window.Resources>

  <Grid Margin="18,12,18,12">
    <Grid.RowDefinitions>
      <RowDefinition Height="Auto"/>
      <RowDefinition Height="*"/>
      <RowDefinition Height="Auto"/>
      <RowDefinition Height="Auto"/>
    </Grid.RowDefinitions>

    <!-- En-tete -->
    <DockPanel Grid.Row="0" Margin="0,0,0,8">
      <StackPanel DockPanel.Dock="Left" Orientation="Horizontal" VerticalAlignment="Center">
        <Border Background="#1F6FEB" CornerRadius="8" Width="40" Height="40" Margin="0,0,12,0">
          <TextBlock Text="TK" Foreground="White" FontWeight="Bold" FontSize="17" HorizontalAlignment="Center" VerticalAlignment="Center"/>
        </Border>
        <StackPanel VerticalAlignment="Center">
          <TextBlock Text="TECH TOOLKIT" FontSize="20" FontWeight="Bold" Foreground="#E6EDF3"/>
          <TextBlock x:Name="TxtVersion" Foreground="#8B949E" FontSize="11"/>
        </StackPanel>
      </StackPanel>
      <StackPanel DockPanel.Dock="Right" HorizontalAlignment="Right" VerticalAlignment="Center">
        <StackPanel Orientation="Horizontal" HorizontalAlignment="Right">
          <Border x:Name="BdMode" CornerRadius="10" Padding="10,2" Margin="0,0,8,0" Background="#331F6FEB">
            <TextBlock x:Name="TxtMode" FontSize="11" FontWeight="Bold" Foreground="#58A6FF"/>
          </Border>
          <TextBlock x:Name="TxtMachine" Foreground="#E6EDF3" FontWeight="SemiBold"/>
        </StackPanel>
        <TextBlock x:Name="TxtMachine2" Foreground="#8B949E" FontSize="11" HorizontalAlignment="Right" Margin="0,3,0,0"/>
      </StackPanel>
    </DockPanel>

    <TabControl Grid.Row="1" x:Name="Tabs">

      <!-- ===================== TWEAKS ===================== -->
      <TabItem Header="Tweaks &amp; durcissement">
        <Grid Margin="0,10,0,0">
          <Grid.ColumnDefinitions>
            <ColumnDefinition Width="250"/>
            <ColumnDefinition Width="*"/>
          </Grid.ColumnDefinitions>
          <Border Grid.Column="0" Background="{StaticResource Panel}" BorderBrush="{StaticResource Line}" BorderThickness="1" CornerRadius="8" Padding="14" Margin="0,0,12,0">
            <DockPanel>
              <StackPanel DockPanel.Dock="Top">
                <TextBlock Text="PROFILS" Foreground="#8B949E" FontSize="11" FontWeight="Bold" Margin="0,0,0,6"/>
                <StackPanel x:Name="PresetPanel"/>
                <Separator Margin="0,12" Background="#30363D"/>
                <CheckBox x:Name="ChkRestore" Content="Point de restauration avant" IsChecked="True"/>
                <Button x:Name="BtnApply" Style="{StaticResource BtnAccent}" Content="Appliquer la s&#x00E9;lection" Margin="0,10,0,3"/>
                <Button x:Name="BtnUndo" Style="{StaticResource Btn}" Content="Annuler la s&#x00E9;lection"/>
                <Button x:Name="BtnRefresh" Style="{StaticResource Btn}" Content="Actualiser l'&#x00E9;tat"/>
                <Button x:Name="BtnClear" Style="{StaticResource Btn}" Content="Tout d&#x00E9;cocher"/>
              </StackPanel>
              <TextBlock DockPanel.Dock="Bottom" VerticalAlignment="Bottom" TextWrapping="Wrap" Foreground="#8B949E" FontSize="11"
                         Text="Les valeurs d'origine sont sauvegard&#x00E9;es &#x00E0; la 1re application (ProgramData\TechToolkit\state.json). &#x00AB; Annuler &#x00BB; les restaure."/>
            </DockPanel>
          </Border>
          <Border Grid.Column="1" Background="{StaticResource Panel}" BorderBrush="{StaticResource Line}" BorderThickness="1" CornerRadius="8">
            <ScrollViewer VerticalScrollBarVisibility="Auto" Padding="16,4,16,12">
              <StackPanel x:Name="TweaksPanel"/>
            </ScrollViewer>
          </Border>
        </Grid>
      </TabItem>

      <!-- ===================== CONTROLE ===================== -->
      <TabItem Header="Contr&#x00F4;le &amp; nettoyage">
        <Grid Margin="0,10,0,0">
          <Grid.ColumnDefinitions>
            <ColumnDefinition Width="*"/>
            <ColumnDefinition Width="350"/>
          </Grid.ColumnDefinitions>
          <DockPanel Grid.Column="0" Margin="0,0,12,0">
            <StackPanel DockPanel.Dock="Top" Orientation="Horizontal" Margin="0,0,0,8">
              <Button x:Name="BtnCheck" Style="{StaticResource BtnAccent}" Content="Lancer le contr&#x00F4;le" Margin="0,0,8,0"/>
              <Button x:Name="BtnReport" Style="{StaticResource Btn}" Content="Ouvrir le rapport HTML" IsEnabled="False" Margin="0,0,8,0"/>
              <Button x:Name="BtnFolder" Style="{StaticResource Btn}" Content="Dossier des rapports" Margin="0,0,16,0"/>
              <TextBlock x:Name="TxtCheckSummary" VerticalAlignment="Center" Foreground="#8B949E"/>
            </StackPanel>
            <Border Background="{StaticResource Panel}" BorderBrush="{StaticResource Line}" BorderThickness="1" CornerRadius="8">
              <DataGrid x:Name="GridCheck" AutoGenerateColumns="False" IsReadOnly="True" CanUserAddRows="False"
                        HeadersVisibility="Column" GridLinesVisibility="Horizontal" HorizontalGridLinesBrush="#21262D"
                        Background="Transparent" RowBackground="#161B22" AlternatingRowBackground="#121821"
                        Foreground="#C9D1D9" BorderThickness="0" SelectionMode="Single">
                <DataGrid.RowStyle>
                  <Style TargetType="DataGridRow">
                    <Style.Triggers>
                      <DataTrigger Binding="{Binding Etat}" Value="KO"><Setter Property="Foreground" Value="#F85149"/></DataTrigger>
                      <DataTrigger Binding="{Binding Etat}" Value="WARN"><Setter Property="Foreground" Value="#D29922"/></DataTrigger>
                      <DataTrigger Binding="{Binding Etat}" Value="OK"><Setter Property="Foreground" Value="#3FB950"/></DataTrigger>
                    </Style.Triggers>
                  </Style>
                </DataGrid.RowStyle>
                <DataGrid.Columns>
                  <DataGridTextColumn Header="&#x00C9;tat" Binding="{Binding Etat}" Width="60"/>
                  <DataGridTextColumn Header="Cat&#x00E9;gorie" Binding="{Binding Categorie}" Width="110"/>
                  <DataGridTextColumn Header="Contr&#x00F4;le" Binding="{Binding Controle}" Width="210"/>
                  <DataGridTextColumn Header="D&#x00E9;tail" Binding="{Binding Detail}" Width="*"/>
                </DataGrid.Columns>
              </DataGrid>
            </Border>
          </DockPanel>
          <Border Grid.Column="1" Background="{StaticResource Panel}" BorderBrush="{StaticResource Line}" BorderThickness="1" CornerRadius="8" Padding="14">
            <DockPanel>
              <TextBlock DockPanel.Dock="Top" Text="NETTOYAGE &amp; R&#x00C9;PARATION" Foreground="#8B949E" FontSize="11" FontWeight="Bold" Margin="0,0,0,4"/>
              <StackPanel DockPanel.Dock="Bottom">
                <Button x:Name="BtnRunCleanup" Style="{StaticResource BtnAccent}" Content="Ex&#x00E9;cuter la s&#x00E9;lection" Margin="0,8,0,6"/>
                <TextBlock TextWrapping="Wrap" Foreground="#8B949E" FontSize="11"
                           Text="Volontairement absents : effacement des journaux d'&#x00E9;v&#x00E9;nements et du Prefetch. Ce sont des traces pr&#x00E9;cieuses en cas d'incident."/>
              </StackPanel>
              <ScrollViewer VerticalScrollBarVisibility="Auto">
                <StackPanel x:Name="CleanupPanel"/>
              </ScrollViewer>
            </DockPanel>
          </Border>
        </Grid>
      </TabItem>

      <!-- ===================== OUTILS CLE ===================== -->
      <TabItem x:Name="TabTools" Header="Outils de la cl&#x00E9;">
        <Border Background="{StaticResource Panel}" BorderBrush="{StaticResource Line}" BorderThickness="1" CornerRadius="8" Padding="14" Margin="0,10,0,0">
          <DockPanel>
            <StackPanel DockPanel.Dock="Top" Orientation="Horizontal" Margin="0,0,0,10">
              <TextBlock Text="Cat&#x00E9;gorie" VerticalAlignment="Center" Margin="0,0,8,0"/>
              <ComboBox x:Name="CmbToolCat" Width="200" Margin="0,0,12,0"/>
              <Button x:Name="BtnLaunchTool" Style="{StaticResource BtnAccent}" Content="Lancer l'outil" Margin="0,0,12,0"/>
              <TextBlock x:Name="TxtToolsInfo" VerticalAlignment="Center" Foreground="#8B949E"/>
            </StackPanel>
            <ListBox x:Name="LstTools" Background="#0D1117" Foreground="#E6EDF3" BorderBrush="#30363D" DisplayMemberPath="Display" FontSize="13"/>
          </DockPanel>
        </Border>
      </TabItem>
    </TabControl>

    <!-- Statut -->
    <DockPanel Grid.Row="2" Margin="0,8,0,4">
      <ProgressBar x:Name="Progress" DockPanel.Dock="Right" Width="220" Height="6" Foreground="#58A6FF" Background="#21262D" BorderThickness="0" Visibility="Hidden"/>
      <TextBlock x:Name="TxtStatus" Foreground="#8B949E" Text="Pr&#x00EA;t"/>
    </DockPanel>

    <!-- Journal -->
    <Expander Grid.Row="3" Header="Journal" IsExpanded="True" Foreground="#8B949E">
      <TextBox x:Name="LogBox" Height="130" IsReadOnly="True" Background="#010409" Foreground="#C9D1D9" BorderBrush="#30363D"
               FontFamily="Consolas" FontSize="12" VerticalScrollBarVisibility="Auto" TextWrapping="NoWrap" Margin="0,4,0,0"/>
    </Expander>
  </Grid>
</Window>
'@
# ---------------------------------------------------------------- Check.ps1
function Invoke-TKCheck {
    <# Controle de securite du poste. Renvoie @{ Machine; Results; Sections } #>
    $results  = New-Object System.Collections.Generic.List[object]
    $sections = [ordered]@{}
    function Add-R([string]$cat, [string]$label, [string]$state, [string]$detail) {
        $results.Add([pscustomobject]@{ Etat = $state; Categorie = $cat; Controle = $label; Detail = $detail })
    }

    Set-TKStatus 'Contrôle : protection'
    # --- Antivirus ---
    try {
        $av = @(Get-CimInstance -Namespace root\SecurityCenter2 -ClassName AntiVirusProduct -ErrorAction Stop)
        $sections['Antivirus déclarés'] = $av | Select-Object displayName, pathToSignedProductExe, productState
        Add-R 'Protection' 'Antivirus déclarés' 'INFO' (($av.displayName) -join ', ')
    } catch {}
    try {
        $mp = Get-MpComputerStatus -ErrorAction Stop
        $age = (New-TimeSpan $mp.AntivirusSignatureLastUpdated (Get-Date)).Days
        if ($mp.RealTimeProtectionEnabled) {
            Add-R 'Protection' 'Defender temps réel' $(if ($age -gt 3) { 'WARN' } else { 'OK' }) "actif, signatures de $age j"
        } else {
            Add-R 'Protection' 'Defender temps réel' 'WARN' 'inactif (normal si un antivirus tiers est actif)'
        }
        if ($mp.IsTamperProtected -eq $false -and $mp.RealTimeProtectionEnabled) { Add-R 'Protection' 'Protection anti-falsification' 'WARN' 'désactivée' }
        $det = @(Get-MpThreatDetection -ErrorAction SilentlyContinue)
        if ($det.Count) {
            $sections['Détections Defender'] = $det | Select-Object InitialDetectionTime, ThreatID, ActionSuccess, @{n = 'Ressources'; e = { $_.Resources -join '; ' } }
            Add-R 'Protection' 'Détections Defender' 'WARN' "$($det.Count) détection(s) dans l'historique"
        } else { Add-R 'Protection' 'Détections Defender' 'OK' 'aucune' }
    } catch { Add-R 'Protection' 'Defender' 'INFO' 'non disponible' }

    $fw = Get-NetFirewallProfile
    $off = @($fw | Where-Object { -not $_.Enabled } | ForEach-Object { $_.Name })
    if ($off.Count) { Add-R 'Protection' 'Pare-feu' 'KO' ('désactivé : ' + ($off -join ', ')) } else { Add-R 'Protection' 'Pare-feu' 'OK' 'actif sur tous les profils' }

    try {
        $bl = Get-BitLockerVolume -MountPoint $env:SystemDrive -ErrorAction Stop
        if ($bl.ProtectionStatus -eq 'On') { Add-R 'Protection' 'BitLocker (système)' 'OK' "chiffré ($($bl.EncryptionMethod))" }
        else { Add-R 'Protection' 'BitLocker (système)' 'WARN' 'non protégé' }
    } catch { Add-R 'Protection' 'BitLocker' 'INFO' 'non disponible (édition Famille ?)' }

    try {
        if (Confirm-SecureBootUEFI -ErrorAction Stop) { Add-R 'Protection' 'Secure Boot' 'OK' 'actif' } else { Add-R 'Protection' 'Secure Boot' 'WARN' 'désactivé' }
    } catch { Add-R 'Protection' 'Secure Boot' 'INFO' 'BIOS legacy ou non supporté' }

    $smb1 = try { (Get-SmbServerConfiguration -ErrorAction Stop).EnableSMB1Protocol } catch { $null }
    if ($smb1 -eq $true) { Add-R 'Protection' 'SMBv1' 'KO' 'activé' } elseif ($smb1 -eq $false) { Add-R 'Protection' 'SMBv1' 'OK' 'désactivé' }

    Set-TKStatus 'Contrôle : mises à jour'
    # --- Mises a jour ---
    $hf = @(Get-HotFix -ErrorAction SilentlyContinue | Where-Object InstalledOn | Sort-Object InstalledOn -Descending)
    $sections['Correctifs installés'] = $hf | Select-Object -First 20 HotFixID, Description, InstalledOn
    if ($hf.Count) {
        $d = (New-TimeSpan $hf[0].InstalledOn (Get-Date)).Days
        Add-R 'Mises à jour' 'Dernier correctif' $(if ($d -gt 60) { 'KO' } elseif ($d -gt 35) { 'WARN' } else { 'OK' }) "il y a $d j ($($hf[0].HotFixID))"
    }
    $pending = (Test-Path 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\WindowsUpdate\Auto Update\RebootRequired') -or
               (Test-Path 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Component Based Servicing\RebootPending')
    if ($pending) { Add-R 'Mises à jour' 'Redémarrage en attente' 'WARN' 'oui' }

    Set-TKStatus 'Contrôle : comptes'
    # --- Comptes ---
    $users = @(Get-LocalUser | Select-Object Name, Enabled, LastLogon, PasswordLastSet, PasswordRequired)
    $sections['Comptes locaux'] = $users
    $admins = try { @(Get-LocalGroupMember -SID 'S-1-5-32-544' -ErrorAction Stop | Select-Object Name, ObjectClass, PrincipalSource) } catch { @() }
    $sections['Administrateurs locaux'] = $admins
    Add-R 'Comptes' 'Administrateurs locaux' $(if ($admins.Count -gt 3) { 'WARN' } else { 'INFO' }) (($admins.Name) -join ', ')
    $builtin = Get-LocalUser | Where-Object { $_.SID -like 'S-1-5-*-500' }
    if ($builtin.Enabled) { Add-R 'Comptes' 'Compte Administrateur intégré' 'WARN' "activé ($($builtin.Name))" }
    $nopwd = @($users | Where-Object { $_.Enabled -and -not $_.PasswordRequired })
    if ($nopwd.Count) { Add-R 'Comptes' 'Comptes sans mot de passe requis' 'WARN' (($nopwd.Name) -join ', ') }

    Set-TKStatus 'Contrôle : persistance'
    # --- Persistance ---
    $run = foreach ($k in 'HKLM:\Software\Microsoft\Windows\CurrentVersion\Run', 'HKLM:\Software\Microsoft\Windows\CurrentVersion\RunOnce',
                          'HKLM:\Software\WOW6432Node\Microsoft\Windows\CurrentVersion\Run', 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Run',
                          'HKCU:\Software\Microsoft\Windows\CurrentVersion\RunOnce') {
        if (Test-Path $k) {
            (Get-ItemProperty $k).PSObject.Properties | Where-Object { $_.Name -notlike 'PS*' } |
                ForEach-Object { [pscustomobject]@{ Cle = $k; Nom = $_.Name; Commande = "$($_.Value)" } }
        }
    }
    $run = @($run)
    $sections['Clés Run'] = $run
    $suspRx = 'AppData|\\Temp\\|ProgramData|\\Users\\Public|powershell|mshta|wscript|cscript|rundll32|regsvr32|\.vbs|\.js\b|\.hta|-enc'
    $suspRun = @($run | Where-Object { $_.Commande -match $suspRx })
    Add-R 'Persistance' 'Clés Run' $(if ($suspRun.Count) { 'WARN' } else { 'OK' }) ("$($run.Count) entrée(s)" + $(if ($suspRun.Count) { ", $($suspRun.Count) à vérifier" } else { '' }))

    $tasks = @(Get-ScheduledTask | Where-Object { $_.TaskPath -notlike '\Microsoft\*' } |
        Select-Object TaskName, TaskPath, State, @{n = 'Action'; e = { (@($_.Actions) | ForEach-Object { "$($_.Execute) $($_.Arguments)" }) -join ' | ' } })
    $sections['Tâches planifiées (hors Microsoft)'] = $tasks
    $suspTask = @($tasks | Where-Object { $_.Action -match $suspRx })
    Add-R 'Persistance' 'Tâches planifiées' $(if ($suspTask.Count) { 'WARN' } else { 'OK' }) ("$($tasks.Count) hors Microsoft" + $(if ($suspTask.Count) { ", $($suspTask.Count) à vérifier" } else { '' }))

    $svc = @(Get-CimInstance Win32_Service | Where-Object { $_.PathName -match 'AppData|\\Temp\\|\\Users\\|ProgramData' } | Select-Object Name, State, StartMode, PathName)
    $sections['Services lancés depuis un emplacement suspect'] = $svc
    Add-R 'Persistance' 'Services' $(if ($svc.Count) { 'WARN' } else { 'OK' }) $(if ($svc.Count) { "$($svc.Count) depuis un profil/Temp/ProgramData" } else { 'aucun chemin suspect' })

    $wmi = @(Get-CimInstance -Namespace root\subscription -ClassName __FilterToConsumerBinding -ErrorAction SilentlyContinue)
    if ($wmi.Count) { $sections['Abonnements WMI'] = $wmi | Select-Object Filter, Consumer }
    Add-R 'Persistance' 'Abonnements WMI' $(if ($wmi.Count) { 'WARN' } else { 'OK' }) $(if ($wmi.Count) { "$($wmi.Count) trouvé(s)" } else { 'aucun' })

    $rmmRx = 'AnyDesk|TeamViewer|ScreenConnect|ConnectWise|RustDesk|Atera|NetSupport|Splashtop|LogMeIn|UltraViewer|Supremo|Remote Utilities|SimpleHelp|Zoho Assist|Action1|Level\.io|TacticalRMM|MeshAgent'
    $apps = @(Get-ItemProperty 'HKLM:\Software\Microsoft\Windows\CurrentVersion\Uninstall\*',
                               'HKLM:\Software\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\*',
                               'HKCU:\Software\Microsoft\Windows\CurrentVersion\Uninstall\*' -ErrorAction SilentlyContinue |
              Where-Object DisplayName | Select-Object DisplayName, DisplayVersion, Publisher, InstallDate | Sort-Object InstallDate -Descending)
    $sections['Logiciels installés'] = $apps
    $rmm = @($apps | Where-Object { $_.DisplayName -match $rmmRx })
    $rmmProc = @(Get-Process -ErrorAction SilentlyContinue | Where-Object { $_.ProcessName -match $rmmRx } | Select-Object -ExpandProperty ProcessName -Unique)
    $rmmAll = @($rmm.DisplayName) + $rmmProc | Select-Object -Unique
    Add-R 'Persistance' 'Prise en main à distance' $(if ($rmmAll.Count) { 'WARN' } else { 'OK' }) $(if ($rmmAll.Count) { ($rmmAll -join ', ') + ' : légitime ?' } else { 'aucun outil connu' })
    $recent = @($apps | Where-Object { $_.InstallDate -and $_.InstallDate -ge (Get-Date).AddDays(-14).ToString('yyyyMMdd') })
    if ($recent.Count) { Add-R 'Persistance' 'Logiciels installés < 14 j' 'INFO' (($recent | Select-Object -First 6).DisplayName -join ', ') }

    Set-TKStatus 'Contrôle : réseau'
    # --- Reseau ---
    $conn = @(Get-NetTCPConnection -State Established -ErrorAction SilentlyContinue |
        Where-Object { $_.RemoteAddress -notmatch '^(127\.|::1$|0\.0\.0\.0)' } |
        Select-Object RemoteAddress, RemotePort, OwningProcess,
            @{n = 'Processus'; e = { $p = Get-Process -Id $_.OwningProcess -ErrorAction SilentlyContinue; if ($p.Path) { $p.Path } else { $p.ProcessName } } })
    $sections['Connexions établies'] = $conn
    Add-R 'Réseau' 'Connexions établies' 'INFO' "$($conn.Count) (détail dans le rapport)"

    $proxy = (Get-ItemProperty 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Internet Settings' -ErrorAction SilentlyContinue)
    if ($proxy.ProxyEnable -eq 1 -and $proxy.ProxyServer) { Add-R 'Réseau' 'Proxy utilisateur' 'WARN' $proxy.ProxyServer }
    elseif ($proxy.AutoConfigURL) { Add-R 'Réseau' 'Script de proxy (PAC)' 'WARN' $proxy.AutoConfigURL }
    else { Add-R 'Réseau' 'Proxy utilisateur' 'OK' 'aucun' }
    $winhttp = (& netsh.exe winhttp show proxy) -join ' '
    if ($winhttp -match 'Proxy Server\(s\)\s*:\s*(\S+)|Serveur\(s\) proxy\s*:\s*(\S+)') { Add-R 'Réseau' 'Proxy WinHTTP' 'WARN' ($Matches[1] + $Matches[2]) }

    $hostsFile = "$env:SystemRoot\System32\drivers\etc\hosts"
    $hosts = @(Get-Content $hostsFile -ErrorAction SilentlyContinue | Where-Object { $_ -and $_ -notmatch '^\s*#' })
    if ($hosts.Count) { $sections['Fichier hosts'] = $hosts | ForEach-Object { [pscustomobject]@{ Entree = $_ } } }
    Add-R 'Réseau' 'Fichier hosts' $(if ($hosts.Count) { 'WARN' } else { 'OK' }) $(if ($hosts.Count) { "$($hosts.Count) entrée(s) active(s)" } else { 'vierge' })

    $dns = @(Get-DnsClientServerAddress -AddressFamily IPv4 -ErrorAction SilentlyContinue | Where-Object ServerAddresses |
             Select-Object InterfaceAlias, @{n = 'Serveurs'; e = { $_.ServerAddresses -join ', ' } })
    $sections['Serveurs DNS'] = $dns
    Add-R 'Réseau' 'Serveurs DNS' 'INFO' ((@($dns.Serveurs) | Select-Object -Unique) -join ' / ')

    $llmnr = (Get-ItemProperty 'HKLM:\SOFTWARE\Policies\Microsoft\Windows NT\DNSClient' -ErrorAction SilentlyContinue).EnableMulticast
    Add-R 'Réseau' 'LLMNR' $(if ($llmnr -eq 0) { 'OK' } else { 'WARN' }) $(if ($llmnr -eq 0) { 'désactivé' } else { 'actif (empoisonnement possible)' })

    Set-TKStatus 'Contrôle : stockage'
    # --- Stockage ---
    $vols = @(Get-Volume -ErrorAction SilentlyContinue | Where-Object { $_.DriveLetter -and $_.DriveType -eq 'Fixed' -and $_.Size -gt 0 })
    foreach ($v in $vols) {
        $pct = [math]::Round($v.SizeRemaining / $v.Size * 100)
        Add-R 'Stockage' "Espace libre $($v.DriveLetter):" $(if ($pct -lt 10) { 'KO' } elseif ($pct -lt 20) { 'WARN' } else { 'OK' }) ("{0} % ({1:N1} Go)" -f $pct, ($v.SizeRemaining / 1GB))
    }
    try {
        $disks = @(Get-PhysicalDisk -ErrorAction Stop | Select-Object FriendlyName, MediaType, HealthStatus, OperationalStatus)
        $sections['Disques physiques'] = $disks
        $bad = @($disks | Where-Object { $_.HealthStatus -ne 'Healthy' })
        Add-R 'Stockage' 'Santé des disques' $(if ($bad.Count) { 'KO' } else { 'OK' }) $(if ($bad.Count) { (($bad.FriendlyName) -join ', ') + ' : ' + $bad[0].HealthStatus } else { 'tous sains' })
    } catch {}

    [pscustomobject]@{
        Machine  = Get-TKMachineInfo
        Date     = Get-Date
        Results  = $results.ToArray()
        Sections = $sections
    }
}

function Export-TKReport {
    <# Rapport HTML autonome a partir du resultat de Invoke-TKCheck #>
    param([Parameter(Mandatory)]$Check, [string]$Folder = (Get-TKCollectePath))
    $m = $Check.Machine
    $enc = { param($s) [System.Net.WebUtility]::HtmlEncode("$s") }
    $count = @{}; foreach ($s in 'KO', 'WARN', 'OK', 'INFO') { $count[$s] = @($Check.Results | Where-Object Etat -eq $s).Count }

    $rows = ($Check.Results | ForEach-Object {
        "<tr class='$($_.Etat.ToLower())'><td><span class='badge $($_.Etat.ToLower())'>$($_.Etat)</span></td><td>$(& $enc $_.Categorie)</td><td>$(& $enc $_.Controle)</td><td>$(& $enc $_.Detail)</td></tr>"
    }) -join "`n"

    $details = foreach ($k in $Check.Sections.Keys) {
        $data = @($Check.Sections[$k])
        if (-not $data.Count) { continue }
        $frag = $data | ConvertTo-Html -Fragment | Out-String
        "<details><summary>$(& $enc $k) <small>($($data.Count))</small></summary>$frag</details>"
    }

    $css = @'
body{font-family:Segoe UI,Arial,sans-serif;background:#0d1117;color:#c9d1d9;margin:0;padding:32px}
h1{color:#e6edf3;margin:0 0 4px}h2{color:#58a6ff;margin-top:32px}.sub{color:#8b949e}
.cards{display:flex;gap:12px;margin:24px 0}.card{flex:1;background:#161b22;border:1px solid #30363d;border-radius:8px;padding:14px}
.card b{display:block;font-size:28px}.card.ko b{color:#f85149}.card.warn b{color:#d29922}.card.ok b{color:#3fb950}.card.info b{color:#8b949e}
table{border-collapse:collapse;width:100%;font-size:13px}th,td{border-bottom:1px solid #30363d;padding:6px 8px;text-align:left;vertical-align:top}
th{color:#8b949e;font-weight:600}.badge{padding:2px 8px;border-radius:10px;font-size:11px;font-weight:700}
.badge.ko{background:#f8514933;color:#f85149}.badge.warn{background:#d2992233;color:#d29922}.badge.ok{background:#3fb95033;color:#3fb950}.badge.info{background:#8b949e33;color:#8b949e}
details{background:#161b22;border:1px solid #30363d;border-radius:8px;margin:8px 0;padding:8px 12px}summary{cursor:pointer;font-weight:600}
.meta td{border:none;padding:2px 16px 2px 0}@media print{body{background:#fff;color:#000}details{border-color:#ccc}}
'@
    $html = @"
<!DOCTYPE html><html lang="fr"><head><meta charset="utf-8"><title>Contrôle $(& $enc $m.Nom)</title><style>$css</style></head><body>
<h1>Rapport de contrôle : $(& $enc $m.Nom)</h1><div class="sub">Tech Toolkit $($sync.Version) - $($Check.Date.ToString('dd/MM/yyyy HH:mm'))</div>
<table class="meta"><tr><td>Système</td><td>$(& $enc $m.OS) $(& $enc $m.Version)</td></tr><tr><td>Modèle</td><td>$(& $enc $m.Modele)</td></tr>
<tr><td>Domaine</td><td>$(& $enc $m.Domaine)</td></tr><tr><td>IP</td><td>$(& $enc $m.IP)</td></tr><tr><td>Exécuté par</td><td>$(& $enc $m.Utilisateur)</td></tr></table>
<div class="cards"><div class="card ko"><b>$($count.KO)</b>Critique</div><div class="card warn"><b>$($count.WARN)</b>À vérifier</div><div class="card ok"><b>$($count.OK)</b>Conforme</div><div class="card info"><b>$($count.INFO)</b>Info</div></div>
<h2>Synthèse</h2><table><tr><th>État</th><th>Catégorie</th><th>Contrôle</th><th>Détail</th></tr>$rows</table>
<h2>Détails</h2>$($details -join "`n")
</body></html>
"@
    $file = Join-Path $Folder ("Controle_{0}_{1}.html" -f $m.Nom, $Check.Date.ToString('yyyyMMdd-HHmm'))
    [IO.File]::WriteAllText($file, $html, (New-Object System.Text.UTF8Encoding $true))
    Write-TKLog "Rapport enregistré : $file" 'OK'
    return $file
}
# ---------------------------------------------------------------- Cleanup.ps1
function Invoke-TKCleanupBatch {
    <# Execute en tache de fond une liste d'actions de config/cleanup.json #>
    param([string[]]$Ids)
    $i = 0
    foreach ($id in $Ids) {
        $i++
        $a = $sync.configs.cleanup | Where-Object { $_.id -eq $id } | Select-Object -First 1
        if (-not $a) { continue }
        Set-TKStatus ("Action {0}/{1} : {2}" -f $i, $Ids.Count, $a.name)
        Write-TKLog "Début : $($a.name)" 'INFO'
        try { & ([scriptblock]::Create($a.script)) | Out-Null }
        catch { Write-TKLog "$($a.name) : $($_.Exception.Message)" 'ERR' }
    }
    Write-TKLog 'Actions terminées.' 'OK'
}

function Get-TKPortableTools {
    <# Catalogue tools.json de la cle (mode USB) #>
    if ($sync.Mode -ne 'USB') { return @() }
    try {
        $list = Get-Content -LiteralPath (Join-Path $sync.Root 'tools.json') -Raw -Encoding UTF8 | ConvertFrom-Json
        foreach ($t in $list) {
            $full = Join-Path $sync.Root $t.path
            $t | Add-Member -NotePropertyName FullPath -NotePropertyValue $full -Force
            $t | Add-Member -NotePropertyName Present -NotePropertyValue (Test-Path -LiteralPath $full) -Force
            $t | Add-Member -NotePropertyName Display -NotePropertyValue ('{0}  -  {1}' -f $t.name, $t.desc) -Force
        }
        return @($list)
    } catch {
        Write-TKLog "tools.json illisible : $($_.Exception.Message)" 'ERR'
        return @()
    }
}

function Start-TKPortableTool {
    param([Parameter(Mandatory)]$Tool)
    if (-not $Tool.Present) { Write-TKLog "Absent de la clé : $($Tool.path)" 'WARN'; return }
    $wd = Split-Path -LiteralPath $Tool.FullPath
    $a = if ($Tool.args) { $Tool.args.Replace('{ROOT}', $sync.Root).Replace('{COLLECTE}', (Get-TKCollectePath)) } else { $null }
    try {
        switch ($Tool.type) {
            'script'  { Start-Process powershell.exe -WorkingDirectory $wd -ArgumentList "-NoProfile -ExecutionPolicy Bypass -NoExit -File `"$($Tool.FullPath)`" $a" }
            'console' { Start-Process cmd.exe -WorkingDirectory $wd -ArgumentList "/k `"`"$($Tool.FullPath)`" $a`"" }
            default   { if ($a) { Start-Process -FilePath $Tool.FullPath -WorkingDirectory $wd -ArgumentList $a } else { Start-Process -FilePath $Tool.FullPath -WorkingDirectory $wd } }
        }
        Write-TKLog "Lancé : $($Tool.name)" 'OK'
    } catch { Write-TKLog "$($Tool.name) : $($_.Exception.Message)" 'ERR' }
}
# ---------------------------------------------------------------- Core.ps1
function Write-TKLog {
    <# Journal : fichier + file d'attente lue par l'interface (thread-safe, utilisable en tache de fond) #>
    param(
        [Parameter(Mandatory)][string]$Message,
        [ValidateSet('INFO', 'OK', 'WARN', 'ERR')][string]$Level = 'INFO'
    )
    $line = '{0} [{1,-4}] {2}' -f (Get-Date -Format 'HH:mm:ss'), $Level, $Message
    try { Add-Content -LiteralPath $sync.LogFile -Value $line -Encoding UTF8 } catch {}
    $sync.LogQueue.Enqueue($line)
}

function Set-TKStatus {
    param([string]$Text)
    $sync.Status = $Text
}

function Get-TKCollectePath {
    <# Dossier de sortie : Collecte\ sur la partition Ventoy de la cle (mode USB), sinon ProgramData #>
    if ($sync.Mode -eq 'USB') {
        try {
            $letter = (Split-Path $sync.Root -Qualifier).TrimEnd(':')
            $disk = (Get-Partition -DriveLetter $letter -ErrorAction Stop).DiskNumber
            $v = Get-Partition -DiskNumber $disk | Get-Volume -ErrorAction SilentlyContinue |
                 Where-Object { $_.FileSystemLabel -eq 'Ventoy' -and $_.DriveLetter } | Select-Object -First 1
            if ($v) {
                $p = "$($v.DriveLetter):\Collecte"
                New-Item -ItemType Directory -Path $p -Force | Out-Null
                return $p
            }
        } catch {}
    }
    $p = Join-Path $sync.DataDir 'Rapports'
    New-Item -ItemType Directory -Path $p -Force | Out-Null
    return $p
}

function Get-TKMachineInfo {
    $os = Get-CimInstance Win32_OperatingSystem
    $cs = Get-CimInstance Win32_ComputerSystem
    $ip = (Get-NetIPAddress -AddressFamily IPv4 -ErrorAction SilentlyContinue |
           Where-Object { $_.IPAddress -notlike '127.*' -and $_.IPAddress -notlike '169.254.*' } |
           Select-Object -ExpandProperty IPAddress) -join ', '
    $disp = (Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion' -ErrorAction SilentlyContinue).DisplayVersion
    [pscustomobject]@{
        Nom      = $env:COMPUTERNAME
        OS       = $os.Caption
        Version  = ('{0} (build {1})' -f $disp, $os.BuildNumber).Trim()
        Build    = [int]$os.BuildNumber
        Domaine  = if ($cs.PartOfDomain) { $cs.Domain } else { "WORKGROUP ($($cs.Workgroup))" }
        Modele   = ('{0} {1}' -f $cs.Manufacturer, $cs.Model).Trim()
        IP       = $ip
        Uptime   = '{0:%d}j {0:hh}h{0:mm}' -f ((Get-Date) - $os.LastBootUpTime)
        Utilisateur = "$env:USERDOMAIN\$env:USERNAME"
    }
}

function Initialize-TKRunspacePool {
    <# Pool de runspaces avec toutes les fonctions *-TK* et la variable $sync #>
    $iss = [System.Management.Automation.Runspaces.InitialSessionState]::CreateDefault()
    $iss.Variables.Add((New-Object System.Management.Automation.Runspaces.SessionStateVariableEntry -ArgumentList 'sync', $sync, $null))
    Get-ChildItem function: | Where-Object { $_.Name -like '*-TK*' } | ForEach-Object {
        $iss.Commands.Add((New-Object System.Management.Automation.Runspaces.SessionStateFunctionEntry -ArgumentList $_.Name, $_.Definition))
    }
    $pool = [runspacefactory]::CreateRunspacePool(1, 2, $iss, $Host)
    $pool.Open()
    $sync.RunspacePool = $pool
}

function Start-TKJob {
    <# Lance un bloc en tache de fond. OnDone (scriptblock) est execute sur le thread UI a la fin. #>
    param(
        [Parameter(Mandatory)][string]$Name,
        [Parameter(Mandatory)][scriptblock]$ScriptBlock,
        [hashtable]$Arguments = @{},
        [scriptblock]$OnDone
    )
    if ($sync.Busy) {
        Write-TKLog "Une tache est deja en cours ($($sync.BusyName)). Patiente." 'WARN'
        return
    }
    $sync.Busy = $true
    $sync.BusyName = $Name
    Set-TKStatus "$Name..."
    if ($OnDone) { $sync.OnDone[$Name] = $OnDone }

    $ps = [powershell]::Create()
    $ps.RunspacePool = $sync.RunspacePool
    [void]$ps.AddScript($ScriptBlock.ToString())
    foreach ($k in $Arguments.Keys) { [void]$ps.AddParameter($k, $Arguments[$k]) }
    $handle = $ps.BeginInvoke()
    [void]$sync.Jobs.Add([pscustomobject]@{ Name = $Name; PS = $ps; Handle = $handle })
}

function Update-TKJobs {
    <# Appele par le timer UI : termine les taches finies, remonte les erreurs, lance OnDone #>
    foreach ($job in @($sync.Jobs)) {
        if (-not $job.Handle.IsCompleted) { continue }
        $result = $null
        try { $result = $job.PS.EndInvoke($job.Handle) }
        catch { Write-TKLog "$($job.Name) : $($_.Exception.InnerException.Message)" 'ERR' }
        foreach ($e in $job.PS.Streams.Error) { Write-TKLog "$($job.Name) : $($e.ToString())" 'ERR' }
        $job.PS.Dispose()
        $sync.Jobs.Remove($job)
        $sync.Busy = $false
        Set-TKStatus 'Pret'
        if ($sync.OnDone.ContainsKey($job.Name)) {
            $cb = $sync.OnDone[$job.Name]
            $sync.OnDone.Remove($job.Name)
            try { & $cb $result } catch { Write-TKLog "Mise a jour de l'interface : $($_.Exception.Message)" 'ERR' }
        }
    }
}

function New-TKRestorePoint {
    $key = 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\SystemRestore'
    $old = (Get-ItemProperty -Path $key -Name SystemRestorePointCreationFrequency -ErrorAction SilentlyContinue).SystemRestorePointCreationFrequency
    try {
        Enable-ComputerRestore -Drive "$env:SystemDrive\" -ErrorAction Stop
        Set-ItemProperty -Path $key -Name SystemRestorePointCreationFrequency -Value 0 -Type DWord
        Checkpoint-Computer -Description ("Tech Toolkit {0}" -f (Get-Date -Format 'yyyy-MM-dd HH:mm')) -RestorePointType MODIFY_SETTINGS -ErrorAction Stop
        Write-TKLog 'Point de restauration cree.' 'OK'
    } catch {
        Write-TKLog "Point de restauration impossible : $($_.Exception.Message)" 'WARN'
    } finally {
        if ($null -ne $old) { Set-ItemProperty -Path $key -Name SystemRestorePointCreationFrequency -Value $old -Type DWord }
        else { Remove-ItemProperty -Path $key -Name SystemRestorePointCreationFrequency -ErrorAction SilentlyContinue }
    }
}
# ---------------------------------------------------------------- Tweaks.ps1
function Get-TKState {
    <# Sauvegarde des valeurs d'origine (avant 1re application) par tweak #>
    $h = @{}
    if (Test-Path -LiteralPath $sync.StateFile) {
        try {
            $obj = Get-Content -LiteralPath $sync.StateFile -Raw -Encoding UTF8 | ConvertFrom-Json
            foreach ($p in $obj.PSObject.Properties) { $h[$p.Name] = $p.Value }
        } catch { Write-TKLog "state.json illisible, il sera recréé : $($_.Exception.Message)" 'WARN' }
    }
    return $h
}

function Save-TKState {
    param([hashtable]$State)
    $State | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath $sync.StateFile -Encoding UTF8
}

function Get-TKRegistryValue {
    <# Renvoie @{ Value; Kind } ou Value = '<RemoveEntry>' si absente #>
    param([string]$Path, [string]$Name)
    try {
        $key = Get-Item -LiteralPath $Path -ErrorAction Stop
        if ($key.GetValueNames() -contains $Name) {
            return @{ Value = $key.GetValue($Name, $null, 'DoNotExpandEnvironmentNames'); Kind = $key.GetValueKind($Name).ToString() }
        }
    } catch {}
    return @{ Value = '<RemoveEntry>'; Kind = $null }
}

function Set-TKRegistryValue {
    param([string]$Path, [string]$Name, [string]$Type, $Value)
    if ("$Value" -eq '<RemoveEntry>') {
        if (Test-Path -LiteralPath $Path) { Remove-ItemProperty -LiteralPath $Path -Name $Name -ErrorAction SilentlyContinue }
        return
    }
    if (-not (Test-Path -LiteralPath $Path)) { New-Item -Path $Path -Force | Out-Null }
    $v = switch ($Type) {
        'DWord'       { [int][int64]"$Value" }
        'QWord'       { [int64]"$Value" }
        'MultiString' { [string[]]@($Value) }
        default       { "$Value" }
    }
    New-ItemProperty -LiteralPath $Path -Name $Name -PropertyType $Type -Value $v -Force | Out-Null
}

function Set-TKServiceStartup {
    param([string]$Name, [string]$Startup)
    $svc = Get-Service -Name $Name -ErrorAction SilentlyContinue
    if (-not $svc) { Write-TKLog "Service $Name absent, ignoré." 'INFO'; return }
    if ($Startup -eq 'AutomaticDelayedStart') { & sc.exe config $Name start= delayed-auto | Out-Null }
    else { Set-Service -Name $Name -StartupType $Startup -ErrorAction SilentlyContinue }
    if ($Startup -eq 'Disabled' -and $svc.Status -eq 'Running') { Stop-Service -Name $Name -Force -ErrorAction SilentlyContinue }
}

function Get-TKTweak {
    param([string]$Id)
    $sync.configs.tweaks | Where-Object { $_.id -eq $Id } | Select-Object -First 1
}

function Test-TKTweak {
    <# Applied / Partial / NotApplied / Unknown #>
    param([Parameter(Mandatory)]$Tweak)
    $checks = New-Object System.Collections.Generic.List[bool]
    foreach ($r in @($Tweak.registry)) {
        if (-not $r) { continue }
        $cur = Get-TKRegistryValue -Path $r.path -Name $r.name
        $checks.Add(("$($cur.Value)" -eq "$($r.value)"))
    }
    foreach ($s in @($Tweak.services)) {
        if (-not $s) { continue }
        $svc = Get-Service -Name $s.name -ErrorAction SilentlyContinue
        if ($svc) { $checks.Add(("$($svc.StartType)" -eq "$($s.startup)")) }
    }
    if ($Tweak.test) {
        try { $checks.Add([bool](& ([scriptblock]::Create($Tweak.test)))) } catch { $checks.Add($false) }
    }
    if ($checks.Count -eq 0) { return 'Unknown' }
    $ok = @($checks | Where-Object { $_ }).Count
    if ($ok -eq $checks.Count) { 'Applied' } elseif ($ok -gt 0) { 'Partial' } else { 'NotApplied' }
}

function Invoke-TKTweak {
    param(
        [Parameter(Mandatory)]$Tweak,
        [ValidateSet('Apply', 'Undo')][string]$Mode = 'Apply'
    )
    $state  = Get-TKState
    $backup = $state[$Tweak.id]

    if ($Mode -eq 'Apply') {
        $newBackup = @{ registry = @(); services = @() }
        foreach ($r in @($Tweak.registry)) {
            if (-not $r) { continue }
            $cur = Get-TKRegistryValue -Path $r.path -Name $r.name
            $newBackup.registry += @{ path = $r.path; name = $r.name; type = $(if ($cur.Kind) { $cur.Kind } else { $r.type }); value = $cur.Value }
            Set-TKRegistryValue -Path $r.path -Name $r.name -Type $r.type -Value $r.value
        }
        foreach ($s in @($Tweak.services)) {
            if (-not $s) { continue }
            $svc = Get-Service -Name $s.name -ErrorAction SilentlyContinue
            if ($svc) { $newBackup.services += @{ name = $s.name; startup = "$($svc.StartType)" } }
            Set-TKServiceStartup -Name $s.name -Startup $s.startup
        }
        if ($Tweak.invoke) { & ([scriptblock]::Create($Tweak.invoke)) | Out-Null }
        # On ne garde que l'etat d'origine : une re-application n'ecrase pas la sauvegarde
        if (-not $backup) { $state[$Tweak.id] = $newBackup; Save-TKState $state }
        Write-TKLog "Appliqué : $($Tweak.name)" 'OK'
    }
    else {
        if ($Tweak.undo) { & ([scriptblock]::Create($Tweak.undo)) | Out-Null }
        foreach ($r in @($Tweak.registry)) {
            if (-not $r) { continue }
            $b = @($backup.registry) | Where-Object { $_.path -eq $r.path -and $_.name -eq $r.name } | Select-Object -First 1
            if ($b) { Set-TKRegistryValue -Path $b.path -Name $b.name -Type $b.type -Value $b.value }
            else    { Set-TKRegistryValue -Path $r.path -Name $r.name -Type $r.type -Value $r.original }
        }
        foreach ($s in @($Tweak.services)) {
            if (-not $s) { continue }
            $b = @($backup.services) | Where-Object { $_.name -eq $s.name } | Select-Object -First 1
            $target = if ($b) { $b.startup } else { $s.original }
            if ($target) { Set-TKServiceStartup -Name $s.name -Startup $target }
        }
        if ($state.ContainsKey($Tweak.id)) { $state.Remove($Tweak.id); Save-TKState $state }
        $src = if ($backup) { 'valeurs sauvegardées' } else { 'valeurs par défaut Windows' }
        Write-TKLog "Annulé : $($Tweak.name) ($src)" 'OK'
    }
}

function Invoke-TKTweakBatch {
    <# Execute en tache de fond : applique ou annule une liste d'IDs #>
    param([string[]]$Ids, [string]$Mode, [bool]$RestorePoint)
    if ($Mode -eq 'Apply' -and $RestorePoint) { Set-TKStatus 'Point de restauration...'; New-TKRestorePoint }
    $restartExplorer = $false; $reboot = $false
    $i = 0
    foreach ($id in $Ids) {
        $i++
        $t = Get-TKTweak -Id $id
        if (-not $t) { continue }
        Set-TKStatus ("{0} {1}/{2} : {3}" -f $(if ($Mode -eq 'Apply') { 'Application' } else { 'Annulation' }), $i, $Ids.Count, $t.name)
        try {
            Invoke-TKTweak -Tweak $t -Mode $Mode
            if ($t.restartExplorer) { $restartExplorer = $true }
            if ($t.reboot) { $reboot = $true }
        } catch {
            Write-TKLog "$($t.name) : $($_.Exception.Message)" 'ERR'
        }
    }
    if ($restartExplorer) {
        Write-TKLog "Redémarrage de l'Explorateur..." 'INFO'
        Stop-Process -Name explorer -Force -ErrorAction SilentlyContinue
    }
    if ($reboot) { Write-TKLog 'Un redémarrage du poste est nécessaire pour finaliser certains réglages.' 'WARN' }
    return (Get-TKTweakStates)
}

function Get-TKTweakStates {
    $h = @{}
    foreach ($t in $sync.configs.tweaks) {
        try { $h[$t.id] = Test-TKTweak -Tweak $t } catch { $h[$t.id] = 'Unknown' }
    }
    return $h
}
# ---------------------------------------------------------------- main.ps1
################################################################################
#  Interface
################################################################################

# --- Chargement XAML ---
[xml]$xaml = $inputXML
try {
    $sync.Form = [Windows.Markup.XamlReader]::Load((New-Object System.Xml.XmlNodeReader $xaml))
} catch {
    Write-Host "Erreur de chargement de l'interface : $($_.Exception.InnerException.Message)" -ForegroundColor Red
    return
}
$xaml.SelectNodes("//*[@*[local-name()='Name']]") | ForEach-Object {
    $n = $_.Attributes | Where-Object { $_.LocalName -eq 'Name' } | Select-Object -First 1 -ExpandProperty Value
    $sync[$n] = $sync.Form.FindName($n)
}

$bc = New-Object System.Windows.Media.BrushConverter
function New-TKBrush([string]$hex) { $bc.ConvertFromString($hex) }
function New-TKThickness([double]$l, [double]$t, [double]$r, [double]$b) { New-Object System.Windows.Thickness -ArgumentList $l, $t, $r, $b }
function New-TKText([string]$text, [double]$size = 13, [string]$color = '#C9D1D9', [string]$weight = 'Normal') {
    $t = New-Object System.Windows.Controls.TextBlock
    $t.Text = $text; $t.FontSize = $size; $t.Foreground = New-TKBrush $color
    $t.FontWeight = [System.Windows.FontWeights]::$weight
    $t.TextWrapping = 'Wrap'
    return $t
}

# --- En-tete ---
$sync.Machine = Get-TKMachineInfo
$sync.TxtVersion.Text  = "v$($sync.Version)  -  Déploiement, SAV, contrôle, nettoyage"
$sync.TxtMode.Text     = if ($sync.Mode -eq 'USB') { "CLÉ USB  $($sync.Root)" } else { 'WEB' }
$sync.TxtMachine.Text  = "$($sync.Machine.Nom)  |  $($sync.Machine.Domaine)"
$sync.TxtMachine2.Text = "$($sync.Machine.OS) $($sync.Machine.Version)  |  $($sync.Machine.Modele)  |  IP $($sync.Machine.IP)  |  up $($sync.Machine.Uptime)"

# --- Onglet Tweaks : construction dynamique depuis tweaks.json ---
$sync.TweakChecks = @{}
$sync.TweakBadges = @{}
$categories = New-Object System.Collections.Generic.List[string]
foreach ($t in $sync.configs.tweaks) { if (-not $categories.Contains($t.category)) { $categories.Add($t.category) } }

foreach ($cat in $categories) {
    $h = New-TKText $cat.ToUpper() 12 '#58A6FF' 'Bold'
    $h.Margin = New-TKThickness 0 16 0 6
    [void]$sync.TweaksPanel.Children.Add($h)
    foreach ($t in @($sync.configs.tweaks | Where-Object { $_.category -eq $cat })) {
        $row = New-Object System.Windows.Controls.DockPanel
        $row.Margin = New-TKThickness 0 4 0 0
        $badge = New-TKText '' 11 '#8B949E'
        $badge.Width = 110; $badge.TextAlignment = 'Right'; $badge.VerticalAlignment = 'Center'
        [System.Windows.Controls.DockPanel]::SetDock($badge, 'Right')
        [void]$row.Children.Add($badge)
        if ($t.risk -eq 'medium') {
            $warn = New-TKText ("{0} à tester" -f [char]0x26A0) 11 '#D29922'
            $warn.Margin = New-TKThickness 8 0 8 0; $warn.VerticalAlignment = 'Center'
            [System.Windows.Controls.DockPanel]::SetDock($warn, 'Right')
            [void]$row.Children.Add($warn)
        }
        $cb = New-Object System.Windows.Controls.CheckBox
        $cb.Content = $t.name; $cb.Tag = $t.id; $cb.FontWeight = [System.Windows.FontWeights]::SemiBold
        [void]$row.Children.Add($cb)
        $desc = New-TKText $t.description 11.5 '#8B949E'
        $desc.Margin = New-TKThickness 22 0 120 4
        [void]$sync.TweaksPanel.Children.Add($row)
        [void]$sync.TweaksPanel.Children.Add($desc)
        $sync.TweakChecks[$t.id] = $cb
        $sync.TweakBadges[$t.id] = $badge
    }
}

function Update-TKTweakBadges($states) {
    if (-not $states) { return }
    foreach ($id in $sync.TweakBadges.Keys) {
        $b = $sync.TweakBadges[$id]
        switch ($states[$id]) {
            'Applied'    { $b.Text = "{0} appliqué" -f [char]0x25CF;     $b.Foreground = New-TKBrush '#3FB950' }
            'Partial'    { $b.Text = "{0} partiel" -f [char]0x25D0;      $b.Foreground = New-TKBrush '#D29922' }
            'NotApplied' { $b.Text = "{0} non appliqué" -f [char]0x25CB; $b.Foreground = New-TKBrush '#8B949E' }
            default      { $b.Text = '? inconnu';                         $b.Foreground = New-TKBrush '#8B949E' }
        }
    }
}
function Get-TKCheckedTweaks { @($sync.TweakChecks.Values | Where-Object { $_.IsChecked } | ForEach-Object { $_.Tag }) }
function Get-TKLastHashtable($r) { @($r) | Where-Object { $_ -is [hashtable] } | Select-Object -Last 1 }

foreach ($p in $sync.configs.presets) {
    $btn = New-Object System.Windows.Controls.Button
    $btn.Style = $sync.Form.FindResource('Btn')
    $btn.Content = $p.name; $btn.ToolTip = $p.description; $btn.Tag = @($p.tweaks)
    $btn.Add_Click({
        foreach ($id in $sync.TweakChecks.Keys) { $sync.TweakChecks[$id].IsChecked = ($this.Tag -contains $id) }
        Write-TKLog "Profil sélectionné : $($this.Content) ($(@($this.Tag).Count) réglages)" 'INFO'
    })
    [void]$sync.PresetPanel.Children.Add($btn)
}

$tweakDone = { param($r) Update-TKTweakBadges (Get-TKLastHashtable $r) }

$sync.BtnApply.Add_Click({
    $ids = Get-TKCheckedTweaks
    if (-not $ids.Count) { Write-TKLog 'Aucun réglage coché.' 'WARN'; return }
    $risky = @($sync.configs.tweaks | Where-Object { $ids -contains $_.id -and $_.risk -eq 'medium' } | ForEach-Object { " - $($_.name)" })
    if ($risky.Count) {
        $msg = "Ces réglages peuvent gêner de vieux équipements (NAS, copieurs, pilotes) :`n`n$($risky -join "`n")`n`nContinuer ?"
        if ([System.Windows.MessageBox]::Show($msg, 'Tech Toolkit', 'YesNo', 'Warning') -ne 'Yes') { return }
    }
    Start-TKJob -Name 'Application des réglages' -OnDone $tweakDone `
        -ScriptBlock { param($Ids, $RestorePoint) Invoke-TKTweakBatch -Ids $Ids -Mode 'Apply' -RestorePoint $RestorePoint } `
        -Arguments @{ Ids = $ids; RestorePoint = [bool]$sync.ChkRestore.IsChecked }
})

$sync.BtnUndo.Add_Click({
    $ids = Get-TKCheckedTweaks
    if (-not $ids.Count) { Write-TKLog 'Aucun réglage coché.' 'WARN'; return }
    if ([System.Windows.MessageBox]::Show("Annuler $($ids.Count) réglage(s) et restaurer les valeurs d'origine ?", 'Tech Toolkit', 'YesNo', 'Question') -ne 'Yes') { return }
    Start-TKJob -Name 'Annulation des réglages' -OnDone $tweakDone `
        -ScriptBlock { param($Ids) Invoke-TKTweakBatch -Ids $Ids -Mode 'Undo' -RestorePoint $false } `
        -Arguments @{ Ids = $ids }
})

$sync.BtnRefresh.Add_Click({
    Start-TKJob -Name "Lecture de l'état" -OnDone $tweakDone -ScriptBlock { Get-TKTweakStates }
})
$sync.BtnClear.Add_Click({ foreach ($cb in $sync.TweakChecks.Values) { $cb.IsChecked = $false } })

# --- Onglet Controle & nettoyage ---
$sync.BtnCheck.Add_Click({
    Start-TKJob -Name 'Contrôle du poste' -ScriptBlock { Invoke-TKCheck } -OnDone {
        param($r)
        $c = @($r) | Where-Object { $_.Results } | Select-Object -Last 1
        if (-not $c) { Write-TKLog 'Le contrôle n''a rien renvoyé.' 'ERR'; return }
        $sync.LastCheck = $c
        $order = @{ KO = 0; WARN = 1; INFO = 2; OK = 3 }
        $sync.GridCheck.ItemsSource = @($c.Results | Sort-Object { $order[$_.Etat] }, Categorie)
        $n = @{}; foreach ($s in 'KO', 'WARN', 'OK') { $n[$s] = @($c.Results | Where-Object Etat -eq $s).Count }
        $sync.TxtCheckSummary.Text = "$($n.KO) critique(s)  |  $($n.WARN) à vérifier  |  $($n.OK) conforme(s)"
        try {
            $sync.LastReport = Export-TKReport -Check $c
            $sync.BtnReport.IsEnabled = $true
        } catch { Write-TKLog "Rapport HTML : $($_.Exception.Message)" 'ERR' }
        Write-TKLog ("Contrôle terminé : {0} critique(s), {1} à vérifier." -f $n.KO, $n.WARN) $(if ($n.KO) { 'WARN' } else { 'OK' })
    }
})
$sync.BtnReport.Add_Click({ if ($sync.LastReport) { Start-Process $sync.LastReport } })
$sync.BtnFolder.Add_Click({ Start-Process explorer.exe (Get-TKCollectePath) })

$sync.CleanupChecks = @{}
$groups = New-Object System.Collections.Generic.List[string]
foreach ($a in $sync.configs.cleanup) { if (-not $groups.Contains($a.group)) { $groups.Add($a.group) } }
foreach ($g in $groups) {
    $h = New-TKText $g.ToUpper() 11 '#58A6FF' 'Bold'
    $h.Margin = New-TKThickness 0 12 0 4
    [void]$sync.CleanupPanel.Children.Add($h)
    foreach ($a in @($sync.configs.cleanup | Where-Object { $_.group -eq $g })) {
        $cb = New-Object System.Windows.Controls.CheckBox
        $cb.Content = $a.name; $cb.Tag = $a.id; $cb.ToolTip = $a.description
        if ($a.confirm) { $cb.Foreground = New-TKBrush '#F85149' }
        $d = New-TKText $a.description 11 '#8B949E'
        $d.Margin = New-TKThickness 22 0 0 6
        [void]$sync.CleanupPanel.Children.Add($cb)
        [void]$sync.CleanupPanel.Children.Add($d)
        $sync.CleanupChecks[$a.id] = $cb
    }
}

$sync.BtnRunCleanup.Add_Click({
    # On respecte l'ordre du fichier (DISM avant SFC)
    $ids = @($sync.configs.cleanup | Where-Object { $sync.CleanupChecks[$_.id].IsChecked } | ForEach-Object { $_.id })
    if (-not $ids.Count) { Write-TKLog 'Aucune action cochée.' 'WARN'; return }
    $danger = @($sync.configs.cleanup | Where-Object { $ids -contains $_.id -and $_.confirm })
    if ($danger.Count) {
        $msg = "Attention :`n`n" + (($danger | ForEach-Object { "- $($_.name) : $($_.description)" }) -join "`n") + "`n`nContinuer ?"
        if ([System.Windows.MessageBox]::Show($msg, 'Tech Toolkit', 'YesNo', 'Warning') -ne 'Yes') { return }
    }
    Start-TKJob -Name 'Nettoyage et réparation' -ScriptBlock { param($Ids) Invoke-TKCleanupBatch -Ids $Ids } -Arguments @{ Ids = $ids }
})

# --- Onglet Outils de la cle ---
$sync.PortableTools = Get-TKPortableTools
function Update-TKToolList {
    $cat = $sync.CmbToolCat.SelectedItem
    $sync.LstTools.ItemsSource = @($sync.PortableTools | Where-Object { -not $cat -or $cat -eq 'Toutes' -or $_.cat -eq $cat })
}
if ($sync.Mode -eq 'USB' -and $sync.PortableTools.Count) {
    [void]$sync.CmbToolCat.Items.Add('Toutes')
    foreach ($c in @($sync.PortableTools | ForEach-Object { $_.cat } | Select-Object -Unique)) { [void]$sync.CmbToolCat.Items.Add($c) }
    $sync.CmbToolCat.SelectedIndex = 0
    $present = @($sync.PortableTools | Where-Object Present).Count
    $sync.TxtToolsInfo.Text = "$present / $($sync.PortableTools.Count) outils présents sur la clé  -  double-clic pour lancer"
    Update-TKToolList
    $sync.CmbToolCat.Add_SelectionChanged({ Update-TKToolList })
    $launch = { if ($sync.LstTools.SelectedItem) { Start-TKPortableTool -Tool $sync.LstTools.SelectedItem } }
    $sync.BtnLaunchTool.Add_Click($launch)
    $sync.LstTools.Add_MouseDoubleClick($launch)
} else {
    $sync.CmbToolCat.IsEnabled = $false
    $sync.BtnLaunchTool.IsEnabled = $false
    $sync.TxtToolsInfo.Text = 'Disponible quand Tech Toolkit est lancé depuis la clé USB (START.bat sur la partition TOOLS).'
}

# --- Boucle UI : journal, statut, fin des taches ---
$sync.ActionButtons = @($sync.BtnApply, $sync.BtnUndo, $sync.BtnRefresh, $sync.BtnCheck, $sync.BtnRunCleanup)
$timer = New-Object System.Windows.Threading.DispatcherTimer
$timer.Interval = [TimeSpan]::FromMilliseconds(250)
$timer.Add_Tick({
    $line = $null
    $sb = New-Object System.Text.StringBuilder
    while ($sync.LogQueue.TryDequeue([ref]$line)) { [void]$sb.AppendLine($line) }
    if ($sb.Length) { $sync.LogBox.AppendText($sb.ToString()); $sync.LogBox.ScrollToEnd() }
    $sync.TxtStatus.Text = $sync.Status
    $sync.Progress.IsIndeterminate = [bool]$sync.Busy
    $sync.Progress.Visibility = $(if ($sync.Busy) { 'Visible' } else { 'Hidden' })
    foreach ($b in $sync.ActionButtons) { $b.IsEnabled = -not $sync.Busy }
    Update-TKJobs
})

$sync.Form.Add_Loaded({
    $timer.Start()
    Write-TKLog "Tech Toolkit v$($sync.Version) - mode $($sync.Mode) - journal : $($sync.LogFile)" 'INFO'
    Start-TKJob -Name "Lecture de l'état" -OnDone $tweakDone -ScriptBlock { Get-TKTweakStates }
})
$sync.Form.Add_Closing({
    param($s, $e)
    if ($sync.Busy -and [System.Windows.MessageBox]::Show("Une tâche est en cours ($($sync.BusyName)). Quitter quand même ?", 'Tech Toolkit', 'YesNo', 'Warning') -ne 'Yes') {
        $e.Cancel = $true; return
    }
    $timer.Stop()
    try { $sync.RunspacePool.Close() } catch {}
})

# --- Demarrage ---
Initialize-TKRunspacePool
try {
    Add-Type -Namespace TK -Name Win -MemberDefinition '[DllImport("kernel32.dll")] public static extern System.IntPtr GetConsoleWindow(); [DllImport("user32.dll")] public static extern bool ShowWindow(System.IntPtr h, int n);' -ErrorAction Stop
    [void][TK.Win]::ShowWindow([TK.Win]::GetConsoleWindow(), 6)   # console reduite
} catch {}
[void]$sync.Form.ShowDialog()
