################################################################################
#  Creation / mise a jour de la cle USB Tech Toolkit
################################################################################

function Get-TKUsbDisks {
    <# Disques USB eligibles : jamais le disque systeme/boot, jamais la cle qui execute l'outil #>
    $self = $null
    if ($sync.Root) {
        try { $self = (Get-Partition -DriveLetter ((Split-Path $sync.Root -Qualifier).TrimEnd(':')) -ErrorAction Stop).DiskNumber } catch {}
    }
    @(Get-Disk | Where-Object { $_.BusType -eq 'USB' -and -not $_.IsBoot -and -not $_.IsSystem -and $_.Number -ne $self -and $_.Size -gt 0 } |
        ForEach-Object {
            $labels = @(Get-Partition -DiskNumber $_.Number -ErrorAction SilentlyContinue | Get-Volume -ErrorAction SilentlyContinue | ForEach-Object { $_.FileSystemLabel })
            [pscustomobject]@{
                Number   = $_.Number
                Name     = $_.FriendlyName
                SizeGB   = [math]::Round($_.Size / 1GB, 1)
                IsKit    = ($labels -contains 'Ventoy') -and ($labels -contains 'TOOLS')
                IsVentoy = ($labels -contains 'Ventoy')
                Display  = ('Disque {0}  -  {1}  -  {2} Go' -f $_.Number, $_.FriendlyName, [math]::Round($_.Size / 1GB, 1))
            }
        })
}

function Get-TKHttp {
    if (-not $sync.Http) {
        Add-Type -AssemblyName System.Net.Http
        [Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12
        $h = New-Object System.Net.Http.HttpClientHandler
        $h.AllowAutoRedirect = $true
        $c = New-Object System.Net.Http.HttpClient -ArgumentList $h
        $c.Timeout = [TimeSpan]::FromHours(3)
        $c.DefaultRequestHeaders.UserAgent.ParseAdd('Mozilla/5.0 (Windows NT 10.0; Win64; x64) TechToolkit/1.0')
        $sync.Http = $c
    }
    $sync.Http
}

function Get-TKDownload {
    <# Telechargement en flux avec progression dans la barre de statut #>
    param([Parameter(Mandatory)][string]$Url, [Parameter(Mandatory)][string]$OutFile, [string]$Label = 'Téléchargement')
    $http = Get-TKHttp
    $resp = $http.GetAsync($Url, [System.Net.Http.HttpCompletionOption]::ResponseHeadersRead).GetAwaiter().GetResult()
    if (-not $resp.IsSuccessStatusCode) { $code = [int]$resp.StatusCode; $resp.Dispose(); throw "HTTP $code sur $Url" }
    $total = $resp.Content.Headers.ContentLength
    $in = $resp.Content.ReadAsStreamAsync().GetAwaiter().GetResult()
    $tmp = "$OutFile.part"
    $out = [IO.File]::Create($tmp)
    try {
        $buf = New-Object byte[] 1048576
        $done = 0L; $last = -1
        while (($n = $in.Read($buf, 0, $buf.Length)) -gt 0) {
            $out.Write($buf, 0, $n)
            $done += $n
            if ($total) {
                $pct = [int]($done * 100 / $total)
                if ($pct -ne $last) { $last = $pct; Set-TKStatus ('{0} : {1} % ({2:N0} / {3:N0} Mo)' -f $Label, $pct, ($done / 1MB), ($total / 1MB)) }
            } elseif (($done % 20MB) -lt $n) {
                Set-TKStatus ('{0} : {1:N0} Mo' -f $Label, ($done / 1MB))
            }
        }
    } finally { $out.Dispose(); $in.Dispose(); $resp.Dispose() }
    if ((Get-Item -LiteralPath $tmp).Length -lt 1024) {
        $head = [IO.File]::ReadAllText($tmp)
        Remove-Item -LiteralPath $tmp -Force
        throw "Fichier reçu trop petit (page d'erreur ?) : $($head.Substring(0, [math]::Min(120, $head.Length)))"
    }
    Move-Item -LiteralPath $tmp -Destination $OutFile -Force
}

function Resolve-TKGithubAsset {
    param([string]$Repo, [string[]]$Patterns)
    $json = (Get-TKHttp).GetStringAsync("https://api.github.com/repos/$Repo/releases/latest").GetAwaiter().GetResult() | ConvertFrom-Json
    foreach ($p in $Patterns) {
        $a = @($json.assets | Where-Object { $_.name -match $p }) | Select-Object -First 1
        if ($a) { return [pscustomobject]@{ Url = $a.browser_download_url; Name = $a.name; Version = $json.tag_name } }
    }
    throw "Aucun fichier correspondant dans la dernière version de $Repo ($($json.tag_name))"
}

function Expand-TKArchive {
    <# Extrait un zip et renvoie le dossier utile (descend si le zip contient un seul dossier) #>
    param([string]$Zip, [string]$To)
    if (Test-Path -LiteralPath $To) { Remove-Item -LiteralPath $To -Recurse -Force }
    Expand-Archive -LiteralPath $Zip -DestinationPath $To -Force
    $dir = $To
    while ($true) {
        $items = @(Get-ChildItem -LiteralPath $dir -Force)
        if ($items.Count -eq 1 -and $items[0].PSIsContainer) { $dir = $items[0].FullName } else { break }
    }
    return $dir
}

function Wait-TKVolume {
    param([int]$DiskNumber, [string]$Label, [int]$TimeoutSec = 45)
    for ($i = 0; $i -lt $TimeoutSec; $i++) {
        Update-HostStorageCache -ErrorAction SilentlyContinue
        $part = Get-Partition -DiskNumber $DiskNumber -ErrorAction SilentlyContinue |
                Where-Object { ($_ | Get-Volume -ErrorAction SilentlyContinue).FileSystemLabel -eq $Label } | Select-Object -First 1
        if ($part) {
            if ("$($part.DriveLetter)" -notmatch '^[A-Za-z]$') {
                $part | Add-PartitionAccessPath -AssignDriveLetter -ErrorAction SilentlyContinue
                Start-Sleep -Seconds 2
                $part = Get-Partition -DiskNumber $DiskNumber -PartitionNumber $part.PartitionNumber
            }
            if ("$($part.DriveLetter)" -match '^[A-Za-z]$') { return $part }
        }
        Start-Sleep -Seconds 1
    }
    throw "Partition '$Label' introuvable sur le disque $DiskNumber"
}

function Install-TKVentoy {
    param([int]$DiskNumber, [string]$Work, [ValidateSet('Install', 'Update')][string]$Mode, [int]$ReserveMB)
    $asset = Resolve-TKGithubAsset -Repo 'ventoy/Ventoy' -Patterns @('(?i)windows\.zip$')
    Write-TKLog "Ventoy $($asset.Version) : téléchargement..." 'INFO'
    $zip = Join-Path $Work 'ventoy.zip'
    Get-TKDownload -Url $asset.Url -OutFile $zip -Label "Ventoy $($asset.Version)"
    $dir = Expand-TKArchive -Zip $zip -To (Join-Path $Work 'ventoy')
    $exe = Get-ChildItem -LiteralPath $dir -Recurse -Filter 'Ventoy2Disk.exe' | Where-Object { $_.FullName -notmatch '\\altexe\\' } | Select-Object -First 1
    if (-not $exe) { throw 'Ventoy2Disk.exe introuvable dans l''archive' }
    $wd = $exe.DirectoryName
    Remove-Item (Join-Path $wd 'cli_*.txt') -Force -ErrorAction SilentlyContinue

    $cliArgs = if ($Mode -eq 'Install') { "VTOYCLI /I /PhyDrive:$DiskNumber /GPT /R:$ReserveMB" } else { "VTOYCLI /U /PhyDrive:$DiskNumber" }
    Write-TKLog "Ventoy2Disk $cliArgs" 'INFO'
    $p = Start-Process -FilePath $exe.FullName -ArgumentList $cliArgs -WorkingDirectory $wd -PassThru -WindowStyle Hidden
    $doneFile = Join-Path $wd 'cli_done.txt'
    $pctFile = Join-Path $wd 'cli_percent.txt'
    $limit = (Get-Date).AddMinutes(20)
    while (-not (Test-Path $doneFile) -and (Get-Date) -lt $limit) {
        $pct = Get-Content $pctFile -ErrorAction SilentlyContinue | Select-Object -First 1
        Set-TKStatus ("Ventoy : {0} {1} %" -f $(if ($Mode -eq 'Install') { 'installation' } else { 'mise à jour' }), $pct)
        if ($p.HasExited -and -not (Test-Path $doneFile)) { Start-Sleep -Seconds 3; break }
        Start-Sleep -Milliseconds 700
    }
    $result = (Get-Content $doneFile -ErrorAction SilentlyContinue | Select-Object -First 1)
    if ("$result".Trim() -ne '0') {
        $log = (Get-Content (Join-Path $wd 'cli_log.txt') -Tail 8 -ErrorAction SilentlyContinue) -join ' | '
        throw "Échec Ventoy (cli_done=$result). $log"
    }
    Write-TKLog "Ventoy $($asset.Version) : $(if ($Mode -eq 'Install') { 'installé' } else { 'mis à jour' })." 'OK'
}

function Get-TKKitSource {
    <# Dossier contenant usb\, dist\toolkit.ps1, launcher\ : depot local si dispo, sinon zip GitHub #>
    param([string]$Work)
    if ($sync.Root) {
        foreach ($cand in @((Split-Path $sync.Root -Parent), $sync.Root)) {
            if ($cand -and (Test-Path (Join-Path $cand 'usb\VENTOY')) -and (Test-Path (Join-Path $cand 'dist\toolkit.ps1'))) {
                Write-TKLog "Kit : dépôt local $cand" 'INFO'
                return $cand
            }
        }
    }
    $zip = Join-Path $Work 'kit.zip'
    Get-TKDownload -Url $sync.RepoZip -OutFile $zip -Label 'Kit Tech Toolkit'
    return (Expand-TKArchive -Zip $zip -To (Join-Path $Work 'kit'))
}

function Copy-TKTree {
    param([string]$From, [string]$To, [string[]]$KeepIfExists = @())
    foreach ($f in Get-ChildItem -LiteralPath $From -Recurse -File -Force) {
        if ($f.Name -eq '.keep') { $dirOnly = $true } else { $dirOnly = $false }
        $rel = $f.FullName.Substring($From.Length).TrimStart('\')
        $dst = Join-Path $To $rel
        $dstDir = Split-Path $dst -Parent
        if (-not (Test-Path -LiteralPath $dstDir)) { New-Item -ItemType Directory -Path $dstDir -Force | Out-Null }
        if ($dirOnly) { continue }
        if ((Test-Path -LiteralPath $dst) -and ($KeepIfExists -contains $rel)) { continue }
        Copy-Item -LiteralPath $f.FullName -Destination $dst -Force
    }
}

function Install-TKUsbComponent {
    param([Parameter(Mandatory)]$C, [string]$VentoyRoot, [string]$ToolsRoot, [string]$Work, [bool]$Force)
    $base = if ($C.target -eq 'ventoy') { $VentoyRoot } else { $ToolsRoot }
    $dest = Join-Path $base $C.dest
    $check = if ($C.check) { Join-Path $base $C.check } else { $dest }
    $res = { param($r, $d) [pscustomobject]@{ Composant = $C.name; Resultat = $r; Detail = $d } }

    # Fichier deja telecharge par le technicien dans son dossier Telechargements ?
    $local = $null
    if ($C.local) {
        $dl = Join-Path $env:USERPROFILE 'Downloads'
        $local = Get-ChildItem -LiteralPath $dl -Filter $C.local -File -ErrorAction SilentlyContinue |
                 Sort-Object LastWriteTime -Descending | Select-Object -First 1
    }
    if ($C.source.type -eq 'page' -and -not $local) {
        return (& $res 'Manuel' "Page ouverte, à déposer dans $dest")
    }
    if ((Test-Path -LiteralPath $check) -and -not $Force -and -not $C.refresh) {
        return (& $res 'Déjà présent' $check)
    }

    $url = $C.source.url; $name = $null; $ver = ''
    if ($local) {
        $name = $local.Name
        $isZip = [bool]$C.extract -or ($name -match '\.zip$')
        if (-not $isZip) {
            # Copie directe vers la cle (pas de detour par le dossier temporaire)
            Set-TKStatus "Copie de $name depuis Téléchargements..."
            New-Item -ItemType Directory -Path (Split-Path $dest -Parent) -Force | Out-Null
            Copy-Item -LiteralPath $local.FullName -Destination $dest -Force
            Write-TKLog "$($C.name) : copié depuis Téléchargements ($name)" 'OK'
            return (& $res 'OK' "Téléchargements\$name -> $dest")
        }
    }
    elseif ($C.source.type -eq 'github') {
        $a = Resolve-TKGithubAsset -Repo $C.source.repo -Patterns @($C.source.asset)
        $url = $a.Url; $name = $a.Name; $ver = $a.Version
    }
    elseif ($C.source.type -eq 'scrape') {
        # Lien versionne lu sur la page officielle (pas d'URL "latest" stable)
        $html = (Get-TKHttp).GetStringAsync($C.source.page).GetAwaiter().GetResult()
        $m = [regex]::Match($html, $C.source.pattern)
        if (-not $m.Success) { throw "Lien introuvable sur $($C.source.page) (la page a peut-être changé)" }
        $url = $m.Value; $name = Split-Path $url -Leaf
        $v = [regex]::Match($name, '\d+(\.\d+)+'); if ($v.Success) { $ver = $v.Value }
    }
    $isZip = [bool]$C.extract -or ($name -match '\.zip$')
    $ext = if ($isZip) { '.zip' } elseif ($name) { [IO.Path]::GetExtension($name) } else { [IO.Path]::GetExtension($dest) }
    $tmp = Join-Path $Work ($C.id + $ext)
    if ($local) { Copy-Item -LiteralPath $local.FullName -Destination $tmp -Force; $ver = "(Téléchargements\$name)" }
    else { Get-TKDownload -Url $url -OutFile $tmp -Label $C.name }

    if ($isZip) {
        $x = Expand-TKArchive -Zip $tmp -To (Join-Path $Work "$($C.id)_x")
        if ($C.pick) {
            $f = Get-ChildItem -LiteralPath $x -Recurse -Filter $C.pick | Select-Object -First 1
            if (-not $f) { throw "Aucun fichier $($C.pick) dans l'archive" }
            New-Item -ItemType Directory -Path (Split-Path $dest -Parent) -Force | Out-Null
            Copy-Item -LiteralPath $f.FullName -Destination $dest -Force
        } else {
            New-Item -ItemType Directory -Path $dest -Force | Out-Null
            Copy-Item -Path (Join-Path $x '*') -Destination $dest -Recurse -Force
        }
        if ($C.renameFrom) {
            $f = Get-ChildItem -LiteralPath $dest -Filter $C.renameFrom | Where-Object { $_.Name -ne $C.renameTo } | Select-Object -First 1
            if ($f) { Copy-Item -LiteralPath $f.FullName -Destination (Join-Path $dest $C.renameTo) -Force }
        }
        Remove-Item -LiteralPath (Join-Path $Work "$($C.id)_x") -Recurse -Force -ErrorAction SilentlyContinue
        Remove-Item -LiteralPath $tmp -Force -ErrorAction SilentlyContinue
    } else {
        New-Item -ItemType Directory -Path (Split-Path $dest -Parent) -Force | Out-Null
        Move-Item -LiteralPath $tmp -Destination $dest -Force
    }
    Write-TKLog "$($C.name) $ver : OK" 'OK'
    return (& $res 'OK' ("$ver $dest").Trim())
}

function New-TKUsbKey {
    <# Tache de fond : installe ou met a jour la cle complete #>
    param([int]$DiskNumber, [int]$ToolsGB, [string[]]$Components, [bool]$UpdateOnly, [bool]$UpdateVentoy, [bool]$Force, [bool]$Lock)
    $report = New-Object System.Collections.Generic.List[object]
    $pages = New-Object System.Collections.Generic.List[string]
    $work = Join-Path $env:TEMP 'TechToolkit\usb'
    New-Item -ItemType Directory -Path $work -Force | Out-Null

    # Garde-fous (re-verifies ici, juste avant d'ecrire)
    $disk = Get-Disk -Number $DiskNumber -ErrorAction Stop
    if ($disk.BusType -ne 'USB' -or $disk.IsBoot -or $disk.IsSystem) { throw "Disque $DiskNumber refusé (pas USB, ou disque système)." }
    if (-not $UpdateOnly -and $disk.Size -lt 16GB) { throw 'Clé trop petite : 16 Go minimum (32 Go conseillés).' }

    # 1. Ventoy
    if (-not $UpdateOnly) {
        Install-TKVentoy -DiskNumber $DiskNumber -Work $work -Mode 'Install' -ReserveMB ($ToolsGB * 1024)
    } elseif ($UpdateVentoy) {
        Install-TKVentoy -DiskNumber $DiskNumber -Work $work -Mode 'Update' -ReserveMB 0
    }

    # 2. Partitions
    Set-TKStatus 'Partitions...'
    $vPart = Wait-TKVolume -DiskNumber $DiskNumber -Label 'Ventoy'
    if (-not $UpdateOnly) {
        $free = (Get-Disk -Number $DiskNumber).LargestFreeExtent
        if ($free -lt 1GB) { throw 'Pas d''espace réservé pour la partition TOOLS après Ventoy.' }
        Write-TKLog ('Création de la partition TOOLS ({0:N1} Go)...' -f ($free / 1GB)) 'INFO'
        New-Partition -DiskNumber $DiskNumber -UseMaximumSize -AssignDriveLetter |
            Format-Volume -FileSystem NTFS -NewFileSystemLabel 'TOOLS' -Confirm:$false | Out-Null
    }
    $tPart = Wait-TKVolume -DiskNumber $DiskNumber -Label 'TOOLS'
    if ($tPart.IsReadOnly) {
        Set-Partition -DiskNumber $DiskNumber -PartitionNumber $tPart.PartitionNumber -IsReadOnly $false
        Write-TKLog 'TOOLS déverrouillée pour la mise à jour.' 'INFO'
    }
    $V = "$($vPart.DriveLetter):\"
    $T = "$($tPart.DriveLetter):\"
    Write-TKLog "Ventoy = $V   TOOLS = $T" 'INFO'

    # 3. Kit (theme, menus, scripts, Tech Toolkit lui-meme)
    Set-TKStatus 'Copie du kit...'
    $src = Get-TKKitSource -Work $work
    Copy-TKTree -From (Join-Path $src 'usb\VENTOY') -To $V -KeepIfExists @('ventoy\ventoy.json')
    Copy-TKTree -From (Join-Path $src 'usb\TOOLS') -To $T -KeepIfExists @('tools.json', 'Deploy\PostInstall\postinstall.ps1')
    Copy-Item -LiteralPath (Join-Path $src 'dist\toolkit.ps1') -Destination $T -Force
    Copy-Item -LiteralPath (Join-Path $src 'launcher\START.bat') -Destination $T -Force
    $report.Add([pscustomobject]@{ Composant = 'Kit Tech Toolkit'; Resultat = 'OK'; Detail = 'thème Ventoy, menus, scripts, toolkit.ps1' })

    # 4. Composants
    $list = @($sync.configs.usb | Where-Object { $Components -contains $_.id })
    $i = 0
    foreach ($c in $list) {
        $i++
        Set-TKStatus ("Composant {0}/{1} : {2}" -f $i, $list.Count, $c.name)
        try {
            $r = Install-TKUsbComponent -C $c -VentoyRoot $V -ToolsRoot $T -Work $work -Force $Force
            $report.Add($r)
            if ($r.Resultat -eq 'Manuel') { $pages.Add($c.source.url); if ($c.note) { Write-TKLog "$($c.name) : $($c.note)" 'WARN' } }
        } catch {
            Write-TKLog "$($c.name) : $($_.Exception.Message)" 'ERR'
            $report.Add([pscustomobject]@{ Composant = $c.name; Resultat = 'Erreur'; Detail = $_.Exception.Message })
        }
    }

    # 5. Empreintes + verrouillage
    $integrity = Join-Path $T 'Scripts\integrity.ps1'
    if (Test-Path -LiteralPath $integrity) {
        Set-TKStatus 'Calcul des empreintes SHA256...'
        & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $integrity -Init | Out-Null
        Write-TKLog 'Manifeste d''intégrité généré.' 'OK'
    }
    if ($Lock) {
        Set-Partition -DiskNumber $DiskNumber -PartitionNumber $tPart.PartitionNumber -IsReadOnly $true
        Write-TKLog 'TOOLS verrouillée en lecture seule.' 'OK'
        if ($pages.Count) { Write-TKLog 'Pour déposer les fichiers à télécharger à la main sur TOOLS : Scripts\lock.ps1 -Unlock, puis relock.' 'WARN' }
    }
    Remove-Item -LiteralPath $work -Recurse -Force -ErrorAction SilentlyContinue

    $ko = @($report | Where-Object Resultat -eq 'Erreur').Count
    Write-TKLog ("Clé prête : {0} OK, {1} erreur(s), {2} à faire à la main." -f @($report | Where-Object Resultat -in 'OK', 'Déjà présent').Count, $ko, $pages.Count) $(if ($ko) { 'WARN' } else { 'OK' })
    [pscustomobject]@{ Report = $report.ToArray(); Pages = $pages.ToArray(); Ventoy = $V; Tools = $T }
}
