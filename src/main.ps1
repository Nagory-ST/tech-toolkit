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
