#Requires -RunAsAdministrator
<#  Check rapide : état de sécurité du poste + persistance, en moins d'une minute.
    Sortie : <OutRoot>\<PC>-<date>\ (un fichier par contrôle + resume.txt)  #>
param([string]$OutRoot = "$env:PUBLIC\Collecte-Toolkit")

[Console]::OutputEncoding = [Text.Encoding]::UTF8
$out = Join-Path $OutRoot ("{0}-{1}" -f $env:COMPUTERNAME, (Get-Date -Format 'yyyyMMdd-HHmm'))
New-Item -ItemType Directory -Path $out -Force | Out-Null
$resume = [System.Collections.Generic.List[string]]::new()

function Add-Result([string]$label, [string]$state, [string]$detail) {
    $color = @{ OK = 'Green'; WARN = 'Yellow'; KO = 'Red'; INFO = 'Gray' }[$state]
    Write-Host ("  [{0,-4}] {1,-22} {2}" -f $state, $label, $detail) -ForegroundColor $color
    $resume.Add(("[{0}] {1} : {2}" -f $state, $label, $detail))
}
function Save($obj, $name) { $obj | Format-Table -AutoSize | Out-String -Width 400 | Out-File "$out\$name.txt" -Encoding UTF8 }

Write-Host "`n  Check rapide - $env:COMPUTERNAME`n" -ForegroundColor Cyan

# Antivirus (Defender + tiers déclarés dans le Centre de sécurité)
try {
    $mp = Get-MpComputerStatus -ErrorAction Stop
    Save $mp 'defender'
    $age = (New-TimeSpan $mp.AntivirusSignatureLastUpdated (Get-Date)).Days
    if ($mp.RealTimeProtectionEnabled) { Add-Result 'Defender temps réel' 'OK' "signatures de $age j" }
    else { Add-Result 'Defender temps réel' 'WARN' 'désactivé (normal si un AV tiers est actif)' }
} catch { Add-Result 'Defender' 'INFO' 'non disponible' }
try {
    $av = Get-CimInstance -Namespace root\SecurityCenter2 -ClassName AntiVirusProduct -ErrorAction Stop
    Save $av 'antivirus'
    Add-Result 'Antivirus déclarés' 'INFO' (($av.displayName) -join ', ')
} catch {}

# BitLocker
try {
    $bl = Get-BitLockerVolume -ErrorAction Stop
    Save $bl 'bitlocker'
    $sys = $bl | Where-Object MountPoint -eq $env:SystemDrive
    if ($sys.ProtectionStatus -eq 'On') { Add-Result 'BitLocker (système)' 'OK' 'protégé' }
    else { Add-Result 'BitLocker (système)' 'WARN' 'non protégé' }
} catch { Add-Result 'BitLocker' 'INFO' 'non disponible (édition Famille ?)' }

# Pare-feu
$fw = Get-NetFirewallProfile
Save $fw 'firewall'
$off = @($fw | Where-Object { -not $_.Enabled } | Select-Object -ExpandProperty Name)
if ($off.Count -eq 0) { Add-Result 'Pare-feu' 'OK' 'tous profils actifs' }
else { Add-Result 'Pare-feu' 'KO' ("désactivé : " + ($off -join ', ')) }

# Secure Boot
try {
    if (Confirm-SecureBootUEFI -ErrorAction Stop) { Add-Result 'Secure Boot' 'OK' 'actif' }
    else { Add-Result 'Secure Boot' 'WARN' 'désactivé' }
} catch { Add-Result 'Secure Boot' 'INFO' 'BIOS legacy ou non supporté' }

# Patchs
$hf = Get-HotFix | Sort-Object InstalledOn -Descending
Save $hf 'patchs'
$last = ($hf | Select-Object -First 1).InstalledOn
if ($last) {
    $d = (New-TimeSpan $last (Get-Date)).Days
    Add-Result 'Dernier patch' ($(if ($d -gt 45) { 'WARN' } else { 'OK' })) ("il y a $d j")
}

# Comptes
$users = Get-LocalUser | Select-Object Name, Enabled, LastLogon, PasswordLastSet
Save $users 'utilisateurs'
$admins = try { Get-LocalGroupMember -SID 'S-1-5-32-544' -ErrorAction Stop | Select-Object Name, ObjectClass, PrincipalSource } catch { net localgroup administrators | Select-Object -Skip 6 | Where-Object { $_ -and $_ -notmatch 'commande|command' } | ForEach-Object { [pscustomobject]@{ Name = $_ } } }
Save $admins 'administrateurs'
Add-Result 'Administrateurs locaux' 'INFO' (($admins.Name) -join ', ')

# Persistance
$run = foreach ($k in 'HKLM:\Software\Microsoft\Windows\CurrentVersion\Run',
                     'HKLM:\Software\Microsoft\Windows\CurrentVersion\RunOnce',
                     'HKLM:\Software\WOW6432Node\Microsoft\Windows\CurrentVersion\Run',
                     'HKCU:\Software\Microsoft\Windows\CurrentVersion\Run',
                     'HKCU:\Software\Microsoft\Windows\CurrentVersion\RunOnce') {
    if (Test-Path $k) {
        (Get-ItemProperty $k).PSObject.Properties | Where-Object Name -notlike 'PS*' |
            ForEach-Object { [pscustomobject]@{ Cle = $k; Nom = $_.Name; Commande = $_.Value } }
    }
}
Save $run 'run_keys'
$tasks = Get-ScheduledTask | Where-Object { $_.TaskPath -notlike '\Microsoft\*' } |
    Select-Object TaskName, TaskPath, State, @{n = 'Action'; e = { ($_.Actions.Execute, $_.Actions.Arguments) -join ' ' } }
Save $tasks 'taches'
$susp = @($tasks | Where-Object { $_.Action -match 'AppData|\\Temp\\|ProgramData|powershell|mshta|wscript|cscript|rundll32' })
if ($susp.Count) { Add-Result 'Tâches planifiées' 'WARN' "$($susp.Count) à vérifier (voir taches.txt)" }
else { Add-Result 'Tâches planifiées' 'OK' "$(@($tasks).Count) hors Microsoft" }

$svc = Get-CimInstance Win32_Service | Where-Object { $_.PathName -match 'AppData|\\Temp\\|\\Users\\' } |
    Select-Object Name, State, StartMode, PathName
Save $svc 'services_suspects'
if (@($svc).Count) { Add-Result 'Services' 'WARN' "$(@($svc).Count) lancés depuis un profil/Temp" }
else { Add-Result 'Services' 'OK' 'aucun chemin suspect' }

$wmi = Get-CimInstance -Namespace root\subscription -ClassName __FilterToConsumerBinding -ErrorAction SilentlyContinue
if (@($wmi).Count) { Save $wmi 'wmi_persistance'; Add-Result 'Abonnements WMI' 'WARN' "$(@($wmi).Count) trouvés (voir wmi_persistance.txt)" }
else { Add-Result 'Abonnements WMI' 'OK' 'aucun' }

# Outils de prise en main à distance installés
$rmm = 'AnyDesk|TeamViewer|ScreenConnect|ConnectWise|RustDesk|Atera|NetSupport|Splashtop|LogMeIn|UltraViewer|Supremo|Remote Utilities'
$apps = Get-ItemProperty 'HKLM:\Software\Microsoft\Windows\CurrentVersion\Uninstall\*',
                        'HKLM:\Software\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\*',
                        'HKCU:\Software\Microsoft\Windows\CurrentVersion\Uninstall\*' -ErrorAction SilentlyContinue |
        Where-Object DisplayName | Select-Object DisplayName, DisplayVersion, Publisher, InstallDate
Save ($apps | Sort-Object InstallDate -Descending) 'logiciels'
$found = @($apps | Where-Object DisplayName -match $rmm)
if ($found.Count) { Add-Result 'Prise en main distante' 'WARN' (($found.DisplayName) -join ', ') }
else { Add-Result 'Prise en main distante' 'OK' 'aucun outil connu' }

# Réseau
$conn = Get-NetTCPConnection -State Established -ErrorAction SilentlyContinue |
    Where-Object { $_.RemoteAddress -notmatch '^(127\.|::1|0\.0\.0\.0)' } |
    Select-Object RemoteAddress, RemotePort, OwningProcess,
        @{n = 'Processus'; e = { (Get-Process -Id $_.OwningProcess -ErrorAction SilentlyContinue).Path } }
Save $conn 'connexions'
Add-Result 'Connexions sortantes' 'INFO' "$(@($conn).Count) établies (voir connexions.txt)"

$proxy = (Get-ItemProperty 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Internet Settings' -ErrorAction SilentlyContinue).ProxyServer
if ($proxy) { Add-Result 'Proxy utilisateur' 'WARN' $proxy } else { Add-Result 'Proxy utilisateur' 'OK' 'aucun' }
$hosts = Get-Content "$env:SystemRoot\System32\drivers\etc\hosts" | Where-Object { $_ -and $_ -notmatch '^\s*#' }
if (@($hosts).Count) { $hosts | Out-File "$out\hosts.txt"; Add-Result 'Fichier hosts' 'WARN' "$(@($hosts).Count) entrée(s)" }
else { Add-Result 'Fichier hosts' 'OK' 'vierge' }
Save (Get-DnsClientServerAddress -AddressFamily IPv4) 'dns'

$resume | Out-File "$out\resume.txt" -Encoding UTF8
Write-Host "`n  Résultats : $out`n" -ForegroundColor Cyan
