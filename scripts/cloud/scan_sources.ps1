# scan_sources.ps1
# GitHub Actions 每日 3:00 跑：探接口式找源（枚举源站编号，不下载别人的成品清单）
# 输出：out\candidates.json（有台名映射的候选，可进备线池）+ out\pending.m3u（未认台的编号）
# 特点：同一 host 串行，host 之间并发；只做快速判活，抽帧终审交给华为云

param(
  [string]$Root = (Split-Path $PSScriptRoot -Parent | Split-Path -Parent),
  [int]$Throttle = 6,
  [int]$MinSegBytes = 8192
)

$ErrorActionPreference = 'Continue'
$UA = 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 Chrome/120.0 Safari/537.36'
$cfgDir = Join-Path $Root 'config'
$outDir = Join-Path $Root 'out'
if (-not (Test-Path $outDir)) { New-Item -ItemType Directory -Path $outDir -Force | Out-Null }

$stations = (Get-Content -LiteralPath (Join-Path $cfgDir 'stations.json') -Raw -Encoding UTF8 | ConvertFrom-Json).stations
$mapObj = (Get-Content -LiteralPath (Join-Path $cfgDir 'station_map.json') -Raw -Encoding UTF8 | ConvertFrom-Json).map

# ---------- 1. 生成待扫清单 ----------
$targets = @()
foreach ($st in $stations) {
  if (-not ($st.enabled -eq $true)) { continue }
  $start = [int]$st.from
  $end = [int]$st.to
  $pad = [int]$st.pad
  $step = if ($st.step) { [int]$st.step } else { 1 }
  for ($i = $start; $i -le $end; $i += $step) {
    $id = $i.ToString().PadLeft($pad, '0')
    $targets += [pscustomobject]@{
      station = $st.key
      sname   = $st.name
      id      = $id
      url     = ($st.base -replace '{id}', $id)
    }
  }
}
Write-Output ("待扫 " + $targets.Count + " 个编号，源站 " + $stations.Count + " 个")

# ---------- 2. 按 host 分组 ----------
$byHost = $targets | Group-Object { try { ([Uri]$_.url).Host } catch { '?' } }

$sb = {
  param($batch, $ua, $minSeg)

  function Fetch($url, $t, $out, $range) {
    $a = @('-sS', '-L', '-m', "$t", '-A', $ua, '-o', $out, '-w', '%{http_code}|%{size_download}')
    if ($range) { $a += @('-r', $range) }
    $a += $url
    $o = & curl.exe @a 2>$null
    $c = 0; $s = 0
    if ($o -match '^(\d+)\|(\d+)$') { $c = [int]$Matches[1]; $s = [int64]$Matches[2] }
    elseif ($o -match '^(\d+)\|') { $c = [int]$Matches[1] }
    return [pscustomobject]@{ code = $c; size = $s }
  }

  $tmp = Join-Path $env:TEMP ('scan_' + [guid]::NewGuid().ToString('N'))
  New-Item -ItemType Directory -Path $tmp -Force | Out-Null

  function CheckOne($t) {
    $u = $t.url
    $segs = @()
    $okPlaylist = $false
    # master 逐层降：最多 3 层，直到拿到 media playlist
    for ($depth = 0; $depth -lt 3; $depth++) {
      $f1 = Join-Path $tmp ('m_' + [guid]::NewGuid().ToString('N') + '.bin')
      $h = Fetch $u 7 $f1 $null
      if ($h.code -ne 200 -and $h.code -ne 206) { return $null }
      if (-not (Test-Path $f1)) { return $null }
      $txt = [IO.File]::ReadAllText($f1)
      if (-not $txt.Contains('#EXTM3U')) { return $null }
      $segs = @()
      foreach ($ln in ($txt -split "`n")) { $x = $ln.Trim(); if ($x -ne '' -and -not $x.StartsWith('#')) { $segs += $x } }
      if ($segs.Count -eq 0) { return $null }
      if ($txt.Contains('#EXT-X-STREAM-INF')) {
        $nu = $segs[0]
        if ($nu -notmatch '^http') { try { $nu = ([Uri]::new([Uri]$u, $nu)).AbsoluteUri } catch { return $null } }
        $u = $nu
        continue
      }
      $okPlaylist = $true
      break
    }
    if (-not $okPlaylist) { return $null }

    $su = $segs[0]
    if ($su -notmatch '^http') { try { $su = ([Uri]::new([Uri]$u, $su)).AbsoluteUri } catch { return $null } }
    $f2 = Join-Path $tmp ('s_' + [guid]::NewGuid().ToString('N') + '.bin')
    $d = Fetch $su 8 $f2 '0-1048575'
    if ($d.size -lt $minSeg) { return $null }
    return [pscustomobject]@{ station = $t.station; id = $t.id; url = $t.url; size = $d.size; segs = $segs.Count }
  }

  $ok = @()
  foreach ($t in $batch) {
    $r = CheckOne $t
    if ($r) { $ok += $r }
  }
  Remove-Item $tmp -Recurse -Force -ErrorAction SilentlyContinue
  return $ok
}

$pool = [runspacefactory]::CreateRunspacePool(1, $Throttle); $pool.Open()
$jobs = @()
foreach ($hg in $byHost) {
  $ps = [powershell]::Create().AddScript($sb).AddArgument($hg.Group).AddArgument($UA).AddArgument($MinSegBytes)
  $ps.RunspacePool = $pool
  $jobs += [pscustomobject]@{ ps = $ps; h = $ps.BeginInvoke(); host = $hg.Name; cnt = $hg.Count }
}
$alive = @()
$done = 0
foreach ($j in $jobs) {
  $o = @()
  foreach ($r in $j.ps.EndInvoke($j.h)) { if ($r) { $o += $r } }
  $j.ps.Dispose()
  $alive += $o
  $done += $j.cnt
  Write-Output ("  [" + $done + "/" + $targets.Count + "] " + $j.host + " 活 " + $o.Count + "/" + $j.cnt)
}
$pool.Close(); $pool.Dispose()

# ---------- 3. 映射台名 ----------
$cand = @()
$pend = @()
foreach ($a in $alive) {
  $nm = $null
  if ($mapObj.PSObject.Properties[$a.station]) {
    $sm = $mapObj.($a.station)
    if ($sm.PSObject.Properties[$a.id]) { $nm = $sm.($a.id) }
  }
  if ($nm) {
    $cand += [pscustomobject]@{ name = $nm; url = $a.url; station = $a.station; id = $a.id; size = $a.size }
  } else {
    $pend += [pscustomobject]@{ station = $a.station; id = $a.id; url = $a.url; size = $a.size }
  }
}

$ts = Get-Date -Format 'yyyy-MM-dd HH:mm:ss'
$res = [pscustomobject]@{
  ts         = $ts
  scanned    = $targets.Count
  alive      = $alive.Count
  candidates = $cand
  pending    = $pend
}
[IO.File]::WriteAllText((Join-Path $outDir 'candidates.json'), ($res | ConvertTo-Json -Depth 5), (New-Object Text.UTF8Encoding($false)))

# pending.m3u 追加（保留历史，不覆盖）
$pendPath = Join-Path $outDir 'pending.m3u'
$hist = @()
if (Test-Path $pendPath) { $hist = Get-Content -LiteralPath $pendPath -Encoding UTF8 }
$sbp = New-Object System.Text.StringBuilder
foreach ($h in $hist) { if ($h.Trim() -ne '' -and $h -notmatch '^#EXTM3U') { [void]$sbp.AppendLine($h) } }
foreach ($p in $pend) {
  [void]$sbp.AppendLine('#EXTINF:-1 group-title="待认台",' + $p.station + '-' + $p.id)
  [void]$sbp.AppendLine($p.url)
}
$head = "#EXTM3U`n"
[IO.File]::WriteAllText($pendPath, ($head + $sbp.ToString()), (New-Object Text.UTF8Encoding($false)))

Write-Output ""
Write-Output ("=== 扫源结果 " + $ts + " ===")
Write-Output ("扫描 " + $targets.Count + "  活 " + $alive.Count + "  认出台 " + $cand.Count + "  待认台 " + $pend.Count)
$cand | Group-Object name | Sort-Object Name | ForEach-Object { Write-Output ("  " + $_.Name + " : " + $_.Count + " 条") }
Write-Output ("输出: " + (Join-Path $outDir 'candidates.json'))
