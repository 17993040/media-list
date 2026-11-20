# build_base.ps1
# 作用：按固定口径生成 75 个固定台的基准配置，并输出 live.m3u / backup.m3u / pending.m3u
# 数据源：out\live-all3.m3u（现有可用源），缺的台自动标〔待补〕

param(
  [string]$Src = (Join-Path (Split-Path (Split-Path $PSScriptRoot -Parent) -Parent) 'out\live-all3.m3u'),
  [string]$Root = (Split-Path (Split-Path $PSScriptRoot -Parent) -Parent)
)

$ErrorActionPreference = 'Stop'
$cfgDir = Join-Path $Root 'config'
$outDir = Join-Path $Root 'out'
if (-not (Test-Path $cfgDir)) { New-Item -ItemType Directory -Path $cfgDir -Force | Out-Null }

# ---------- 1. 读现有源 ----------
$map = @{}
if (Test-Path -LiteralPath $Src) {
  $nm = ''
  foreach ($l in Get-Content -LiteralPath $Src -Encoding UTF8) {
    if ($l -match '^#EXTINF') {
      $nm = ((($l -replace '^#EXTINF[^,]*,', '') -replace '^.*,', '')).Trim()
    } elseif ($l -notmatch '^#' -and $l -match '^http') {
      if ($nm -and -not $map.ContainsKey($nm)) { $map[$nm] = $l.Trim() }
      $nm = ''
    }
  }
}

function U($n) { if ($map.ContainsKey($n)) { return $map[$n] } else { return '' } }

# ---------- 2. 固定台定义 ----------
# 每组：id / name / 台列表（标准名 / 现有源名 / 是否必通 / 备注）
$gCctv = @(
  @{n='CCTV-1';  s='CCTV-1';  must=$true},
  @{n='CCTV-2';  s='CCTV-2';  must=$true},
  @{n='CCTV-3';  s='CCTV-3';  must=$true},
  @{n='CCTV-4';  s='CCTV-4';  must=$true},
  @{n='CCTV-5';  s='CCTV-5';  must=$true},
  @{n='CCTV-5+'; s='CCTV-5+'; must=$true},
  @{n='CCTV-6';  s='CCTV-6';  must=$true},
  @{n='CCTV-7';  s='CCTV-7';  must=$true},
  @{n='CCTV-8';  s='CCTV-8';  must=$true},
  @{n='CCTV-9';  s='CCTV-9';  must=$true},
  @{n='CCTV-10'; s='CCTV-10'; must=$true},
  @{n='CCTV-11'; s='CCTV-11'; must=$true},
  @{n='CCTV-12'; s='CCTV-12'; must=$true},
  @{n='CCTV-13'; s='CCTV-13'; must=$true},
  @{n='CCTV-14'; s='CCTV-14'; must=$true},
  @{n='CCTV-15'; s='CCTV-15'; must=$true},
  @{n='CCTV-17'; s='CCTV-17'; must=$true}
)

$gSat = @(
  @{n='北京卫视'; s='北京卫视'},
  @{n='天津卫视'; s='天津卫视'},
  @{n='河北卫视'; s='河北卫视'},
  @{n='山西卫视'; s='山西卫视'},
  @{n='内蒙古卫视'; s='内蒙古卫视'},
  @{n='辽宁卫视'; s='辽宁卫视'},
  @{n='吉林卫视'; s='吉林卫视'},
  @{n='黑龙江卫视'; s='黑龙江卫视'},
  @{n='东方卫视'; s='东方卫视'},
  @{n='江苏卫视'; s='江苏卫视'},
  @{n='浙江卫视'; s='浙江卫视'},
  @{n='安徽卫视'; s='安徽卫视'},
  @{n='东南卫视'; s='东南卫视'},
  @{n='江西卫视'; s='江西卫视'},
  @{n='山东卫视'; s='山东卫视'},
  @{n='河南卫视'; s='河南卫视'},
  @{n='湖北卫视'; s='湖北卫视'},
  @{n='湖南卫视'; s='湖南卫视'},
  @{n='广东卫视'; s='广东卫视'},
  @{n='广西卫视'; s='广西卫视'},
  @{n='海南卫视'; s='海南卫视'},
  @{n='重庆卫视'; s='重庆卫视'},
  @{n='四川卫视'; s='四川卫视'},
  @{n='贵州卫视'; s='贵州卫视'},
  @{n='云南卫视'; s='云南卫视'},
  @{n='西藏卫视'; s='西藏卫视'},
  @{n='陕西卫视'; s='陕西卫视'},
  @{n='甘肃卫视'; s='甘肃卫视'},
  @{n='青海卫视'; s='青海卫视'},
  @{n='宁夏卫视'; s='宁夏卫视'},
  @{n='新疆卫视'; s='新疆卫视'}
)

$gHmt = @(
  @{n='TVBS亚洲台';  s='TVBS亚洲台'},
  @{n='TVBS新闻台';  s='TVBS新闻台'},
  @{n='东森超视';    s='东森超视'},
  @{n='东森美洲';    s='东森美洲'},
  @{n='东森新闻';    s='东森新闻'},
  @{n='中视';        s='中视'},
  @{n='中天新闻';    s='中天新闻'},
  @{n='台视新闻';    s='台视新闻'},
  @{n='民视新闻台';  s='民视新闻台'},
  @{n='华视';        s='华视'},
  @{n='公视';        s='公视'},
  @{n='三立新闻';    s='三立新闻'},
  @{n='三立戏剧台';  s='三立戏剧台'},
  @{n='纬来体育';    s='纬来体育'},
  @{n='凤凰资讯';    s='凤凰资讯'},
  @{n='Now70s';      s='Now70s'},
  @{n='Now90s';      s='Now90s'},
  @{n='NowRock';     s='EN|NowRock'},
  @{n='翡翠台';      s='翡翠台'},
  @{n='明珠台';      s='明珠台'},
  @{n='无线新闻台';  s='无线新闻台'},
  @{n='ViuTV';       s='ViuTV'},
  @{n='HOY TV';      s='HOY TV'},
  @{n='澳视';        s='澳视'}
)

$gWh = @(
  @{n='武汉新闻综合'; s='武汉新闻综合'},
  @{n='武汉电视剧';   s='武汉电视剧'},
  @{n='武汉都市文体'; s='武汉都市文体'}
)

# 需要剔除的旧台（不进入新清单）
$dropNames = @('三沙卫视','延边卫视','深圳卫视','东方卫视4K','人间卫视','安多卫视','东森美洲卫视',
  '荆门新闻综合','荆门科教文旅','荆门公共频道','CHC电影','CGTN','CGTN-纪录','CGTN-西语','CGTN-法语',
  'CGTN-阿语','CGTN-俄语','CCTV-16','CCTV-世界地理','CCTV+')

# ---------- 3. 组装 ----------
$channels = @()
$idx = 0
foreach ($g in @(
    @{id='cctv'; name='央视台';    list=$gCctv},
    @{id='sat';  name='卫视频道';  list=$gSat},
    @{id='hmt';  name='港澳台';    list=$gHmt},
    @{id='wh';   name='武汉台';    list=$gWh}
  )) {
  foreach ($c in $g.list) {
    $idx++
    $url = U $c.s
    # 明确标记为错源的剔除
    if ($url -match 'qingting\.fm') { $url = '' }
    $must = if ($c.must) { $true } else { $false }
    $channels += [pscustomobject]@{
      seq     = $idx
      group   = $g.name
      gid     = $g.id
      name    = $c.n
      main    = $url
      backup  = @()
      local   = $(if ($url) { 'untested' } else { 'none' })
      cloud   = 'untested'
      must    = $must
      failCount = 0
      lastLocal = ''
      lastCloud = ''
      note    = $(if (-not $url) { '无可用源' } else { '' })
    }
  }
}

$obj = [pscustomobject]@{
  version  = 1
  updated  = (Get-Date -Format 'yyyy-MM-dd HH:mm:ss')
  rule     = 'list: 只出主线一条；backup: 备线池，单台≤3；标记只代表华为云测过且通过'
  counts   = [pscustomobject]@{
    cctv = @($channels | Where-Object { $_.gid -eq 'cctv' }).Count
    sat  = @($channels | Where-Object { $_.gid -eq 'sat' }).Count
    hmt  = @($channels | Where-Object { $_.gid -eq 'hmt' }).Count
    wh   = @($channels | Where-Object { $_.gid -eq 'wh' }).Count
    total = $channels.Count
  }
  channels = $channels
}
$cfgPath = Join-Path $cfgDir 'channels.json'
[IO.File]::WriteAllText($cfgPath, ($obj | ConvertTo-Json -Depth 6), (New-Object Text.UTF8Encoding($false)))

# ---------- 4. 输出 m3u ----------
$live = New-Object System.Text.StringBuilder
[void]$live.AppendLine('#EXTM3U')
$bck = New-Object System.Text.StringBuilder
[void]$bck.AppendLine('#EXTM3U')

foreach ($c in $channels) {
  $label = $c.name
  if (-not $c.main) { $label = $c.name + '〔待补〕' }
  elseif ($c.cloud -eq 'ok') { $label = $c.name + '[华为云已测]' }
  $u = if ($c.main) { $c.main } else { 'http://0.0.0.0:1/void.m3u8' }
  [void]$live.AppendLine('#EXTINF:-1 group-title="' + $c.group + '",' + $label)
  [void]$live.AppendLine($u)

  if ($c.backup.Count -gt 0) {
    foreach ($b in $c.backup) {
      [void]$bck.AppendLine('#EXTINF:-1 group-title="' + $c.group + '",' + $c.name + '〔备〕')
      [void]$bck.AppendLine($b)
    }
  }
}

$livePath = Join-Path $outDir 'live.m3u'
$bckPath = Join-Path $outDir 'backup.m3u'
$pendPath = Join-Path $outDir 'pending.m3u'
[IO.File]::WriteAllText($livePath, $live.ToString(), (New-Object Text.UTF8Encoding($false)))
[IO.File]::WriteAllText($bckPath, $bck.ToString(), (New-Object Text.UTF8Encoding($false)))
if (-not (Test-Path $pendPath)) { [IO.File]::WriteAllText($pendPath, "#EXTM3U`n", (New-Object Text.UTF8Encoding($false))) }

# ---------- 5. 汇报 ----------
Write-Output ("配置: " + $cfgPath)
Write-Output ("清单: " + $livePath)
$ok = @($channels | Where-Object { $_.main }).Count
$none = @($channels | Where-Object { -not $_.main }).Count
Write-Output ("固定台 " + $channels.Count + "  有源 " + $ok + "  待补 " + $none)
foreach ($g in $channels | Group-Object group) {
  $have = @($g.Group | Where-Object { $_.main }).Count
  Write-Output ("  " + $g.Name + ": " + $have + "/" + $g.Count)
}
Write-Output "待补明细:"
$channels | Where-Object { -not $_.main } | ForEach-Object { Write-Output ("  " + $_.group + " | " + $_.name) }
Write-Output "已剔除旧台:"
Write-Output ("  " + ($dropNames -join '、'))
