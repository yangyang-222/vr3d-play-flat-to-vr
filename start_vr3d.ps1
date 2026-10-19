param(
    [switch]$DesktopTest,
    [ValidateRange(1, 240)]
    [int]$CaptureFps = 90,
    [ValidateRange(1, 240)]
    [int]$SendFps = 90,
    [ValidateRange(1, 120)]
    [int]$DepthFps = 30,
    [ValidateRange(1, 65535)]
    [int]$Port = 48372,
    [ValidateRange(-360, 360)]
    [int]$EnvironmentRotation = 0,
    [ValidateRange(0.0, 4.0)]
    [double]$EnvironmentExposure = 1.0,
    [switch]$EnvironmentFlipY,
    [string]$EnvironmentVideo = "",
    [string]$EnvironmentImage = "",
    [switch]$NoEnvironmentVideo,
    [switch]$NoWait
)

# VR3D 一键启动：Python 服务端 + Godot 4.7.2
$ErrorActionPreference = "Stop"
# Some launchers inject both PATH and Path. Windows PowerShell 5.1 then makes
# Start-Process fail with a duplicate-key error; normalize the process environment.
$normalizedPath = [Environment]::GetEnvironmentVariable("Path", "Process")
[Environment]::SetEnvironmentVariable("PATH", $null, "Process")
[Environment]::SetEnvironmentVariable("Path", $normalizedPath, "Process")
$root = $PSScriptRoot
if ([string]::IsNullOrWhiteSpace($root)) {
    $root = Split-Path -Parent $MyInvocation.MyCommand.Path
}
$portablePython = Join-Path $root "runtime\python\python.exe"
$developmentPython = Join-Path $root "venv313\Scripts\python.exe"
if (Test-Path -LiteralPath $portablePython) {
    $py = $portablePython
} elseif (Test-Path -LiteralPath $developmentPython) {
    $py = $developmentPython
} else {
    $py = $portablePython
}
$server = Join-Path $root "midas_sbs_server.py"
$model = Join-Path $root "models\model-small-traced.pt"
$godot = Join-Path $root "godot\Godot_v4.7.2-stable_win64_console.exe"
$project = Join-Path $root "godot\VR3DXr"
$log = $root

# Start-Process 的重定向会让日志文件保持独占；必须用 FileShare.ReadWrite 才能边跑边读。
function Read-LogText {
    param([string]$Path)
    if (!(Test-Path -LiteralPath $Path)) { return "" }
    $fs = $null
    $sr = $null
    try {
        $fs = [IO.File]::Open($Path, [IO.FileMode]::Open, [IO.FileAccess]::Read, [IO.FileShare]::ReadWrite)
        $sr = New-Object IO.StreamReader($fs)
        return $sr.ReadToEnd()
    } catch {
        return ""
    } finally {
        if ($sr) { $sr.Dispose() }
        if ($fs) { $fs.Dispose() }
    }
}

# venv313\Scripts\python.exe 只是转发器，真正的解释器是它的子进程：
# 监听端口的 PID 不等于 Start-Process 返回的 PID。所以这里按进程树取 PID。
function Get-ProcessTreeIds {
    param([int]$RootPid)
    $all = @(Get-CimInstance Win32_Process -ErrorAction SilentlyContinue | Select-Object ProcessId, ParentProcessId)
    $ids = @($RootPid)
    $added = $true
    while ($added) {
        $added = $false
        foreach ($item in $all) {
            $childPid = [int]$item.ProcessId
            $parentPid = [int]$item.ParentProcessId
            if (($ids -contains $parentPid) -and ($ids -notcontains $childPid)) {
                $ids += $childPid
                $added = $true
            }
        }
    }
    return $ids
}

# 必须连转发器的子进程一起结束，否则会留下占着端口的孤儿服务。
function Stop-ProcessTree {
    param([int]$RootPid)
    $ids = @(Get-ProcessTreeIds -RootPid $RootPid)
    [array]::Reverse($ids)
    foreach ($procId in $ids) {
        Stop-Process -Id $procId -Force -ErrorAction SilentlyContinue
    }
}

# Explicit targets prevent an old parent-process environment from silently
# keeping the sender at the former 45 FPS cap.
$env:VR3D_CAPTURE_FPS = [string]$CaptureFps
$env:VR3D_SEND_FPS = [string]$SendFps
$env:VR3D_DEPTH_FPS = [string]$DepthFps
$env:VR3D_PORT = [string]$Port
if ([string]::IsNullOrWhiteSpace($EnvironmentVideo)) {
    Remove-Item Env:VR3D_ENVIRONMENT_VIDEO -ErrorAction SilentlyContinue
} else {
    $env:VR3D_ENVIRONMENT_VIDEO = $EnvironmentVideo
}
if ([string]::IsNullOrWhiteSpace($EnvironmentImage)) {
    Remove-Item Env:VR3D_ENVIRONMENT_IMAGE -ErrorAction SilentlyContinue
} else {
    $env:VR3D_ENVIRONMENT_IMAGE = $EnvironmentImage
}

# CPU: MiDaS input is 96x96 and runs on CUDA. Single-threaded PyTorch avoids
# OpenMP/MKL worker spin; advanced users can override these before launching.
if ([string]::IsNullOrWhiteSpace($env:VR3D_TORCH_THREADS)) {
    $env:VR3D_TORCH_THREADS = "1"
}
if ([string]::IsNullOrWhiteSpace($env:VR3D_TORCH_INTEROP_THREADS)) {
    $env:VR3D_TORCH_INTEROP_THREADS = "1"
}
if ([string]::IsNullOrWhiteSpace($env:OMP_NUM_THREADS)) {
    $env:OMP_NUM_THREADS = "1"
}
if ([string]::IsNullOrWhiteSpace($env:MKL_NUM_THREADS)) {
    $env:MKL_NUM_THREADS = "1"
}
if ([string]::IsNullOrWhiteSpace($env:OPENBLAS_NUM_THREADS)) {
    $env:OPENBLAS_NUM_THREADS = "1"
}
if ([string]::IsNullOrWhiteSpace($env:NUMEXPR_NUM_THREADS)) {
    $env:NUMEXPR_NUM_THREADS = "1"
}
if ([string]::IsNullOrWhiteSpace($env:OMP_WAIT_POLICY)) {
    $env:OMP_WAIT_POLICY = "PASSIVE"
}

Write-Host "VR3D 启动器"
Write-Host "Python 环境: $py"
Write-Host "捕获模式：显示器 output 0（不查找、不置前任何游戏或进程）。"
Write-Host "当前传输画面：跟随显示器 output 0 的原生桌面分辨率；Godot 画布同步同一宽高比，不裁边。"

Write-Host ("帧率目标：捕获 {0} / 发送 {1} / 深度 {2} FPS；端口 {3}" -f $CaptureFps, $SendFps, $DepthFps, $Port)
Write-Host ("CPU 线程：PyTorch {0} / 数学库 {1}" -f $env:VR3D_TORCH_THREADS, $env:OMP_NUM_THREADS)

foreach ($required in @($py, $server, $model, $godot, (Join-Path $project "project.godot"))) {
    if (!(Test-Path -LiteralPath $required)) {
        throw "找不到必需文件：$required"
    }
}

# Use the framework listener table as the source of truth. On some Windows
# configurations Get-NetTCPConnection can return no row even for a live socket.
$portListeners = @(
    [Net.NetworkInformation.IPGlobalProperties]::GetIPGlobalProperties().GetActiveTcpListeners() |
        Where-Object { $_.Port -eq $Port }
)
$portOwners = @(
    Get-NetTCPConnection -LocalPort $Port -State Listen -ErrorAction SilentlyContinue |
        Select-Object -ExpandProperty OwningProcess -Unique
)
if ($portListeners.Count -gt 0 -or $portOwners.Count -gt 0) {
    Write-Host "端口 $Port 已被占用；不会自动结束任何现有进程。" -ForegroundColor Red
    if ($portOwners.Count -gt 0) {
        foreach ($ownerPid in $portOwners) {
            $owner = Get-Process -Id $ownerPid -ErrorAction SilentlyContinue
            if ($null -ne $owner) {
                Write-Host ("  PID {0}: {1}" -f $ownerPid, $owner.ProcessName)
            } else {
                Write-Host ("  PID {0}" -f $ownerPid)
            }
        }
    } else {
        foreach ($endpoint in $portListeners) {
            Write-Host ("  监听地址 {0}" -f $endpoint)
        }
    }
    throw "请先关闭旧的 VR3D 服务，或使用 -Port 指定其他端口。"
}

if (!$DesktopTest) {
    Write-Host "OpenXR 模式：启动前请确认 Pico 4 已通过 Virtual Desktop 连接。"
} else {
    Write-Host "桌面测试模式：禁用 OpenXR。"
}

# 服务端后台运行，避免桌面捕获把服务端控制台拍进去。
# -u 保证重定向日志实时刷新。
$serverProcess = Start-Process -FilePath $py `
    -ArgumentList "-u", $server `
    -WorkingDirectory $root `
    -WindowStyle Hidden `
    -RedirectStandardOutput (Join-Path $log "srv_out.txt") `
    -RedirectStandardError (Join-Path $log "srv_err.txt") `
    -PassThru
try { $serverProcess.PriorityClass = [Diagnostics.ProcessPriorityClass]::AboveNormal } catch {
    Write-Warning "无法提高 Python 优先级，将继续使用系统默认值：$($_.Exception.Message)"
}

$serverReady = $false
$startupDeadline = (Get-Date).AddSeconds(45)
$srvOutPath = Join-Path $log "srv_out.txt"
while ((Get-Date) -lt $startupDeadline) {
    $serverProcess.Refresh()
    if ($serverProcess.HasExited) {
        break
    }
    # 先看服务端自己打印的 "listening on"；不成立时再看"本进程树里有没有 PID
    # 在监听端口"。两者任一成立就算就绪，不再依赖转发器的 PID。
    if ((Read-LogText $srvOutPath) -match "listening on") {
        $serverReady = $true
        break
    }
    $listenerPids = @(Get-NetTCPConnection -LocalPort $Port -State Listen -ErrorAction SilentlyContinue |
        Select-Object -ExpandProperty OwningProcess -Unique)
    $treeIds = @(Get-ProcessTreeIds -RootPid $serverProcess.Id)
    if (@($listenerPids | Where-Object { $treeIds -contains $_ }).Count -gt 0) {
        $serverReady = $true
        break
    }
    Start-Sleep -Milliseconds 250
}

if (!$serverReady) {
    Write-Host "Python/DXGI 服务未能在 45 秒内监听端口 $Port；Godot 不会启动。" -ForegroundColor Red
    foreach ($logName in @("srv_out.txt", "srv_err.txt")) {
        $logPath = Join-Path $log $logName
        if (Test-Path -LiteralPath $logPath) {
            Write-Host "--- $logName ---"
            Get-Content -LiteralPath $logPath -Tail 80
        }
    }
    Stop-ProcessTree -RootPid $serverProcess.Id
    throw "VR3D 服务端启动失败。"
}
Write-Host ("Python 服务已就绪：PID {0}，127.0.0.1:{1}" -f $serverProcess.Id, $Port)

$godotArgs = @("--path", $project, "--rendering-driver", "vulkan")
if ($DesktopTest) {
    $godotArgs += @("--xr-mode", "off")
} else {
    $godotArgs += @("--xr-mode", "on")
}
$godotArgs += @("--", "--server-port=$Port")
if ($NoEnvironmentVideo) {
    $godotArgs += "--no-environment-video"
}
if (-not [string]::IsNullOrWhiteSpace($EnvironmentVideo)) {
    $godotArgs += "--environment-video=$EnvironmentVideo"
}
if (-not [string]::IsNullOrWhiteSpace($EnvironmentImage)) {
    $godotArgs += "--environment-image=$EnvironmentImage"
}
# 旋转/曝光/翻转同时适用于视频和图片背景，不能因为 $NoEnvironmentVideo 被跳过。
if ($EnvironmentRotation -ne 0) {
    $godotArgs += "--environment-rotation=$EnvironmentRotation"
}
if ([math]::Abs($EnvironmentExposure - 1.0) -gt 0.0001) {
    $godotArgs += "--environment-exposure=$EnvironmentExposure"
}
if ($EnvironmentFlipY) {
    $godotArgs += "--environment-flip-y=1"
}
$godotProcess = Start-Process -FilePath $godot `
    -ArgumentList $godotArgs `
    -WorkingDirectory (Join-Path $root "godot") `
    -WindowStyle Normal `
    -RedirectStandardOutput (Join-Path $log "godot_out.txt") `
    -RedirectStandardError (Join-Path $log "godot_err.txt") `
    -PassThru
try { $godotProcess.PriorityClass = [Diagnostics.ProcessPriorityClass]::High } catch {
    Write-Warning "无法提高 Godot 优先级，将继续使用系统默认值：$($_.Exception.Message)"
}

Write-Host "已启动 VR3D 服务端 + Godot 4.7.2（Vulkan）。"
Write-Host "服务端日志：$(Join-Path $log 'srv_out.txt')"
Write-Host "Godot 日志：$(Join-Path $log 'godot_out.txt')"
Write-Host "实时观察性能：Get-Content '$log\srv_out.txt','$log\godot_out.txt' -Wait"

if ($NoWait) {
    Write-Host "已按 -NoWait 返回；Python/Godot 继续在后台运行。"
    return
}

Write-Host "启动器将保持运行；按 Ctrl+C 结束，并会清理本次启动的 Python/Godot。" -ForegroundColor Cyan
try {
    while ($true) {
        $serverProcess.Refresh()
        $godotProcess.Refresh()
        if ($serverProcess.HasExited) {
            Write-Host ("Python 服务端已退出，退出码 {0}。" -f $serverProcess.ExitCode) -ForegroundColor Red
            break
        }
        if ($godotProcess.HasExited) {
            Write-Host ("Godot 已退出，退出码 {0}。" -f $godotProcess.ExitCode) -ForegroundColor Red
            break
        }
        Start-Sleep -Milliseconds 500
    }
}
finally {
    foreach ($proc in @($godotProcess, $serverProcess)) {
        if ($null -ne $proc) {
            try { $proc.Refresh() } catch { }
            if (!$proc.HasExited) {
                Stop-ProcessTree -RootPid $proc.Id
            }
        }
    }
}
