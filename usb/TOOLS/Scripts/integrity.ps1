<#  Intégrité de la partition TOOLS (SHA256).
    -Init   : crée/maj le manifeste (sur TON poste, partition déverrouillée, clé saine)
    -Verify : compare l'état actuel au manifeste  #>
param([switch]$Init, [switch]$Verify)

[Console]::OutputEncoding = [Text.Encoding]::UTF8
$Root = Split-Path $PSScriptRoot -Parent
$Manifest = Join-Path $Root 'manifest.csv'

function Get-State {
    Get-ChildItem -LiteralPath $Root -Recurse -File -Force |
        Where-Object { $_.FullName -ne $Manifest -and $_.Extension -notin '.gguf' } |
        ForEach-Object {
            [pscustomobject]@{
                Path = $_.FullName.Substring($Root.Length).TrimStart('\')
                Hash = (Get-FileHash -LiteralPath $_.FullName -Algorithm SHA256).Hash
            }
        }
}

if ($Init) {
    Write-Host 'Calcul des empreintes...' -ForegroundColor Cyan
    Get-State | Export-Csv $Manifest -NoTypeInformation -Encoding UTF8
    Write-Host "Manifeste écrit : $Manifest" -ForegroundColor Green
    return
}

if (-not (Test-Path $Manifest)) { Write-Host 'Pas de manifeste : lance integrity.ps1 -Init sur ton poste.' -ForegroundColor Yellow; return }

Write-Host 'Vérification...' -ForegroundColor Cyan
$ref = @{}; Import-Csv $Manifest | ForEach-Object { $ref[$_.Path] = $_.Hash }
$now = @{}; Get-State | ForEach-Object { $now[$_.Path] = $_.Hash }

$added    = @($now.Keys | Where-Object { -not $ref.ContainsKey($_) })
$removed  = @($ref.Keys | Where-Object { -not $now.ContainsKey($_) })
$modified = @($now.Keys | Where-Object { $ref.ContainsKey($_) -and $ref[$_] -ne $now[$_] })

if (-not ($added + $removed + $modified)) { Write-Host "OK : $($ref.Count) fichiers conformes." -ForegroundColor Green; return }
$added    | ForEach-Object { Write-Host "  [AJOUTÉ]   $_" -ForegroundColor Red }
$modified | ForEach-Object { Write-Host "  [MODIFIÉ]  $_" -ForegroundColor Red }
$removed  | ForEach-Object { Write-Host "  [SUPPRIMÉ] $_" -ForegroundColor Yellow }
Write-Host "`nNe branche plus la clé chez un client avant d'avoir compris ces écarts." -ForegroundColor Red
