# ============================================================
# 接单管家 · 构建 + 官网实时同步 一键脚本
# 用法：右键“使用 PowerShell 运行”，或在项目目录执行  ./build_and_sync.ps1
# 流程：构建 release(Dart混淆) -> 固定名 latest + 版本归档 + output 副本
#       -> 更新下载按钮版本号 -> scp 上传官网 -> 公网校验大小
# ============================================================
$ErrorActionPreference = 'Stop'
$env:PUB_CACHE = 'D:\pub-cache'

# ---- 配置（路径有变动只改这里）----
$AppDir   = 'D:\dev\jiedan_app'
$WebLocal = 'D:\dev\website_release'
$SshKey   = 'C:\Users\蓝筝\Desktop\季秋一.pem'
$Srv      = 'root@121.41.97.109'
$SrvWeb   = '/var/www/yurouyun'
$Latest   = 'jiedanguanja_latest.apk'

Set-Location $AppDir

# 1) 读取版本号，形如 1.34.0+44
$psText = [System.IO.File]::ReadAllText((Join-Path $AppDir 'pubspec.yaml'))
if ($psText -match '(?m)^\s*version:\s*([0-9][0-9A-Za-z+.]+)') {
    $fullVer = $Matches[1].Trim()
} else { throw '未能从 pubspec.yaml 解析 version' }
$verShort   = ($fullVer -split '\+')[0]                 # 1.34.0
$verCompact = (($verShort -split '\.')[0..1] -join '.')  # 1.34
Write-Host "[1/6] 当前版本 $fullVer （展示号 v$verCompact）" -ForegroundColor Cyan

# 2) 构建 release（Dart 层混淆）
Write-Host "[2/6] 开始构建 release ..." -ForegroundColor Cyan
flutter build apk --release --obfuscate --split-debug-info=./debug-info
$built = Join-Path $AppDir 'build\app\outputs\flutter-apk\app-release.apk'
if (!(Test-Path $built)) { throw "构建失败：找不到 $built" }

# 3) 本地落地：官网固定名 latest + 版本归档 + App/output 交付副本
$dlLocal = Join-Path $WebLocal 'downloads'
[System.IO.File]::Copy($built, (Join-Path $dlLocal $Latest), $true)
$arch = "jiedanguanja_v$verCompact.apk"
[System.IO.File]::Copy($built, (Join-Path $dlLocal $arch), $true)
$outDir = Join-Path $AppDir 'output'
if (!(Test-Path $outDir)) { New-Item -ItemType Directory -Path $outDir | Out-Null }
[System.IO.File]::Copy($built, (Join-Path $outDir "接单管家_v$fullVer.apk"), $true)
Write-Host "[3/6] 本地已更新 latest / v$verCompact 归档 / output 副本" -ForegroundColor Cyan

# 4) 更新 product.html：href 固定 latest，按钮版本文字随当前版本
$prodPath = Join-Path $WebLocal 'product.html'
$html = [System.IO.File]::ReadAllText($prodPath)
$html = [regex]::Replace($html, 'downloads/jiedanguanja[^"]*\.apk', "downloads/$Latest")
$html = [regex]::Replace($html, '下载 APK · v[0-9.]+', "下载 APK · v$verCompact")
$utf8NoBom = New-Object System.Text.UTF8Encoding($false)
[System.IO.File]::WriteAllText($prodPath, $html, $utf8NoBom)
Write-Host "[4/6] product.html 已指向 latest、版本号更新为 v$verCompact" -ForegroundColor Cyan

# 5) 上传官网（downloads 两个包 + product.html + version.json 版本清单）
Write-Host "[5/6] 上传到服务器官网 ..." -ForegroundColor Cyan
scp -i $SshKey -o StrictHostKeyChecking=no (Join-Path $dlLocal $Latest) (Join-Path $dlLocal $arch) "${Srv}:$SrvWeb/downloads/"
scp -i $SshKey -o StrictHostKeyChecking=no $prodPath "${Srv}:$SrvWeb/product.html"
$manifestPath = Join-Path $WebLocal 'version.json'
if (Test-Path $manifestPath) {
  scp -i $SshKey -o StrictHostKeyChecking=no $manifestPath "${Srv}:$SrvWeb/version.json"
}

# 6) 公网验证：上传后短暂重试，状态 200 且线上大小=本地大小才算通过
Write-Host "[6/6] 公网验证 ..." -ForegroundColor Cyan
$localLen = (Get-Item $built).Length
$head = $null
$remoteLen = $null
for ($try = 1; $try -le 6; $try++) {
  Start-Sleep -Seconds 2
  $head = curl.exe -sI "https://yurouyun.cn/downloads/$Latest"
  if ($head -match '200 OK') {
    $remoteLen = ($head | Where-Object { $_ -match 'Content-Length:\s*(\d+)' } | ForEach-Object { $Matches[1] } | Select-Object -First 1)
    if ("$remoteLen" -eq "$localLen") { break }
  }
  $remoteLen = $null
}
if ("$remoteLen" -ne "$localLen") { throw "公网验证失败：线上大小 $remoteLen 与本地 $localLen 不一致（已重试）" }
Write-Host ($head -join "`n")
Write-Host ""
Write-Host "全部完成：官网下载已更新为 v$verCompact（大小校验一致）" -ForegroundColor Green
Write-Host "固定下载地址：https://yurouyun.cn/downloads/$Latest" -ForegroundColor Green
