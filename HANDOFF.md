# 交接文档：逆战未来 PC 端 3D 化（Codex 接手用）

> 本文件是给 Codex 的完整交接说明。**开工前先读本文件 + 项目 README**，
> 再读核心代码（`midas_sbs_server.py`、`godot/VR3DXr/scripts/main.gd`、`godot/VR3DXr/shaders/dibr.gdshader`）。

## 一、项目目标

把《逆战：未来》（UE4 网游，ACE 反作弊**禁止 DLL 注入**，UEVR 不可用）的
**2D 桌面画面用 PC 端 4080 实时 3D 化**，在 **Pico 4 + Virtual Desktop OpenXR** 里看
**全桌面 2K（2560×1440，16:9）立体画面**，要求：**90fps、颜色正常、全桌面 3D**。
参考实现：Moonlight XR（源码见下文）。

用户硬性约束（**不得违背**）：
- C 盘空间不足：所有安装/大文件放 **G 盘**
- 游戏运行中不要随便关；戴头显测试前必须先告知用户
- 已明确否决：21:9 比例、画面缩放、GPU 处理彩色图、SBS 双通道方案

## 二、当前状态（v9 方案，2026-09-22）

**窗口模式已验证通过**，VR（OpenXR）实测未完成：

| 项 | 状态 |
|---|---|
| 捕获：dxcam 捕获游戏窗口 | ✅ 2K 2560×1440 16:9 中央裁切（源 3440×1440） |
| 深度：MiDaS 独立线程（96×96） | ✅ |
| 传输：YUV420(I420) 直传 socket，无压缩 | ✅ 窗口模式 **50fps**（JPEG 版只有 30） |
| 渲染：Godot 4.4.1 + OpenXR，shader DIBR 左右眼 | ✅ 窗口模式颜色正常（蓝不再变黄） |
| 防回环：Godot 窗口最小化 | ✅ 已加 |
| **VR 实测（戴头显）** | ⏳ **待做**（OpenXR 需头显+VD 连接才激活） |

## 三、架构与数据流

```
逆战未来窗口（物理屏 3440×1440）
   │ dxcam 捕获 → 中央裁 2560×1440 (16:9)
   ▼
midas_sbs_server.py (Python, 端口 48372)
   ├─ YUV420(I420) 彩色帧 [2560×1440×1.5 字节]
   └─ float32 深度图 [96×96]
   ▼ socket
Godot 4.4.1 (OpenXR) → ImageTexture 三平面(Y/U/V) + 深度纹理
   ▼ shader
YUV→RGB + DIBR(VIEW_INDEX 区分左右眼, DISPARITY=0.03) → 左右眼立体
   ▼ VD 串流
Pico 4 头显
```

## 四、核心文件清单

| 文件 | 作用 |
|---|---|
| `G:\24youxi\VR3D\midas_sbs_server.py` | **服务端 v9**：dxcam 捕获 + 深度线程 + YUV420 直传 |
| `G:\24youxi\VR3D\godot\VR3DXr\scripts\main.gd` | Godot 客户端：网络接收、纹理更新、窗口最小化 |
| `G:\24youxi\VR3D\godot\VR3DXr\shaders\dibr.gdshader` | YUV→RGB + DIBR 视差（VIEW_INDEX 左右眼） |
| `G:\24youxi\VR3D\godot\VR3DXr\scenes\Main.tscn` | QuadMesh 6×3.375（16:9） |
| `G:\24youxi\VR3D\godot\VR3DXr\project.godot` | OpenXR 配置（.bak 是备份） |
| `G:\24youxi\VR3D\venv\` | Python 环境（torch cu128） |
| `G:\24youxi\VR3D\models\` | MiDaS 模型 |
| `C:\Users\13767\Doubao\chats\2026-09-22\new-chat\nightfall-src\` | **Moonlight XR 参考源码**（见第七节） |

## 五、启动命令

```powershell
# 1. 服务端（游戏先开，窗口化/无边框）
G:\24youxi\VR3D\venv\Scripts\python.exe G:\24youxi\VR3D\midas_sbs_server.py 逆战

# 2. Godot 客户端（先戴头显 + VD 连接，OpenXR 才激活）
G:\24youxi\VR3D\godot\Godot_v4.4.1-stable_win64.exe --path G:\24youxi\VR3D\godot\VR3DXr
```

协议：`[4字节长度][YUV420 2560×1440×3/2][float32 深度 96×96]`，端口 **48372**。
Godot 常量：`COLOR_W/H=2560/1440`、`DEPTH_N=96`、`DEPTH_NEAR=1`。

## 六、已验证死路（不要重试）

1. **Godot 4.4.0**：全部 JPEG/PNG buffer 解码→ImageTexture 路径白/黑/灰屏 → **必须 4.4.1**（load_jpg_from_buffer err=0）
2. **Godot 4.6**：xrCreateInstance 失败
3. `VIEW_MATRIX[3][0]` 区分左右眼无效（OpenXR 双眼单色）→ **必须用 VIEW_INDEX**
4. SubViewport 中间层：4.4.0 弯路，直连 texture 更简
5. **SBS 双通道**（每眼半分辨率）：用户否决
6. GPU 缩放彩色图 → 23fps（和 MiDaS/Godot 抢 4080）→ 改回 CPU 裁切+转换
7. JPEG 压缩传输 → 30fps（编解码 CPU 开销）→ **YUV420 无损耗 50fps 胜出**
8. 泛红：shader 用 `:` source_color → 去掉修复
9. 蓝色显黄：视差 offset 过大颜色串扰 → DISPARITY 0.05→0.03
10. Codex CLI 配置（不相关但已踩）：新版 wire_api 必须 "responses"，"chat" 已弃用

## 七、Moonlight XR 源码（用户点名参考）

- **本地**：`C:\Users\13767\Doubao\chats\2026-09-22\new-chat\nightfall-src\`（42MB，Godot 工程，含 android/、models/、patches/）
- **在线**：`https://github.com/tB0nE/nightfall`（tB0nE/nightfall，作者 reddlx/tbone13billion）
- 用户实测 Moonlight XR（Pico 端 APK）：手机级 GPU 渲染 **120fps**、画面清晰颜色正；它**在头显端做深度估计+DIBR**。我们的方案反过来：**4080 做深度**，Pico 只解码，目标是更高分辨率不掉帧
- 参考点：它的深度估计实现（models/）、DIBR shader（depth_offset.gdshader）、YUV 处理管线

## 八、下一步（按优先级）

1. **VR 实测**：用户戴头显 + VD 连接 → 启动服务端 + Godot → 确认 OpenXR 画面、帧率、颜色、立体感
2. **性能**：若 VR 帧率不足 90：分析瓶颈（MiDaS 推理分辨率、YUV 转换、VD 编码）、尝试深度图更低分辨率/更轻模型
3. **回环问题**：正式游玩时桌面 Godot 窗口最小化（已加），验证捕获是否还正常
4. **体验**：DISPARITY/汇聚面微调；菜单、文字立体舒适度

## 九、项目根目录其他文件

`G:\24youxi\VR3D\` 下还有大量测试脚本/截图（bench_*.py、test_*.py、*.png），
README.md 是 **v6 旧版（SBS 方案）**，已被 v9 取代，仅供历史参考。

## 十、2026-09-23 进展（Codex 续作）

### 1. 45fps 的根因 = Virtual Desktop 的 SSW
- Pico 4 的 VD 里 **SSW（Synchronous Spacewarp）必须关闭**。开着时无论 PC 多快都被锁在 45fps（90Hz 的半帧）。
- 关闭后：极简 `--solid` 模式 90.0fps，完整 composition layer + Python 全链路 engine 稳定 90.0fps。
- 所以 4080 只有 45fps 不是算力问题，是 VD 的补帧策略。

### 2. 当前真实性能（2560x1792 composition 视口，12 秒采样）
- 捕获 88.9fps / copy 1.32ms
- 深度 29.6fps / 单次推理 8.58ms
- 发送 88.6fps / i420 0.80ms / send+ack 3.75ms
- Godot engine 90.0fps（采样 90/89/90/90）
- Godot 新帧应用 81.9fps，texture apply 1.57ms
- 接收线程 89.9fps / payload 2.52ms

### 3. 关键坑：composition 视口尺寸 ≠ 桌面分辨率
幕布是 **1.43:1（IMAX）**，桌面是 **16:9**，`dibr_canvas.gdshader` 会上下留黑边把 16:9 内容放进 1.43 幕布。
因此 `COMP_VIEWPORT_SIZE.y` 只有约 80.4% 用来显示桌面：

| 视口 | 实际桌面内容像素 | 结果 |
|---|---|---|
| 1280x896 | 1280x720 | 720p，糊 |
| 2560x1440 | 2560x1158 | 被缩放，不够锐 |
| **2560x1792** | **2560x1440** | **与桌面 1:1，推荐** |

公式：`视口高度 = 桌面高度 / (1.43 / (16/9)) = 1440 / 0.8044 ≈ 1792`

- 默认值已改为 `Vector2i(2560, 1792)`（`scripts/xr_composition_video.gd`）。
- 新增命令行开关 `--comp-viewport=WxH` 做 A/B，不用改代码：
  `powershell -File .code\diagnose_live.ps1 -Xr -VisibleWindow -CompViewport 2560x1792 -Seconds 12`

### 4. 诊断脚本新增参数
`-CompViewport 2560x1792`（另有既有的 `-Xr -VisibleWindow -Mesh -NoUi -NoTexture -Solid -NoStream -RenderScale -DepthFps`）

### 5. 已知遗留
- 启动瞬间有 `xrWaitFrame() XR_ERROR_RUNTIME_FAILURE` / `XR_ERROR_TIME_INVALID`，1 秒内自动恢复，判定为 VDXR + Godot 4.7.2 启动时序问题，不影响运行。
- Godot 新帧应用率约 82fps，低于 engine 90fps；engine 已是满帧，剩余差异在纹理上传/接收侧。
- `start_vr3d.ps1` 日常启动用默认 2560x1792，无需额外参数。

### 6. 2026-09-23 傍晚：mesh 设为默认 + 屏幕默认位置重调

**根因回顾**：VDXR 1.0.9 不能可靠地按 `eye_visibility` 路由两个 composition layer
（双眼都只看到蓝色右眼层）；原生 mesh + `VIEW_INDEX` 已验证左右眼分离正常。
所以 **mesh 投影层改为默认路径**，composition layer 退居 `--composition` 实验开关。

**本次改动**

| 文件 | 改动 |
|---|---|
| `scripts/main.gd` | `use_composition := xr_active and ("--composition" in args)`，默认走 mesh；启动打印渲染路径 |
| `scripts/xr_settings_panel.gd` | 新增 `CONFIG_VERSION=2`；默认距离 2.4m / 高度 1.55m / 曲率 0.35；立体强度 0 视为无效并回落到 100%；旧版（composition 时代）配置的屏幕段自动忽略，只迁移立体参数 |
| `scenes/Main.tscn` | 默认变换改为 `(0, 1.55, -2.4)`，即 2.4m 远、略低于眼高 |
| `.code/verify_mesh_default.ps1` | 新增：8 秒桌面冒烟测试，验证脚本可运行并打印屏幕参数 |

**实测（2026-09-23 17:0x，OpenXR + VDXR）**

```
[VR3D] OpenXR 渲染倍率=1.00（请求 1.00）视口=(3168.0, 3168.0)
[VR3D] render path: mesh projection (default; --composition switches back)
[VR3D] settings: legacy screen values ignored (mesh defaults applied)
[VR3D] virtual screen: 3.218 x 2.250 m, aspect=1.4300 (IMAX 1.43:1), distance=2.40 m
[VR3D] stereo: strength=100% disparity=0.0300 convergence=40% swap_eyes=false
[PERF] engine=90.0 fps process=12.0 ms
[cap] events=90.0fps unique=90.0fps | [srv] 90.1 fps | [depth] 29.7fps infer=8.3ms
```

- 左右手柄均 `active=true tracked=true`，可用激光调设置。
- 旧配置备份：`.code/backups/20260923_165956_mesh_default_and_screen_defaults/`。

**遗留**：`--no-ui` 诊断模式不会创建设置面板，因此不会加载 `user://vr3d_settings.cfg`，
只会用场景/脚本默认值。以后做画面位置判断请用正式启动器 `start_vr3d.ps1`。

### 7. 2026-09-23 傍晚：加强前后深度

**用户反馈**：当前效果可以，但希望前后深度更明显、更夸张。

**改动**

| 文件 | 改动 |
|---|---|
| `scripts/xr_settings_panel.gd` | 配置版本升到 3；旧版（<3）立体强度一次性提升到至少 100%；立体强度步进 5%→10%，上限 100%→150%；说明文字更新 |
| `user://vr3d_settings.cfg` | 迁移后 `strength=1.0`；保留 `convergence=0.33`、`swap_eyes=true`、`distance=1.8`、`scale=1.1`、`height=0.55`、`curvature=0.55` |
| `HANDOFF.md` | 本记录 |

**验证**

```text
[VR3D] settings: stereo strength migrated 20% -> 100% for stronger depth
[VR3D] virtual screen: 3.539 x 2.475 m, aspect=1.4300 (IMAX 1.43:1), distance=1.80 m
[VR3D] stereo: strength=100% disparity=0.0300 convergence=33% swap_eyes=true
```

- 桌面冒烟测试通过，无脚本错误。
- 视差从 `0.006` 提升到 `0.030`（约 5 倍）；`0.03` 是此前验证不会明显色彩串扰的安全值。
- 设置面板里现在可以按 10% 步进调到 150%，对应视差 `0.045`，接近 MoonlightXR 的 `0.042`。
- 若 150% 仍不够，下一步应做 shader 的深度曲线或遮挡搜索，而不是继续盲目增大 disparity。
- 备份：`.code/backups/20260923_172729_stereo_depth_exaggeration/`。                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                                