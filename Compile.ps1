<#
  Assemble src/ + config/ en un seul fichier : dist/toolkit.ps1
  - JSON et XAML sont embarqués et convertis en ASCII (\uXXXX / &#xXXXX;)
  - Le code PowerShell ne doit contenir que de l'ASCII ou des lettres accentuées latines
    (les caractères typographiques comme les tirets longs ou guillemets courbes cassent
     Windows PowerShell 5.1 quand le fichier est lu sans BOM).
  - Le résultat est analysé par le parseur PowerShell : la compilation échoue en cas d'erreur.
  Usage : pwsh ./Compile.ps1 [-Version 26.11.24]
#>
param([string]$Version = (Get-Date -Format 'yy.MM.dd'))

$ErrorActionPreference = 'Stop'
$root = $PSScriptRoot
$dist = Join-Path $root 'dist'
New-Item -ItemType Directory -Path $dist -Force | Out-Null

function ConvertTo-AsciiJson([string]$s) {
    $sb = New-Object System.Text.StringBuilder
    foreach ($c in $s.ToCharArray()) { if ([int]$c -gt 127) { [void]$sb.AppendFormat('\u{0:x4}', [int]$c) } else { [void]$sb.Append($c) } }
    $sb.ToString()
}
function ConvertTo-AsciiXml([string]$s) {
    $sb = New-Object System.Text.StringBuilder
    foreach ($c in $s.ToCharArray()) { if ([int]$c -gt 127) { [void]$sb.AppendFormat('&#x{0:X4};', [int]$c) } else { [void]$sb.Append($c) } }
    $sb.ToString()
}
function Test-SafePs([string]$file) {
    $txt = [IO.File]::ReadAllText($file, [Text.Encoding]::UTF8)
    $bad = @()
    $n = 0
    foreach ($line in $txt -split "`n") {
        $n++
        foreach ($c in $line.ToCharArray()) {
            $code = [int]$c
            if (($code -ge 0x80 -and $code -le 0xBF) -or $code -ge 0x100) { $bad += "{0}:{1} U+{2:X4}" -f (Split-Path $file -Leaf), $n, $code; break }
        }
    }
    $bad
}

$psFiles = @(Join-Path $root 'src/start.ps1') +
           @(Get-ChildItem (Join-Path $root 'src/functions') -Recurse -Filter *.ps1 | Sort-Object FullName | ForEach-Object FullName) +
           @(Join-Path $root 'src/main.ps1')

$unsafe = $psFiles | ForEach-Object { Test-SafePs $_ }
if ($unsafe) { throw "Caractères non sûrs pour PowerShell 5.1 :`n$($unsafe -join "`n")" }

$out = New-Object System.Text.StringBuilder
[void]$out.AppendLine(([IO.File]::ReadAllText($psFiles[0], [Text.Encoding]::UTF8)).Replace('#{VERSION}#', $Version))

[void]$out.AppendLine('# ---------------------------------------------------------------- configs')
foreach ($cfg in Get-ChildItem (Join-Path $root 'config') -Filter *.json | Sort-Object Name) {
    $json = [IO.File]::ReadAllText($cfg.FullName, [Text.Encoding]::UTF8)
    $null = $json | ConvertFrom-Json   # validation
    [void]$out.AppendLine("`$sync.configs.$($cfg.BaseName) = @'")
    [void]$out.AppendLine((ConvertTo-AsciiJson $json.TrimEnd()))
    [void]$out.AppendLine("'@ | ConvertFrom-Json")
}

[void]$out.AppendLine('# ---------------------------------------------------------------- xaml')
$xamlPath = Join-Path (Join-Path (Join-Path $root 'src') 'xaml') 'MainWindow.xaml'
$xamlTxt = [IO.File]::ReadAllText($xamlPath, [Text.Encoding]::UTF8)
[xml]$null = $xamlTxt   # validation XML
[void]$out.AppendLine("`$inputXML = @'")
[void]$out.AppendLine((ConvertTo-AsciiXml $xamlTxt.TrimEnd()))
[void]$out.AppendLine("'@")

foreach ($f in $psFiles[1..($psFiles.Count - 1)]) {
    [void]$out.AppendLine("# ---------------------------------------------------------------- $(Split-Path $f -Leaf)")
    [void]$out.AppendLine([IO.File]::ReadAllText($f, [Text.Encoding]::UTF8).TrimEnd())
}

$target = Join-Path $dist 'toolkit.ps1'
$content = $out.ToString() -replace "`r?`n", "`r`n"
[IO.File]::WriteAllText($target, $content, (New-Object System.Text.UTF8Encoding $false))

$tokens = $null; $errors = $null
[System.Management.Automation.Language.Parser]::ParseFile($target, [ref]$tokens, [ref]$errors) | Out-Null
if ($errors) {
    $errors | ForEach-Object { Write-Host ("L{0}: {1}" -f $_.Extent.StartLineNumber, $_.Message) -ForegroundColor Red }
    throw 'Erreurs de syntaxe dans dist/toolkit.ps1'
}
$hash = (Get-FileHash $target -Algorithm SHA256).Hash
Set-Content -Path (Join-Path $dist 'toolkit.ps1.sha256') -Value "$hash  toolkit.ps1" -Encoding ascii
Write-Host "OK : $target  (v$Version, $([math]::Round((Get-Item $target).Length / 1KB)) Ko)" -ForegroundColor Green
Write-Host "SHA256 : $hash"
