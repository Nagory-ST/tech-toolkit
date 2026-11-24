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
