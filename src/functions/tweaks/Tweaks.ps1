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
