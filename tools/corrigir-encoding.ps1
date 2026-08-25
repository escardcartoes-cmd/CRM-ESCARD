# =====================================================================
# Corrige mojibake introduzido pelo aplicar-icp-chips.ps1
#
# Causa: o .ps1 foi salvo em UTF-8 sem BOM e o PowerShell 5.1 leu as
# here-strings como CP1252, corrompendo os em-dash das 3 linhas de
# comentario inseridas.
#
# Atua SO nas 3 linhas conhecidas. Reporta antes e depois.
# So comentarios CSS/JS - zero impacto funcional.
# =====================================================================

$ErrorActionPreference = 'Stop'

$repo = 'C:\dev\CRM-ESCARD'
$alvo = Join-Path $repo 'index.html'
$utf8 = New-Object System.Text.UTF8Encoding($false)

Write-Host ''
Write-Host '=== Correcao de encoding ===' -ForegroundColor Cyan

$t = [System.IO.File]::ReadAllText($alvo, $utf8)
$crlf = $t.Contains("`r`n")

# Assinaturas das 3 linhas afetadas: texto ancora + o que vem depois
$alvos = @(
  @{ pre = 'ICP ';                      pos = ' chips de filtro por tier' },
  @{ pre = '// Filtro "Prioridade ICP" '; pos = ' chips de selecao multipla' },
  @{ pre = '  // ';                     pos = ' nao altera a paginacao nem as RPCs' }
)

$antes = 0
foreach($a in $alvos){
  $rx = [regex]::Escape($a.pre) + '([^\x00-\x7F]+)' + [regex]::Escape($a.pos)
  $m = [regex]::Matches($t, $rx)
  $antes += $m.Count
  foreach($x in $m){
    $bytes = [System.Text.Encoding]::UTF8.GetBytes($x.Groups[1].Value)
    $hex = ($bytes | ForEach-Object { $_.ToString('X2') }) -join ' '
    Write-Host ("  encontrado: [{0}]  bytes: {1}" -f $x.Groups[1].Value, $hex) -ForegroundColor Yellow
  }
  $t = [regex]::Replace($t, $rx, ($a.pre + '-' + $a.pos))
}

if($antes -eq 0){
  Write-Host 'Nenhum mojibake encontrado nas 3 linhas alvo. Nada a fazer.' -ForegroundColor Green
  Write-Host ''
  exit 0
}

if($crlf){ $t = $t -replace "(?<!`r)`n", "`r`n" }
[System.IO.File]::WriteAllText($alvo, $t, $utf8)

# --- Conferencia global ---------------------------------------------
$c = [System.IO.File]::ReadAllText($alvo, $utf8)
$rest = ([regex]::Matches($c, [char]0x00E2 + '[^\x00-\x7F]')).Count

Write-Host ''
Write-Host ("Linhas corrigidas : {0}" -f $antes) -ForegroundColor Green
Write-Host ("Mojibake restante : {0}  (deve ser 0)" -f $rest)
Write-Host ''
Write-Host 'Amostra das linhas corrigidas:' -ForegroundColor Yellow
($c -split "`n") | Select-String -Pattern 'chips de filtro por tier|chips de selecao multipla|nao altera a paginacao' | ForEach-Object { Write-Host ('  ' + $_.ToString().Trim()) }
Write-Host ''
Write-Host 'Agora rode: tools\checar.ps1' -ForegroundColor Green
Write-Host ''
