# publish.ps1
# 每日 5:00 发布：把 channels.json 变成 App 订阅的两份清单，并生成微信摘要
# 只改 live-all3.m3u / live-all3-full.m3u，不碰两个点播 JSON（点播由云端维护）

param(
  [string]$Root = (Split-Path $PSScriptRoot -Parent)
)

$ErrorActionPreference = 'Stop'
$cfgPath = Join-Path $Root 'config/channels.json'
$outDir = Join-Path $Root 'out'
if (-not (Test-Path $outDir)) { New-Item -ItemType Directory -Path $outDir -Force | Out-Null }

if (-not (Test-Path -LiteralPath $cfgPath)) { throw "找不到 $cfgPath" }
$cfg = Get-Content -LiteralPath $cfgPath -Raw -Encoding UTF8 | ConvertFrom-Json
$chs = $cfg.channels
if (-not $chs) { throw 'channels.json 缺少 channels 字段' }

# ---------- 1. 读上一版清单，用于算新增 / 删除 / 换线 ----------
$prevMap = @{}
$prevPath = Join-Path $Root 'live-all3.m3u'
if (Test-Path -LiteralPath $prevPath) {
  $nm = ''
  foreach ($l in (Get-Content -LiteralPath $prevPath -Encoding UTF8)) {
    if ($l -match '^#EXTINF') {
      $nm = ($l -replace '^#EXTINF[^,]*,', '').Trim()
      $nm = $nm -replace '\[华为云已测\]', '' -replace '〔待补〕', '' -replace '〔备〕', ''
    } elseif ($l -notmatch '^#' -and $l.Trim() -match '^http') {
      if ($nm) { $prevMap[$nm] = $l.Trim() }
      $nm = ''
    }
  }
}

# ---------- 2. 生成两份清单 ----------
# 主清单：每台 1 条，只放当前能用的（main 优先，main 空则拿第一条备线顶上）
# 全量清单：同名同 tvg-id 多线路（1 主 + 最多 2 备），供 OK影视 聚合切线路
function Get-Label($c) {
  $hasBackup = @($c.backup | Where-Object { $_ }).Count -gt 0
  if (-not $c.main -and -not $hasBackup) { return ($c.name + '〔待补〕') }
  if (($c.cloud -eq 'fail' -or ($c.note -match '待补')) -and -not $hasBackup) { return ($c.name + '〔待补〕') }
  if ($c.cloud -eq 'ok') { return ($c.name + '[华为云已测]') }
  return $c.name
}

$sbMain = New-Object System.Text.StringBuilder
[void]$sbMain.Append("#EXTM3U`n")
$sbFull = New-Object System.Text.StringBuilder
[void]$sbFull.Append("#EXTM3U`n")

$newMap = @{}
$relinked = @()
$fullLines = 0
$multiLineChs = 0
foreach ($c in $chs) {
  # 主线选线：main 有就用；main 空则拿第一条备线顶上，避免清单里出现死条目
  $liveUrl = $null
  if ($c.main) { $liveUrl = [string]$c.main }
  # 云端判死的主线：发布时直接用第一条备线顶上，别把死链放进主清单
  if ((-not $c.main) -or ($c.cloud -eq 'fail')) {
    foreach ($b in @($c.backup)) { if ($b) { $liveUrl = [string]$b; break } }
  }

  $label = Get-Label $c
  $uMain = if ($liveUrl) { $liveUrl } else { 'http://0.0.0.0:1/void.m3u8' }
  [void]$sbMain.Append("#EXTINF:-1 group-title=`"$($c.group)`",$label`n$uMain`n")

  $newMap[$c.name] = [string]$liveUrl
  if ($prevMap.ContainsKey($c.name) -and $liveUrl -and $prevMap[$c.name] -ne [string]$liveUrl) {
    $relinked += $c.name
  }

  # 全量清单：同一个台的所有线同名、同 tvg-id，播放器才会聚合成"线路 1/2/3"
  $tid = 'ch' + ('{0:D3}' -f [int]$c.seq)
  $urls = @()
  if ($liveUrl) { $urls += $liveUrl }
  foreach ($b in @($c.backup)) {
    if (-not $b) { continue }
    if ($urls.Count -ge 5) { break }
    $urls += [string]$b
  }
  # 主线被判死、备线顶上时，旧主线也留在全量里当一条备选（总上限 5 条）
  if ($c.main -and $c.main -ne $liveUrl -and $urls.Count -lt 5) {
    $urls += [string]$c.main
  }
  $seen = @{}
  $uniq = @()
  foreach ($x in $urls) {
    if ($x -and -not $seen.ContainsKey($x)) { $seen[$x] = 1; $uniq += $x }
  }
  if (-not $uniq) { $uniq = @('http://0.0.0.0:1/void.m3u8') }
  if ($uniq.Count -gt 1) { $multiLineChs++ }
  foreach ($x in $uniq) {
    [void]$sbFull.Append("#EXTINF:-1 tvg-id=`"$tid`" tvg-name=`"$($c.name)`" group-title=`"$($c.group)`",$($c.name)`n$x`n")
    $fullLines++
  }
}

# 保险：台数明显异常就不覆盖，保留上一版清单
if ($chs.Count -lt 70) { throw ("台数异常（$($chs.Count) 台，低于 70），不覆盖现有清单") }

[IO.File]::WriteAllText((Join-Path $Root 'live-all3.m3u'), $sbMain.ToString(), [Text.UTF8Encoding]::new($false))
[IO.File]::WriteAllText((Join-Path $Root 'live-all3-full.m3u'), $sbFull.ToString(), [Text.UTF8Encoding]::new($false))

# ---------- 3. 统计 ----------
$total = $chs.Count
$hasSrc = @($chs | Where-Object { $_.main }).Count
$pending = $total - $hasSrc
$markedOk = @($chs | Where-Object { $_.cloud -eq 'ok' }).Count

$g = @{}
foreach ($c in ($chs | Group-Object group)) { $g[$c.Name] = $c.Count }

$addedNames = @()
$removedNames = @()
if ($prevMap.Count -gt 0) {
  $addedNames = @($chs | Where-Object { -not $prevMap.ContainsKey($_.name) } | ForEach-Object { $_.name })
  $removedNames = @($prevMap.Keys | Where-Object { -not $newMap.ContainsKey($_) })
}

# ---------- 4. 云端 / 扫源 / 点播数据 ----------
$rep = $null
$repPath = Join-Path $outDir 'cloud-report.json'
if (Test-Path -LiteralPath $repPath) {
  try { $rep = Get-Content -LiteralPath $repPath -Raw -Encoding UTF8 | ConvertFrom-Json } catch { $rep = $null }
}

$nowBj = [datetime]::UtcNow.AddHours(8)
$todayBj = $nowBj.ToString('yyyy-MM-dd')

$cloudFresh = $false
$cloudTime = ''
$cloudAge = ''
if ($rep -and $rep.ts) {
  try {
    $raw = $rep.ts
    if ($raw -is [datetime]) {
      $utc = if ($raw.Kind -eq [DateTimeKind]::Local) { $raw.ToUniversalTime() }
             elseif ($raw.Kind -eq [DateTimeKind]::Utc) { $raw }
             else { [datetime]::SpecifyKind($raw, [DateTimeKind]::Utc) }
    } else {
      $utc = [datetime]::Parse([string]$raw, [Globalization.CultureInfo]::InvariantCulture,
        ([Globalization.DateTimeStyles]::AssumeUniversal -bor [Globalization.DateTimeStyles]::AdjustToUniversal))
    }
    $bj = $utc.AddHours(8)
    $cloudTime = $bj.ToString('HH:mm')
    $mins = ($nowBj - $bj).TotalMinutes
    # 发布应在云测之后，且相隔不超过 3 小时；早于云测或过久都视为不可信
    $cloudFresh = ($mins -ge -5 -and $mins -le 180)
    if ($mins -ge 0) {
      $cloudAge = if ($mins -lt 60) { "{0} 分钟前" -f [int]$mins } else { "{0} 小时前" -f [math]::Round($mins / 60, 1) }
    }
  } catch { $cloudFresh = $false }
}

$scanTotal = 0; $scanAlive = 0; $scanCand = 0
$candPath = Join-Path $outDir 'candidates.json'
if (Test-Path -LiteralPath $candPath) {
  try {
    $cj = Get-Content -LiteralPath $candPath -Raw -Encoding UTF8 | ConvertFrom-Json
    if ($cj.candidates) { $scanCand = @($cj.candidates).Count }
    if ($cj.scanned) { $scanTotal = [int]$cj.scanned }
    if ($cj.alive) { $scanAlive = [int]$cj.alive }
    if ($cj.stats) {
      if ($cj.stats.scanned) { $scanTotal = [int]$cj.stats.scanned }
      if ($cj.stats.alive) { $scanAlive = [int]$cj.stats.alive }
    }
  } catch { }
}

$vodTotal = 0; $vodPass = 0; $vodDeleted = @(); $vodDryRun = $true
if ($rep -and $rep.vod) {
  $vodTotal = [int]$rep.vod.total
  $vodPass = [int]$rep.vod.pass
  $vodDryRun = [bool]$rep.vod.dryRun
  if ($rep.vod.deleted) { $vodDeleted = @($rep.vod.deleted) }
}
if (-not $vodTotal) {
  try {
    $lj = Get-Content -LiteralPath (Join-Path $Root 'libretv-sub3.json') -Raw -Encoding UTF8 | ConvertFrom-Json
    if ($lj.sources) { $vodTotal = @($lj.sources).Count }
  } catch { }
}

# ---------- 5. 通知文本 ----------
$sbNote = New-Object System.Text.StringBuilder
[void]$sbNote.Append("【本次补源报告】$($nowBj.ToString('yyyy-MM-dd HH:mm'))（北京时间）`n")
[void]$sbNote.Append("直播总数：$total 台（有源 $hasSrc / 待补 $pending）`n")
[void]$sbNote.Append("新增直播：$($addedNames.Count) 条  删除直播：$($removedNames.Count) 条  换线 $($relinked.Count) 台`n")
[void]$sbNote.Append("点播源：共 $vodTotal 个    新增 0 个    剔除 $($vodDeleted.Count) 个`n")

if ($rep -and $cloudFresh) {
  $cloudFail = [int]$rep.scanned - [int]$rep.pass
  [void]$sbNote.Append("云测 $cloudTime（候选 $($rep.scanned) / 通过 $($rep.pass) / 判死 $cloudFail，$cloudAge完成）`n")
} elseif ($rep) {
  [void]$sbNote.Append("云测未回写：最新报告停在 $cloudTime$(if($cloudAge){"（$cloudAge）"})，本次沿用旧配置`n")
} else {
  [void]$sbNote.Append("云测未回写：没有找到云端报告，本次沿用旧配置`n")
}

if ($scanCand -or $scanTotal) {
  [void]$sbNote.Append("扫源 03:00：编号 $scanTotal / 活源 $scanAlive / 候选 $scanCand`n")
}

# 台标鉴定（本机打分，>=8 分自动转正；只在有结果/该提醒时出一行）
$logoStatePath = Join-Path $outDir 'logo-score\state.json'
if (Test-Path $logoStatePath) {
  try {
    $ls = Get-Content -LiteralPath $logoStatePath -Raw -Encoding UTF8 | ConvertFrom-Json
    $lsAgeH = ((Get-Date).ToUniversalTime() - ([datetimeoffset]::Parse($ls.updated)).UtcDateTime).TotalHours
    $lAp = [int]$ls.autoPass; $lRj = [int]$ls.reject; $lRc = [int]$ls.recheck; $lEr = [int]$ls.error
    if ($lsAgeH -gt 36) {
      [void]$sbNote.Append("台标鉴定：本机 $([int]$lsAgeH) 小时没出结果，新线暂留待选池`n")
    } elseif ($lAp -gt 0) {
      $lNames = @($ls.promoted | Select-Object -First 5) -join '、'
      if (@($ls.promoted).Count -gt 5) { $lNames += '…' }
      [void]$sbNote.Append("台标鉴定：转正 $lAp 条（$lNames） 复检 $lRc / 被拒 $lRj / 异常 $lEr`n")
    } elseif ($lRj -ge 5) {
      [void]$sbNote.Append("台标鉴定：今天 $lRj 条台标对不上被拒，攒到阈值，需要本机看一次对照图`n")
    } elseif ($lRc -ge 5) {
      [void]$sbNote.Append("台标鉴定：$lRc 条读不出台名（源站没填 service_name），在待选池里堆着，需要看画面才能定`n")
    }
  } catch { }
}

$gLine = @()
foreach ($k in @('央视台', '卫视频道', '港澳台', '武汉台', '体育娱乐')) {
  if ($g.ContainsKey($k)) { $gLine += "$k $($g[$k])" }
}
[void]$sbNote.Append("分组：" + ($gLine -join ' / ') + "`n")
[void]$sbNote.Append("订阅直链（raw 直连）：`n")
[void]$sbNote.Append("  https://raw.githubusercontent.com/17993040/media-list/main/libretv-sub3.json`n")
[void]$sbNote.Append("  https://raw.githubusercontent.com/17993040/media-list/main/okys7.json`n")
[void]$sbNote.Append("LibreTV 数据源订阅 https://ghproxy.net/https://raw.githubusercontent.com/17993040/media-list/main/libretv-sub3.json`n")
[void]$sbNote.Append("OK 影视 配置 https://ghproxy.net/https://raw.githubusercontent.com/17993040/media-list/main/okys7.json`n")
[void]$sbNote.Append("完整清单: https://ghproxy.net/https://raw.githubusercontent.com/17993040/media-list/main/每日报告.txt")

[IO.File]::WriteAllText((Join-Path $outDir '通知.txt'), $sbNote.ToString(), [Text.UTF8Encoding]::new($false))

# ---------- 6. 每日报告（微信里只放链接，明细看这个） ----------
$sbRep = New-Object System.Text.StringBuilder
[void]$sbRep.Append("# 影视源每日报告`n`n")
[void]$sbRep.Append("- 生成时间：$($nowBj.ToString('yyyy-MM-dd HH:mm:ss')) 北京时间`n")
[void]$sbRep.Append("- 直播 $total 台（有源 $hasSrc / 待补 $pending / 华为云已测 $markedOk）`n")
[void]$sbRep.Append("- 清单条目：主线 $(@($chs).Count) 条 / 全量 $fullLines 条`n`n")

if ($addedNames.Count) { [void]$sbRep.Append("## 新增直播`n" + ($addedNames -join '、') + "`n`n") }
if ($removedNames.Count) { [void]$sbRep.Append("## 删除直播`n" + ($removedNames -join '、') + "`n`n") }
if ($relinked.Count) { [void]$sbRep.Append("## 换线`n" + ($relinked -join '、') + "`n`n") }

[void]$sbRep.Append("## 体育娱乐（动态组）`n")
$entChs = @($chs | Where-Object { $_.gid -eq 'ent' })
if ($entChs.Count) {
  foreach ($c in $entChs) {
    $st = if ($c.main) { '有源' } else { '无源' }
    [void]$sbRep.Append("- $($c.name)：$st，备线 $(@($c.backup | Where-Object {$_}).Count) 条，$($c.note)`n")
  }
} else {
  [void]$sbRep.Append("- 本轮无在册台`n")
}
[void]$sbRep.Append("`n")

[void]$sbRep.Append("## 点播站（$vodTotal 个，通过 $vodPass）`n")
if ($rep -and $rep.vod -and $rep.vod.detail) {
  foreach ($d in $rep.vod.detail) {
    $flag = if ($d.ok) { 'OK' } else { 'XX' }
    [void]$sbRep.Append("- $flag $($d.name)：$($d.stage)$(if($d.verified){'（已验证出片）'}else{''})`n")
  }
}
if ($vodDeleted.Count) {
  [void]$sbRep.Append("`n### 本轮剔除`n" + ($vodDeleted -join '、') + "`n")
}
if ($vodDryRun) { [void]$sbRep.Append("`n> 点播当前为空跑模式，只报告不删。`n") }

[void]$sbRep.Append("`n## 全部台状态`n")
foreach ($c in $chs) {
  $u = if ($c.main) { '主线有' } else { '主线无' }
  [void]$sbRep.Append("- [$($c.group)] $($c.name)：$u，备线 $(@($c.backup | Where-Object {$_}).Count)，cloud=$($c.cloud)$(if($c.note){"，$($c.note)"})`n")
}

[IO.File]::WriteAllText((Join-Path $Root '每日报告.txt'), $sbRep.ToString(), [Text.UTF8Encoding]::new($false))

Write-Output "发布完成：$total 台 / 全量 $fullLines 条 / 换线 $($relinked.Count) / 点播剔除 $($vodDeleted.Count)"
Write-Output "通知字数：$($sbNote.Length)"
