<#
  checar.ps1 - validacao do index.html single-file (CRM-ESCARD)

  Uso:
    powershell -ExecutionPolicy Bypass -File .\tools\checar.ps1

  NAO cole o conteudo deste arquivo no console: ele termina com "exit",
  o que fecha a sessao interativa do PowerShell. Rode sempre com -File.

  Parametros opcionais:
    -Path <arquivo>     alvo diferente de <raiz>\index.html
    -MaxPerdaJs <n>     perda de linhas de JS tolerada vs backup (padrao 20)
#>
param(
  [string]$Path,
  [int]$MaxPerdaJs = 20
)
$ErrorActionPreference = 'Stop'

$raiz = Split-Path -Parent $PSScriptRoot
if (-not $Path) { $Path = Join-Path $raiz 'index.html' }
if (-not (Test-Path -LiteralPath $Path)) { Write-Host "Nao encontrei $Path" -ForegroundColor Red; exit 1 }
$Path = (Resolve-Path -LiteralPath $Path).Path

Write-Host "=== Checagem de $Path ===" -ForegroundColor Cyan
$html = [IO.File]::ReadAllText($Path)
Write-Host ("Tamanho: {0} KB" -f [int]((Get-Item -LiteralPath $Path).Length / 1KB))

# --- Mascaramento de comentario HTML -------------------------------------
# O SheetJS inline contem o literal de regex <!--.*?--> ; sem mascarar, a
# extracao de <script> quebra em fronteiras falsas. Substitui por espacos
# de comprimento igual para preservar todos os offsets do texto original.
$mask = [System.Text.RegularExpressions.MatchEvaluator] {
  param($m)
  ' ' * $m.Value.Length
}
$limpo = [regex]::Replace($html, '<!--[\s\S]*?-->', $mask)

# --- Extracao dos blocos <script> sem src --------------------------------
$rxScript = [regex] '(?is)<script(?![^>]*\bsrc\s*=)[^>]*>([\s\S]*?)</script>'
$blocos = $rxScript.Matches($limpo)
if ($blocos.Count -eq 0) { Write-Host 'Nenhum bloco <script> inline encontrado.' -ForegroundColor Red; exit 1 }
Write-Host ("Blocos <script> inline: {0}" -f $blocos.Count)

$tmp = Join-Path $env:TEMP ('checar-' + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $tmp | Out-Null

$falhas = 0
$linhasJs = 0
$i = 0
$todoJs = New-Object System.Text.StringBuilder

foreach ($b in $blocos) {
  $i++
  # Recorta do HTML ORIGINAL usando os offsets do texto mascarado, para
  # validar o codigo real e nao a versao com comentarios apagados.
  $g = $b.Groups[1]
  $js = $html.Substring($g.Index, $g.Length)
  $n = ([regex]::Matches($js, "`n")).Count
  $linhasJs += $n
  [void]$todoJs.AppendLine($js)

  $arq = Join-Path $tmp ("bloco{0}.js" -f $i)
  [IO.File]::WriteAllText($arq, $js, (New-Object System.Text.UTF8Encoding($false)))

  $saida = & node --check $arq 2>&1
  if ($LASTEXITCODE -ne 0) {
    Write-Host ("  [FALHA] bloco {0}" -f $i) -ForegroundColor Red
    $saida | ForEach-Object { Write-Host ("    " + $_) -ForegroundColor Red }
    $falhas++
  }
  else {
    Write-Host ("  [ok] bloco {0} ({1} linhas)" -f $i, $n) -ForegroundColor Green
  }
}

# --- Higiene -------------------------------------------------------------
$js = $todoJs.ToString()
$nConsole = ([regex]::Matches($js, '(?<![\w.$])console\s*\.')).Count
$nStorage = ([regex]::Matches($js, '(?<![\w.$])(local|session)Storage\b')).Count
Write-Host ("console.*   : {0}" -f $nConsole) -ForegroundColor $(if ($nConsole -gt 3) { 'Yellow' } else { 'Gray' })
Write-Host ("Storage API : {0}" -f $nStorage) -ForegroundColor $(if ($nStorage -gt 0) { 'Yellow' } else { 'Gray' })

# --- Delta de linhas de JS contra o backup mais recente ------------------
$dir = Split-Path -Parent $Path
$bkp = Get-ChildItem -LiteralPath $dir -Filter '*.bak-*' -File -ErrorAction SilentlyContinue |
Sort-Object LastWriteTime -Descending | Select-Object -First 1

if ($bkp) {
  $htmlBkp = [IO.File]::ReadAllText($bkp.FullName)
  $limpoBkp = [regex]::Replace($htmlBkp, '<!--[\s\S]*?-->', $mask)
  $jsBkp = 0
  foreach ($b in $rxScript.Matches($limpoBkp)) {
    $trecho = $htmlBkp.Substring($b.Groups[1].Index, $b.Groups[1].Length)
    $jsBkp += ([regex]::Matches($trecho, "`n")).Count
  }
  $delta = $linhasJs - $jsBkp
  Write-Host ("Delta JS vs {0}: {1} linhas" -f $bkp.Name, $delta)
  if ($delta -lt (-1 * $MaxPerdaJs)) {
    Write-Host ("  [FALHA] perda de {0} linhas de JS excede o limite de {1}" -f (-1 * $delta), $MaxPerdaJs) -ForegroundColor Red
    $falhas++
  }
}
else {
  Write-Host 'Sem backup (*.bak-*) para comparar delta.' -ForegroundColor Gray
}

Remove-Item -LiteralPath $tmp -Recurse -Force -ErrorAction SilentlyContinue

if ($falhas -gt 0) {
  Write-Host ("`nREPROVADO - {0} falha(s)." -f $falhas) -ForegroundColor Red
  exit 1
}
Write-Host "`nAPROVADO" -ForegroundColor Green
exit 0
