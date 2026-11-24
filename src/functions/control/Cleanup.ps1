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
