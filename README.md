# VR3D — 把平面 PC 游戏实时转成立体 VR 画面

在 4080 上用 MiDaS 实时估深度 + DIBR 视差渲染，把任何窗口化平面游戏在 Pico 4 / Virtual Desktop / OpenXR 里变成 2K 全屏立体画面，实测 **90fps**。

不依赖虚拟显示器、不装 Moonlight XR，PC 端一次推流到头显。

---

## 快速开始（从源码构建）

### ① 装依赖

```powershell
# Python 3.10-3.13 + CUDA 12.x
pip install torch torchvision --index-url https://download.pytorch.org/whl/cu128
pip install dxcam opencv-python numpy

# MiDaS 模型 (~80MB)：model-small-traced.pt
# 从 https://github.com/isl-org/MiDaS 下载，放到 models/ 目录

# Godot 4.4.1 stable (Windows 64)
# https://github.com/godotengine/godot/releases/tag/4.4.1-stable
```

### ② 启动

```powershell
# 1. 把游戏开成窗口化/无边框
# 2. 先戴头显，Virtual Desktop 连上、OpenXR 激活

# 3. 启动 Python 服务端（参数是游戏窗口标题关键词）
python midas_sbs_server.py <游戏窗口标题>

# 4. 启动 Godot 客户端
Godot_v4.4.1-stable_win64.exe --path godot/VR3DXr
```

等 15 秒预热，游戏自动拉到前台，头显里就是全屏立体画面。ESC 退出。

### ③ VD 里的设置

Virtual Desktop → 桌面模式 → **3D 模式 → SBS**。

---

## 效果

- 全屏 2K SBS（每眼 2560×1440 区域，1.43:1 IMAX 银幕）
- MiDaS 推理 ~8ms / 帧，dxcam 捕窗 90fps，Godot OpenXR 90fps
- 左右眼分离走 mesh 投影层（不用 composition layer，避开 VDXR 1.0.9 的 bug）

---

## 给开发者：架构

```
游戏窗口（窗口化，物理屏任意分辨率）
   │  dxcam 捕窗 → 中央裁剪 2560×1440 (16:9)
   ▼
midas_sbs_server.py  (Python, port 48372)
   ├─ MiDaS 深度推理 96×96
   ├─ YUV420(I420) 彩色 [2560×1440×1.5 字节]
   └─ float32 深度图 [96×96]
   │  raw socket 直传（无压缩）
   ▼
Godot 4.4.1 + OpenXR  (godot/VR3DXr/)
   ├─ ImageTexture 三路 Y/U/V + 深度纹理
   ├─ dibr.gdshader:  YUV→RGB + DIBR 视差 (VIEW_INDEX 分左右眼)
   └─ mesh 投影层 (不是 composition layer)
   ▼
Pico 4 (Virtual Desktop OpenXR)
```

### 核心文件

| 文件 | 作用 |
|---|---|
| `midas_sbs_server.py` | Python 服务端：捕窗 + 深度 + 推流 |
| `godot/VR3DXr/scripts/main.gd` | Godot 客户端：收流、窗口最小化、路由 |
| `godot/VR3DXr/scripts/xr_composition_video.gd` | OpenXR 合成视口尺寸（2560×1792 1.43:1） |
| `godot/VR3DXr/scripts/xr_settings_panel.gd` | 左右手扳机调立体强度/距离/收敛 |
| `godot/VR3DXr/shaders/dibr.gdshader` | DIBR 视差着色器 |
| `godot/VR3DXr/shaders/dibr_canvas.gdshader` | 16:9 内容塞进 1.43:1 银幕的黑边 |

### 自己装依赖跑（不走 release 包）

```powershell
# Python 3.10-3.13, CUDA 12.x
pip install torch torchvision --index-url https://download.pytorch.org/whl/cu128
pip install dxcam opencv-python numpy

# MiDaS 模型 (model-small-traced.pt, ~80MB)
# 从官方仓库下载: https://github.com/isl-org/MiDaS

# Godot 4.4.1 stable (Windows 64)
# 用 godot/VR3DXr/ 作为项目路径打开
```

启动：

```powershell
# 服务端
python midas_sbs_server.py <游戏窗口标题关键词>

# Godot 客户端
Godot_v4.4.1-stable_win64.exe --path godot/VR3DXr
```

---

## 已知坑（别重试）

- **Godot 必须 4.4.1**：4.4.0 全 JPEG/PNG buffer 解码路线黑屏，4.6 xrCreateInstance 失败
- **VD 必须关 SSW**：开 SSW 强制锁 45fps，跟显卡无关
- **VIEW_MATRIX[3][0] 分眼无效**：OpenXR 双眼单渲染，必须用 `VIEW_INDEX`
- **JPEG 压缩传流只有 30fps**：YUV420 无压缩直传 50-90fps
- **composition layer 双路由在 VDXR 1.0.9 下只能看到右眼**：默认走 mesh 投影层
- 游戏窗口被 SBS 全屏盖住时，**点击会点到 SBS 窗口**——用键盘/手柄操作游戏，或用 VD 内鼠标

---

## 许可

本项目代码 MIT。MiDaS 模型版权归原作者（isl-org），Godot 引擎版权归 Godot 社区。本项目与 OpenAI、Meta、Pico、Unity 均无关。
