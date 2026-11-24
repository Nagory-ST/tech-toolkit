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
