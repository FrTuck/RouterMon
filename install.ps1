<#
.SYNOPSIS
  Ставит RouterMon (дашборд ресурсов роутеров) на роутер с OpenWrt: http://<IP роутера>:8089/
  Работает на любом ПК с Windows 10/11 (встроенные PowerShell 5.1, ssh и tar) и в PowerShell 7 на Linux/macOS.

  Без параметров спрашивает IP основного роутера (по умолчанию — шлюз этого ПК), ставит RouterMon на него,
  затем ищет в локальной сети другие роутеры с OpenWrt и предлагает поставить и на них.
  Остальные роутеры можно добавить и позже — на странице кнопкой «+ Добавить роутер».
.PARAMETER Hosts
  IP роутера (или нескольких). Если не указать — спросит.
.PARAMETER Key
  Файл закрытого ключа SSH. Если не указать — пробуются все ключи ~/.ssh/id_*, затем ssh спросит пароль root.
.PARAMETER NoScan
  Не искать другие роутеры после установки.
.EXAMPLE
  .\install.ps1                              # спросит IP, предложит шлюз ПК
  .\install.ps1 -Hosts 192.168.1.1           # на один роутер
  .\install.ps1 -Hosts 192.168.1.1,192.168.1.2 -Key ~\.ssh\my_router_key
  .\install.ps1 -Hosts 192.168.1.1 -Uninstall
#>
param([string[]]$Hosts, [string]$Key, [int]$Port = 8089, [switch]$Uninstall, [switch]$NoScan)
$ErrorActionPreference = 'Stop'
$Root = Split-Path -Parent $MyInvocation.MyCommand.Path
$Web = Join-Path $Root 'web'
$IsWin = [Environment]::OSVersion.Platform -eq 'Win32NT'

foreach ($tool in 'ssh', 'tar') {
  if (-not (Get-Command $tool -ErrorAction SilentlyContinue)) {
    throw "Не найдена программа '$tool'. В Windows 10/11 включите «Клиент OpenSSH» (Параметры → Приложения → Дополнительные компоненты)."
  }
}

# шлюз по умолчанию этого ПК — обычно это и есть основной роутер
function Get-Gateway {
  try {
    if ($IsWin) {
      $r = Get-NetRoute -DestinationPrefix '0.0.0.0/0' -ErrorAction Stop | Sort-Object { $_.RouteMetric + $_.InterfaceMetric } | Select-Object -First 1
      if ($r) { return $r.NextHop }
    } else {
      $g = sh -c "ip route show default 2>/dev/null | awk '{print `$3; exit}'; route -n get default 2>/dev/null | awk '/gateway:/ {print `$2}'"
      if ($g) { return @($g)[0] }
    }
  } catch { }
  return $null
}

if (-not $Hosts) {
  $gw = Get-Gateway
  $prompt = if ($gw) { "IP основного роутера с OpenWrt [$gw]" } else { 'IP основного роутера с OpenWrt' }
  $in = Read-Host $prompt
  if (-not $in -and $gw) { $in = $gw }
  $Hosts = @($in -split '[,; ]+' | Where-Object { $_ })
  if (-not $Hosts) { return }
}

# ключи: указанный или все ~/.ssh/id_* (кроме .pub); если ни один не подойдёт, ssh спросит пароль
$sshArgs = @('-o', 'ConnectTimeout=10', '-o', 'StrictHostKeyChecking=accept-new')
$keys = @()
if ($Key) { $keys = @((Resolve-Path $Key).Path) }
else {
  $sshDir = Join-Path $HOME '.ssh'
  if (Test-Path $sshDir) { $keys = @(Get-ChildItem $sshDir -File -Filter 'id_*' | Where-Object { $_.Extension -ne '.pub' } | ForEach-Object { $_.FullName }) }
}
foreach ($k in $keys) { $sshArgs += @('-i', $k) }

function Quote([string]$s) { if ($s -match '[\s"]') { '"' + $s + '"' } else { $s } }
# ssh root@<h> <команда>, stdin — файл (бинарно, без перекодировки PowerShell)
function Invoke-Ssh([string]$H, [string]$Cmd, [string]$StdinFile) {
  $argLine = (($sshArgs | ForEach-Object { Quote $_ }) -join ' ') + " root@$H " + '"' + $Cmd + '"'
  if ($IsWin) {
    $redir = if ($StdinFile) { " < `"$StdinFile`"" } else { '' }
    $out = cmd /c "ssh $argLine$redir 2>&1"
  } else {
    $redir = if ($StdinFile) { " < '$StdinFile'" } else { '' }
    $out = sh -c "ssh $argLine$redir 2>&1"
  }
  @{ Code = $LASTEXITCODE; Out = ($out -join "`n") }
}

if ($Uninstall) {
  foreach ($h in $Hosts) {
    $r = Invoke-Ssh $h 'sh /etc/rmon-web/lib/setup.sh remove'
    if ($r.Out -match 'REMOVED') { Write-Host "${h}: RouterMon удалён" -ForegroundColor Yellow } else { Write-Warning "${h}: $($r.Out)" }
  }
  return
}

# сборка пакета: все текстовые файлы с переводами строк LF
$stage = Join-Path ([IO.Path]::GetTempPath()) "rmon-web-$PID"
Remove-Item $stage -Recurse -Force -ErrorAction SilentlyContinue
New-Item -ItemType Directory -Force $stage | Out-Null
$utf8 = New-Object Text.UTF8Encoding $false
$webFull = (Resolve-Path $Web).Path.TrimEnd('\', '/')
foreach ($f in Get-ChildItem $Web -Recurse -File) {
  $rel = $f.FullName.Substring($webFull.Length + 1)
  $t = Join-Path $stage $rel
  New-Item -ItemType Directory -Force (Split-Path $t) | Out-Null
  [IO.File]::WriteAllText($t, ([IO.File]::ReadAllText($f.FullName) -replace "`r`n", "`n"), $utf8)
}
$tarFile = "$stage.tar"
& tar -cf $tarFile -C $stage . ; if ($LASTEXITCODE) { throw 'tar не сработал' }

# одно подключение на роутер: распаковать пакет и запустить установку (пароль, если нужен, спросят один раз).
# $Neighbors — все роутеры этой установки: каждый запишет остальных в свой список, чтобы видеть их сразу
function Install-Routers([string[]]$List, [string[]]$Neighbors) {
  $cmd = "rm -rf /tmp/rmon-inst && mkdir -p /tmp/rmon-inst && tar -xf - -C /tmp/rmon-inst && sh /tmp/rmon-inst/lib/setup.sh install $Port - $($Neighbors -join ' ')"
  $done = @()
  foreach ($h in $List) {
    Write-Host "${h}: устанавливаю… (если спросит — пароль root этого роутера)"
    $r = Invoke-Ssh $h $cmd $tarFile
    if ($r.Out -match 'INSTALLED') { $done += $h; Write-Host "${h}: готово — http://${h}:$Port/" -ForegroundColor Green }
    else {
      $e = ($r.Out -split "`n" | Where-Object { $_ -match '^ERR ' } | Select-Object -Last 1)
      if ($e) { Write-Warning "${h}: $($e.Substring(4))" } else { Write-Warning "${h}: не удалось ($($r.Out))" }
    }
  }
  return ,$done
}

try {
  $ok = Install-Routers $Hosts $Hosts
  # другие роутеры OpenWrt в сети: спрашиваем у только что установленного (он видит соседей в своей ARP-таблице)
  if ($ok.Count -and -not $NoScan) {
    Write-Host "`nИщу другие роутеры с OpenWrt в локальной сети…"
    $found = @()
    try {
      $j = Invoke-RestMethod -Uri "http://$($ok[0]):$Port/cgi-bin/api?a=scan" -TimeoutSec 30
      $found = @($j.found | ForEach-Object { $_.ip } | Where-Object { $Hosts -notcontains $_ })
    } catch { Write-Warning "Поиск не удался: $($_.Exception.Message)" }
    if ($found.Count) {
      Write-Host "Найдены роутеры с OpenWrt без RouterMon: $($found -join ', ')"
      $a = Read-Host 'Поставить RouterMon и на них? Для каждого понадобится пароль root [Y/n]'
      if ($a -notmatch '^[nNнН]') {
        $more = Install-Routers $found ($Hosts + $found)
        $ok += $more
      } else { Write-Host 'Их можно добавить позже на странице: «+ Добавить роутер» → «Найдены в сети».' }
    } else { Write-Host 'Других роутеров с OpenWrt без RouterMon не найдено.' }
  }
} finally { Remove-Item $stage, $tarFile -Recurse -Force -ErrorAction SilentlyContinue }
if ($ok.Count) { Write-Host "`nОткройте http://$($ok[0]):$Port/ — другие роутеры добавляются там кнопкой «+ Добавить роутер»." -ForegroundColor Cyan }
