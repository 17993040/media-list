# extract_vod_sources.ps1
# 扫源环节的"点播找站"步骤：抓一批活的 TVBox 配置，从中抽出 MacCMS 采集站接口。
# 思路：配置本身每天被上游探活，配置里在用的采集站 = 当前大概率还活的站。
# 产物 out/vod-candidates.json 供云端 4:00 并入 config/vod-pool.json 后实测。

param(
  [string]$OutFile = 'out/vod-candidates.json',
  [string]$Root = (Split-Path (Split-Path $PSScriptRoot -Parent) -Parent),
  [int]$MaxConfigs = 24
)

$ErrorActionPreference = 'Continue'
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12

# 配置源清单：优先读 config/vod-config-sources.json，没有就用内置这组
$Builtin = @(
  'https://gh-proxy.com/raw.githubusercontent.com/zhoujck/config/main/box',
  'https://ghproxy.net/https://raw.githubusercontent.com/gaotianliuyun/gao/master/XYQ.json',
  'https://raw.githubusercontent.com/gaotianliuyun/gao/master/js.json',
  'https://gh-proxy.com/raw.githubusercontent.com/gaotianliuyun/gao/master/0827.json',
  'https://www.cttv.vip/ys/json/ctys.json',
  'https://ztha.top/TVBox/thdjk.json',
  'https://clun.top/box.json',
  'https://raw.githubusercontent.com/dxawi/0/main/0.json',
  'https://raw.githubusercontent.com/guot55/yg/main/pg/bh.json',
  'https://szyyds.cn/tv/x.json',
  'https://6800.kstore.vip/fish.json',
  'https://raw.githubusercontent.com/Kimentanm/aptv/master/json/api.json',
  'https://gh-proxy.com/raw.githubusercontent.com/gaotianliuyun/gao/master/js.json',
  'https://9280.kstore.vip/aiwex.json',
  'https://7337.kstore.vip/xw/api.json',
  'https://ztha.top/TVBox/xhz.json'
)

$listFile = Join-Path $Root 'config/vod-config-sources.json'
if (Test-Path $listFile) {
  try {
    $j = Get-Content $listFile -Raw -Encoding UTF8 | ConvertFrom-Json
    if ($j.sources -and $j.sources.Count -gt 0) { $Builtin = $j.sources }
    if ($j.max) { $MaxConfigs = [int]$j.max }
  } catch { }
}

$outPath = Join-Path $Root $OutFile
$outDir = Split-Path $outPath -Parent
if (-not (Test-Path $outDir)) { New-Item -ItemType Directory -Path $outDir -Force | Out-Null }

$rx = [regex]'https?://[A-Za-z0-9\.\-_]+(?::\d+)?(?:/[A-Za-z0-9_\-\/\.]*)?/api\.php/provide/vod[A-Za-z0-9_\-\.\/]*'
$hostCount = @{}
$hostSample = @{}
$hostName = @{}
$ok = 0
$fail = 0

$i = 0
foreach ($u in $Builtin) {
  if ($i -ge $MaxConfigs) { break }
  $i++
  try {
    $resp = Invoke-WebRequest -Uri $u -UseBasicParsing -TimeoutSec 25 -MaximumRedirection 3 `
      -Headers @{ 'User-Agent' = 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) Chrome/120 Safari/537.36' }
    $text = $resp.Content
    if ($text -is [byte[]]) { $text = [Text.Encoding]::UTF8.GetString($text) }
    if (-not $text -or $text.Length -lt 200) { $fail++; continue }
    $ok++

    # 先记一下配置里站名，便于后面给候选起中文名
    foreach ($m in [regex]::Matches($text, '"name"\s*:\s*"([^"]{1,30})"')) {
      $nm = $m.Groups[1].Value
      if ($nm) { $hostName[$nm] = $true }
    }

    foreach ($m in $rx.Matches($text)) {
      $api = $m.Value -replace '\\/', '/'
      try {
        $hh = ([Uri]$api).Host
      } catch { continue }
      if (-not $hh) { continue }
      $hostCount[$hh] = 1 + [int]$hostCount[$hh]
      if (-not $hostSample.ContainsKey($hh)) { $hostSample[$hh] = $api }
    }
  } catch {
    $fail++
  }
}

$rows = @()
foreach ($hh in $hostCount.Keys) {
  $rows += [pscustomobject]@{
    host = $hh
    count = [int]$hostCount[$hh]
    api = [string]$hostSample[$hh]
  }
}
$rows = $rows | Sort-Object -Descending count

$doc = [pscustomobject]@{
  generated = (Get-Date).ToUniversalTime().ToString('o')
  configs = [pscustomobject]@{ tried = $i; ok = $ok; fail = $fail }
  total = $rows.Count
  hosts = $rows
}
[IO.File]::WriteAllText($outPath, ($doc | ConvertTo-Json -Depth 4), [Text.UTF8Encoding]::new($false))

Write-Host "点播找站：配置 $ok/$i 读通，抽出采集站 $($rows.Count) 个（去重后）"
if ($rows.Count -gt 0) {
  Write-Host ("  出现最多的：" + (($rows | Select-Object -First 8 | ForEach-Object { "$($_.host)($($_.count)x)" }) -join '、'))
}
