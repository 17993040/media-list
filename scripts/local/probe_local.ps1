# probe_local.ps1
# 本地全量深度测（抽帧终审）+ 主备线裁决
# 规则：
#   1. 有画面（ffmpeg 出图 ≥5KB）才算通过
#   2. 同一 host 串行测，不同 host 并发（避免 38.64 这类源站被并发压垮）
#   3. 主线挂 → 从备线里挑活的顶上；旧主线降为备线；备线超 3 条丢最老的（本地有删除权）
#   4. 主线挂且备线全死 → 主线清空，标〔待补〕

param(
  [string]$Root = (Split-Path (Split-Path $PSScriptRoot -Parent) -Parent),
  [int]$Workers = 5,
  [string]$FF = 'C:\Users\Administrator\Desktop\影视维护\tools\ffmpeg-9.1-essentials_build\bin\ffmpeg.exe'
)

$ErrorActionPreference = 'Continue'
$UA = 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 Chrome/120.0 Safari/537.36'
$cfgPath = Join-Path $Root 'config\channels.json'
$outDir = Join-Path $Root 'out'
$tmpRoot = Join-Path $env:TEMP 'local_probe'
if (Test-Path $tmpRoot) { Remove-Item $tmpRoot -Recurse -Force -ErrorAction SilentlyContinue }
New-Item -ItemType Directory -Path $tmpRoot -Force | Out-Null

$cfg = Get-Content -LiteralPath $cfgPath -Raw -Encoding UTF8 | ConvertFrom-Json
$chs = $cfg.channels

# ---------- 收集待测项 ----------
$items = @()
foreach ($c in $chs) {
  foreach ($u in @($c.main) + @($c.backup)) {
    if (-not $u) { continue }
    if ($u -match '0\.0\.0\.0:1') { continue }
    $h = '?'
    try { $h = ([Uri]$u).Host } catch { }
    $items += [pscustomobject]@{ seq = $c.seq; name = $c.name; group = $c.group; url = $u; host = $h; isMain = ($u -eq $c.main) }
  }
}
Write-Output ("待测 " + $items.Count + " 条  覆盖 " + (@($items | Select-Object -ExpandProperty seq -Unique).Count) + " 台")

$sbHost = {
  param($batch, $ua, $ff, $tmpRoot)

  function ProbeOne($u) {
    $fid = [guid]::NewGuid().ToString('N')
    $img = Join-Path $tmpRoot ($fid + '.jpg')
    $p = Start-Process -FilePath $ff -ArgumentList @(
      '-y', '-nostdin', '-loglevel', 'error', '-rw_timeout', '25000000',
      '-i', $u, '-t', '12', '-vf', 'fps=1,scale=400:-1', '-frames:v', '1', $img
    ) -NoNewWindow -PassThru -RedirectStandardError ($img + '.err') -RedirectStandardOutput ($img + '.out')
    $done = $p.WaitForExit(45000)
    if (-not $done) { try { $p.Kill() } catch { } ; return @{ ok = $false; why = 'timeout'; size = 0 } }
    $sz = 0
    if (Test-Path $img) { $sz = (Get-Item $img).Length }
    if ($sz -ge 5120) { return @{ ok = $true; why = 'frame'; size = $sz } }
    $note = ''
    if ($sz -gt 0) { $note = 'tiny' } else { $note = 'noimg' }
    return @{ ok = $false; why = $note; size = $sz }
  }

  $out = @()
  foreach ($it in $batch) {
    $r = ProbeOne $it.url
    $out += [pscustomobject]@{ url = $it.url; seq = $it.seq; ok = $r.ok; why = $r.why; size = $r.size }
  }
  return $out
}

# ---------- 按 host 分组，host 内串行，host 间并发 ----------
$byHost = $items | Group-Object host
Write-Output ("源站 " + $byHost.Count + " 个，并发 " + $Workers)

$pool = [runspacefactory]::CreateRunspacePool(1, $Workers); $pool.Open()
$jobs = @()
foreach ($hg in $byHost) {
  $ps = [powershell]::Create().AddScript($sbHost).AddArgument($hg.Group).AddArgument($UA).AddArgument($FF).AddArgument($tmpRoot)
  $ps.RunspacePool = $pool
  $jobs += [pscustomobject]@{ ps = $ps; h = $ps.BeginInvoke(); host = $hg.Name; cnt = $hg.Count }
}

$results = @()
$done = 0
$total = $items.Count
foreach ($j in $jobs) {
  $o = @()
  foreach ($r in $j.ps.EndInvoke($j.h)) { if ($r) { $o += $r } }
  $j.ps.Dispose()
  $results += $o
  $done += $o.Count
  Write-Output ("  [" + $done + "/" + $total + "] " + $j.host + " " + @($o | Where-Object { $_.ok }).Count + "/" + $j.cnt + " 通")
}
$pool.Close(); $pool.Dispose()
Remove-Item $tmpRoot -Recurse -Force -ErrorAction SilentlyContinue

# ---------- 裁决 ----------
$bySeq = @{}
foreach ($r in $results) {
  if (-not $bySeq.ContainsKey($r.seq)) { $bySeq[$r.seq] = @() }
  $bySeq[$r.seq] += $r
}

$ts = Get-Date -Format 'yyyy-MM-dd HH:mm:ss'
$report = New-Object System.Text.StringBuilder
[void]$report.AppendLine("# 本地全量测 $ts")
[void]$report.AppendLine("# 格式: 组 | 台 | 状态 | 主线 | 备线数 | 说明")

$changed = 0
foreach ($c in $chs) {
  if (-not $c.main -and $c.backup.Count -eq 0) {
    $c.local = 'none'
    [void]$report.AppendLine(("{0} | {1} | 待补 | - | 0 | 无任何源" -f $c.group, $c.name))
    continue
  }

  $res = if ($bySeq.ContainsKey($c.seq)) { $bySeq[$c.seq] } else { @() }
  $mainRes = $res | Where-Object { $_.url -eq $c.main }
  $mainOk = $mainRes -and $mainRes.ok

  if (-not $mainOk) {
    # 从备线里找一个活的
    $liveBk = $null
    foreach ($b in @($c.backup)) {
      $br = $res | Where-Object { $_.url -eq $b -and $_.ok }
      if ($br) { $liveBk = $b; break }
    }
    if ($liveBk) {
      $old = $c.main
      $c.main = $liveBk
      $bk = @($c.backup | Where-Object { $_ -ne $liveBk })
      if ($old) { $bk = @($bk) + $old }
      if ($bk.Count -gt 3) { $bk = $bk | Select-Object -First 3 }
      $c.backup = @($bk)
      $c.local = 'ok'
      $c.failCount = 0
      $c.note = '主线失效，备线顶上'
      $changed++
      [void]$report.AppendLine(("{0} | {1} | 备线顶上 | {2} | {3} | 旧主线已降备" -f $c.group, $c.name, $c.main, $c.backup.Count))
    } else {
      # 主备全没活：不清空、不删源，累计失败次数，连续 3 轮才转待补
      $fc = 0
      if ($c.PSObject.Properties['failCount']) { $fc = [int]$c.failCount }
      $fc++
      $c | Add-Member -NotePropertyName failCount -NotePropertyValue $fc -Force
      if ($fc -ge 3) {
        $old = $c.main
        # 三次连续失败：这是本地全量测执行删除的唯一时机
        $c.main = ''
        $c.backup = @()
        $c.local = 'none'
        $c.note = '连续3轮失效，已清空（本轮执行删除）'
        $changed++
        [void]$report.AppendLine(("{0} | {1} | 清空转待补 | - | 0 | 连续3轮失效，原主线 {2}" -f $c.group, $c.name, $old))
      } else {
        $c.local = 'fail'
        $c.note = ('本次未通过，保留观察 ' + $fc + '/3')
        [void]$report.AppendLine(("{0} | {1} | 观察 | {2} | {3} | 第 {4} 次失败，源保留未删" -f $c.group, $c.name, $c.main, $c.backup.Count, $fc))
      }
    }
  } else {
    $c.local = 'ok'
    $c.failCount = 0
    $c.lastLocal = $ts
    $c.note = ''
    [void]$report.AppendLine(("{0} | {1} | 通 | {2} | {3} | {4}B" -f $c.group, $c.name, $c.main, $c.backup.Count, $mainRes.size))
  }
}

$cfg.updated = $ts
[IO.File]::WriteAllText($cfgPath, ($cfg | ConvertTo-Json -Depth 8), (New-Object Text.UTF8Encoding($false)))
[IO.File]::WriteAllText((Join-Path $outDir '_local_probe.txt'), $report.ToString(), (New-Object Text.UTF8Encoding($false)))

# ---------- 重新输出 m3u ----------
$live = New-Object System.Text.StringBuilder
[void]$live.AppendLine('#EXTM3U')
$bck = New-Object System.Text.StringBuilder
[void]$bck.AppendLine('#EXTM3U')
$okN = 0; $noneN = 0
foreach ($c in $chs) {
  $label = $c.name
  if (-not $c.main) { $label = $c.name + '〔待补〕'; $noneN++ }
  else {
    if ($c.cloud -eq 'ok') { $label = $c.name + '[华为云已测]' }
    $okN++
  }
  $u = if ($c.main) { $c.main } else { 'http://0.0.0.0:1/void.m3u8' }
  [void]$live.AppendLine('#EXTINF:-1 group-title="' + $c.group + '",' + $label)
  [void]$live.AppendLine($u)
  foreach ($b in @($c.backup)) {
    if (-not $b) { continue }
    [void]$bck.AppendLine('#EXTINF:-1 group-title="' + $c.group + '",' + $c.name + '〔备〕')
    [void]$bck.AppendLine($b)
  }
}
[IO.File]::WriteAllText((Join-Path $outDir 'live.m3u'), $live.ToString(), (New-Object Text.UTF8Encoding($false)))
[IO.File]::WriteAllText((Join-Path $outDir 'backup.m3u'), $bck.ToString(), (New-Object Text.UTF8Encoding($false)))

Write-Output ""
Write-Output ("=== 本地测结果 ===")
$okN = @($chs | Where-Object { $_.local -eq 'ok' }).Count
$failN = @($chs | Where-Object { $_.local -eq 'fail' }).Count
$noneN = @($chs | Where-Object { -not $_.main }).Count
Write-Output ("固定台 " + $chs.Count + "  本轮通过 " + $okN + "  观察中 " + $failN + "  待补 " + $noneN + "  变动 " + $changed)
foreach ($g in $chs | Group-Object group) {
  $go = @($g.Group | Where-Object { $_.local -eq 'ok' }).Count
  $gf = @($g.Group | Where-Object { $_.local -eq 'fail' }).Count
  $gn = @($g.Group | Where-Object { -not $_.main }).Count
  Write-Output ("  " + $g.Name + ": 通过 " + $go + " / 观察 " + $gf + " / 待补 " + $gn)
}
Write-Output ""
Write-Output ("明细: " + (Join-Path $outDir '_local_probe.txt'))
Write-Output ("清单: " + (Join-Path $outDir 'live.m3u'))
