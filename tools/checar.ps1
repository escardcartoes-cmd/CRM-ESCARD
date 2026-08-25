# =====================================================================
# CRM-ESCARD - Checagem do index.html
#
# 1. node --check na sintaxe dos <script> inline
# 2. Delta contra o backup MAIS RECENTE (o que a ultima alteracao criou)
# 3. git diff --stat
#
# So le. Nao altera nada. Reutilizavel a cada edicao.
# Uso: powershell -ExecutionPolicy Bypass -File tools\checar.ps1
# =====================================================================

$ErrorActionPreference = 'Stop'

$repo = 'C:\dev\CRM-ESCARD'
$alvo = Join-Path $repo 'index.html'
$tmp  = Join-Path $env:TEMP '_crm_check.js'
$erro = 0

Write-Host ''
Write-Host '=== Checagem do index.html ===' -ForegroundColor Cyan

if(-not (Test-Path $alvo)){ throw "Nao encontrei $alvo" }

function ExtrairJs($caminho){
  $h = [System.IO.File]::ReadAllText($caminho)
  $m = [regex]::Matches($h, '(?s)<script(?![^>]*src=)[^>]*>(.*?)</script>')
  $p = @()
  foreach($x in $m){ $p += $x.Groups[1].Value }
  return ($p -join "`n;`n")
}

$js = ExtrairJs $alvo
[System.IO.File]::WriteAllText($tmp, $js)

# --- 1. Sintaxe -----------------------------------------------------
Write-Host ''
Write-Host '--- Sintaxe ---' -ForegroundColor Cyan
$node = Get-Command node -ErrorAction SilentlyContinue
if(-not $node){
  Write-Host 'AVISO: node fora do PATH. Sintaxe nao verificada.' -ForegroundColor Yellow
} else {
  $s = & node --check $tmp 2>&1
  if($LASTEXITCODE -eq 0){
    Write-Host 'SINTAXE OK' -ForegroundColor Green
  } else {
    $erro++
    Write-Host 'ERRO DE SINTAXE:' -ForegroundColor Red
    $s | ForEach-Object { Write-Host $_ -ForegroundColor Red }
  }
}

# --- 2. Delta contra o backup mais recente --------------------------
Write-Host ''
Write-Host '--- Delta (o que a alteracao introduziu) ---' -ForegroundColor Cyan

$bk = Get-ChildItem $repo -Filter 'index.backup*.html' -Recurse -ErrorAction SilentlyContinue |
      Sort-Object LastWriteTime -Descending | Select-Object -First 1

if(-not $bk){
  Write-Host 'Nenhum backup encontrado. Delta nao calculado.' -ForegroundColor Yellow
} else {
  Write-Host ("Comparando com: {0}" -f $bk.Name)
  $jsA = ExtrairJs $bk.FullName

  $met = @(
    @{ n = 'arrow function  (=>)'; r = '=>' },
    @{ n = 'template literal';     r = '\x60' },
    @{ n = 'optional chain (?.)';  r = '\?\.' },
    @{ n = 'nullish (??)';         r = '\?\?' },
    @{ n = 'console.*';            r = 'console\.' },
    @{ n = 'localStorage';         r = 'localStorage|sessionStorage' }
  )

  Write-Host ''
  Write-Host ('{0,-22} {1,8} {2,8} {3,9}' -f 'Construcao','Antes','Depois','Delta') -ForegroundColor Cyan
  Write-Host ('-' * 51)

  $intro = 0
  foreach($m in $met){
    $a = ([regex]::Matches($jsA, $m.r)).Count
    $d = ([regex]::Matches($js,  $m.r)).Count
    $x = $d - $a
    if($x -gt 0){ $intro++; $cor = 'Red';   $txt = '+' + [string]$x }
    elseif($x -lt 0){       $cor = 'Green'; $txt = [string]$x }
    else {                  $cor = 'Green'; $txt = '0' }
    Write-Host ('{0,-22} {1,8} {2,8} {3,9}' -f $m.n, $a, $d, $txt) -ForegroundColor $cor
  }
  Write-Host ('-' * 51)
  $la = ($jsA -split "`n").Count
  $ld = ($js  -split "`n").Count
  Write-Host ('{0,-22} {1,8} {2,8} {3,9}' -f 'linhas de JS', $la, $ld, (('{0:+#;-#;0}') -f ($ld - $la)))

  if($intro -gt 0){ $erro++ }
}

# --- 3. Git ---------------------------------------------------------
Write-Host ''
Write-Host '--- Git ---' -ForegroundColor Cyan
Push-Location $repo
& git status -s
Write-Host ''
& git diff --stat
Pop-Location

Remove-Item $tmp -ErrorAction SilentlyContinue

Write-Host ''
if($erro -eq 0){
  Write-Host '=== APROVADO ===' -ForegroundColor Green
} else {
  Write-Host ("=== {0} PROBLEMA(S) - investigar antes de commitar ===" -f $erro) -ForegroundColor Red
}
Write-Host ''
