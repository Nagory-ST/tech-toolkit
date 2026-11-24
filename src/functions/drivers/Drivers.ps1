################################################################################
#  Pilotes : analyse, Windows Update, pilotes de la cle, export
################################################################################

function Get-TKOemInfo {
    $cs   = Get-CimInstance Win32_ComputerSystem
    $bios = Get-CimInstance Win32_BIOS
    $maker = "$($cs.Manufacturer)".Trim()
    $oem = switch -Regex ($maker) {
        'Dell'            { @{ Nom = 'Dell';    Outil = 'Dell Command | Update';  Page = 'https://www.dell.com/support/home/fr-fr' } }
        'Lenovo'          { @{ Nom = 'Lenovo';  Outil = 'Lenovo System Update / Commercial Vantage'; Page = 'https://pcsupport.lenovo.com/fr/fr' } }
        'HP|Hewlett'      { @{ Nom = 'HP';      Outil = 'HP Image Assistant / HP Support Assistant'; Page = 'https://support.hp.com/fr-fr/drivers' } }
        'ASUS'            { @{ Nom = 'ASUS';    Outil = 'MyASUS';                 Page = 'https://www.asus.com/fr/support/' } }
        'Acer'            { @{ Nom = 'Acer';    Outil = 'Acer Care Center';       Page = 'https://www.acer.com/fr-fr/support/drivers-and-manuals' } }
        'Microsoft'       { @{ Nom = 'Microsoft'; Outil = 'Windows Update';       Page = 'https://support.microsoft.com/fr-fr/surface' } }
        default           { @{ Nom = $maker;    Outil = $null;                    Page = $null } }
    }
    [pscustomobject]@{
        Fabricant = $maker
        Modele    = "$($cs.Model)".Trim()
        Serie     = "$($bios.SerialNumber)".Trim()
        Outil     = $oem.Outil
        Page      = $oem.Page
    }
}

function Invoke-TKDriverScan {
    <# Tache de fond : peripheriques en erreur + pilotes proposes par Windows Update #>
    $rows = New-Object System.Collections.Generic.List[object]
    $codes = @{ 1 = 'mal configuré'; 3 = 'pilote corrompu'; 10 = 'ne peut pas démarrer'; 18 = 'à réinstaller'; 22 = 'désactivé';
                24 = 'absent ou mal installé'; 28 = 'AUCUN PILOTE'; 31 = 'ne fonctionne pas correctement'; 39 = 'pilote corrompu ou manquant';
                43 = 'arrêté (problème signalé)'; 45 = 'non connecté' }

    Set-TKStatus 'Pilotes : périphériques en erreur...'
    $bad = @(Get-CimInstance Win32_PnPEntity | Where-Object { $_.ConfigManagerErrorCode -and $_.ConfigManagerErrorCode -notin 22, 45 })
    foreach ($d in $bad) {
        $hwid = @($d.HardwareID) | Select-Object -First 1
        $txt = if ($codes.ContainsKey([int]$d.ConfigManagerErrorCode)) { $codes[[int]$d.ConfigManagerErrorCode] } else { "code $($d.ConfigManagerErrorCode)" }
        $rows.Add([pscustomobject]@{
            Source = 'Problème'; Peripherique = $(if ($d.Name) { $d.Name } else { $d.PNPClass }); Version = "code $($d.ConfigManagerErrorCode)"
            Detail = "$txt  -  $hwid"; UpdateID = $null; HWID = $hwid; Taille = $null })
    }
    Write-TKLog ("Pilotes : {0} périphérique(s) en erreur." -f $bad.Count) $(if ($bad.Count) { 'WARN' } else { 'OK' })

    Set-TKStatus 'Pilotes : recherche sur Windows Update (1 à 3 min)...'
    try {
        $session = New-Object -ComObject Microsoft.Update.Session
        $searcher = $session.CreateUpdateSearcher()
        $searcher.ServerSelection = 2      # Windows Update directement (meme si le poste est gere par WSUS)
        $res = $searcher.Search("IsInstalled=0 and Type='Driver' and IsHidden=0")
        foreach ($u in $res.Updates) {
            $date = try { ([datetime]$u.DriverVerDate).ToString('dd/MM/yyyy') } catch { '' }
            $rows.Add([pscustomobject]@{
                Source = 'Windows Update'; Peripherique = $u.Title; Version = $date
                Detail = ("{0}  -  {1}  -  {2:N1} Mo" -f $u.DriverClass, $u.DriverManufacturer, ($u.MaxDownloadSize / 1MB))
                UpdateID = $u.Identity.UpdateID; HWID = $u.DriverHardwareID; Taille = $u.MaxDownloadSize })
        }
        Write-TKLog ("Pilotes : {0} mise(s) à jour proposée(s) par Windows Update." -f $res.Updates.Count) 'OK'
    } catch {
        Write-TKLog "Windows Update inaccessible : $($_.Exception.Message)" 'WARN'
    }

    [pscustomobject]@{ Rows = $rows.ToArray(); Oem = Get-TKOemInfo }
}

function Install-TKWUDrivers {
    <# Tache de fond : telecharge et installe les pilotes Windows Update selectionnes #>
    param([string[]]$Ids, [bool]$RestorePoint)
    if ($RestorePoint) { Set-TKStatus 'Point de restauration...'; New-TKRestorePoint }
    $session = New-Object -ComObject Microsoft.Update.Session
    $searcher = $session.CreateUpdateSearcher()
    $searcher.ServerSelection = 2
    Set-TKStatus 'Pilotes : préparation...'
    $res = $searcher.Search("IsInstalled=0 and Type='Driver' and IsHidden=0")
    $coll = New-Object -ComObject Microsoft.Update.UpdateColl
    foreach ($u in $res.Updates) {
        if ($Ids -contains $u.Identity.UpdateID) {
            if (-not $u.EulaAccepted) { $u.AcceptEula() }
            [void]$coll.Add($u)
        }
    }
    if ($coll.Count -eq 0) { Write-TKLog 'Les pilotes sélectionnés ne sont plus proposés (déjà installés ?).' 'WARN'; return }

    Set-TKStatus ("Pilotes : téléchargement de {0} pilote(s)..." -f $coll.Count)
    $dl = $session.CreateUpdateDownloader(); $dl.Updates = $coll
    [void]$dl.Download()
    Set-TKStatus ("Pilotes : installation de {0} pilote(s)..." -f $coll.Count)
    $inst = $session.CreateUpdateInstaller(); $inst.Updates = $coll
    $r = $inst.Install()
    $label = @{ 2 = 'OK'; 3 = 'OK (avec avertissements)'; 4 = 'ÉCHEC'; 5 = 'annulé' }
    for ($i = 0; $i -lt $coll.Count; $i++) {
        $code = $r.GetUpdateResult($i).ResultCode
        $lvl = if ($code -in 2, 3) { 'OK' } else { 'ERR' }
        Write-TKLog ("{0} : {1}" -f $coll.Item($i).Title, $(if ($label.ContainsKey([int]$code)) { $label[[int]$code] } else { "code $code" })) $lvl
    }
    if ($r.RebootRequired) { Write-TKLog 'Redémarrage nécessaire pour finaliser les pilotes.' 'WARN' }
}

function Install-TKDriversFromFolder {
    <# Tache de fond : pnputil installe seulement les pilotes qui correspondent au materiel #>
    param([string]$Path)
    Set-TKStatus "Pilotes : installation depuis $Path..."
    $out = & pnputil.exe /add-driver "$Path\*.inf" /subdirs /install 2>&1 | Out-String
    $added = ([regex]::Matches($out, '(?im)(Added driver packages|Packages de pilotes ajout[ée]s)\s*:\s*(\d+)') | Select-Object -Last 1)
    $n = if ($added) { $added.Groups[2].Value } else { '?' }
    Write-TKLog "pnputil : $n paquet(s) de pilotes ajouté(s) depuis $Path (seuls ceux qui correspondent au matériel sont installés)." 'OK'
    if ($out -match '(?i)reboot|redémarr') { Write-TKLog 'Redémarrage nécessaire pour finaliser les pilotes.' 'WARN' }
}

function Export-TKDrivers {
    <# Tache de fond : sauvegarde des pilotes tiers du poste (avant reinstallation) #>
    $cs = Get-CimInstance Win32_ComputerSystem
    $name = ('{0}-{1}' -f "$($cs.Manufacturer)".Trim(), "$($cs.Model)".Trim()) -replace '[\\/:*?"<>|]', ''
    $dest = Join-Path (Get-TKCollectePath) "Drivers\$name"
    New-Item -ItemType Directory -Path $dest -Force | Out-Null
    Set-TKStatus 'Pilotes : export...'
    & pnputil.exe /export-driver * "$dest" | Out-Null
    $count = @(Get-ChildItem -LiteralPath $dest -Directory).Count
    Write-TKLog "Pilotes exportés : $count paquet(s) dans $dest" 'OK'
    if ($sync.Mode -eq 'USB') { Write-TKLog 'Pour les réutiliser depuis la clé : déverrouille TOOLS et déplace ce dossier dans Drivers\Exports.' 'INFO' }
}
