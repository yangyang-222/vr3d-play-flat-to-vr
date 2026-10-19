# -*- coding: utf-8 -*-
"""
PC端 MiDaS 2D→3D 转 SBS 工具 v5 —— 游戏窗口捕获版（无需虚拟显示器！）

原理: Windows GraphicsCapture 捕获【游戏窗口内容】本身（不是屏幕合成）
      → 即使 SBS 窗口盖住屏幕，也不会把自己捕获进去（无递归）
      → 游戏照常在物理屏玩，SBS 窗口无边框居中显示
      → VD 串流物理屏 + 3D 模式(SBS) = 整个画面立体

用法:
  python midas_sbs.py live [窗口标题关键词]   # 默认找"逆战"
  python midas_sbs.py shot                    # 截游戏窗口一帧生成测试图
"""
import sys, time, threading, ctypes
import numpy as np
import torch
import cv2

# 单实例锁（防止两个 live 互相抢捕获）
import socket
_lock = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
try:
    _lock.bind(("127.0.0.1", 48371))
    _lock.listen(1)
except OSError:
    print("[err] 另一个实例已在运行，请先关掉它（任务管理器结束 python）")
    sys.exit(1)

MODEL = r"G:\24youxi\VR3D\models\model-small-traced.pt"
DISPARITY = 0.008
CONVERGENCE = 0.5
DEPTH_SIZE = 256

# 屏幕分辨率（动态获取，SBS 铺满全屏）
_user32 = ctypes.windll.user32
SCR_W = _user32.GetSystemMetrics(0)
SCR_H = _user32.GetSystemMetrics(1)
OUT_W, OUT_H = SCR_W // 2, SCR_H          # 每眼分辨率（VD 3D SBS = 屏幕分半）
WARP_W, WARP_H = 640, 640 * SCR_H // (SCR_W // 2)   # 低分辨率 warp（同比例，清晰度提升）

device = torch.device("cuda" if torch.cuda.is_available() else "cpu")
print(f"[init] 设备: {device}")
midas = torch.jit.load(MODEL, map_location="cpu").eval().to(device).half()
MEAN = torch.tensor([0.485, 0.456, 0.406], device=device).view(3, 1, 1).half()
STD = torch.tensor([0.229, 0.224, 0.225], device=device).view(3, 1, 1).half()
_warmed = False


def _warmup():
    global _warmed
    if _warmed:
        return
    print("[init] 首次 CUDA 预热（约15秒，仅一次）...")
    z = torch.zeros(1, 3, DEPTH_SIZE, DEPTH_SIZE, device=device).half()
    with torch.no_grad():
        for _ in range(3):
            midas(z)
    torch.cuda.synchronize()
    _warmed = True
    print("[init] 预热完成")


def estimate_depth_t_np(small_rgb):
    img = torch.from_numpy(small_rgb).permute(2, 0, 1).float().div(255.0).to(device).half()
    img = (img - MEAN) / STD
    with torch.no_grad():
        disp = midas(img.unsqueeze(0))
    d = disp[0]
    dmin, dmax = d.min(), d.max()
    d = (d - dmin) / (dmax - dmin + 1e-6)
    d = torch.nn.functional.interpolate(d[None, None], size=(WARP_H, WARP_W),
                                        mode="bilinear", align_corners=False)
    return d


_GX = _GY = None


def _get_grid():
    global _GX, _GY
    if _GX is None:
        xs = torch.linspace(-1, 1, WARP_W, device=device)
        ys = torch.linspace(-1, 1, WARP_H, device=device)
        _GY, _GX = torch.meshgrid(ys, xs, indexing="ij")
    return _GX, _GY


def dibr_sbs_t_np(bgr_low, depth):
    """低分辨率 warp + 放大到 OUT SBS"""
    w = WARP_W
    depth_low = depth.float()
    disp_px = DISPARITY * w
    shift = disp_px * (depth_low[0, 0] - CONVERGENCE)
    gx, gy = _get_grid()
    norm_shift = 2.0 * shift / w
    grid_l = torch.stack([(gx + norm_shift).clamp(-1, 1), gy], dim=-1).unsqueeze(0)
    grid_r = torch.stack([(gx - norm_shift).clamp(-1, 1), gy], dim=-1).unsqueeze(0)
    grids = torch.cat([grid_l, grid_r], dim=0)
    bgr_t = torch.from_numpy(bgr_low).permute(2, 0, 1).float().to(device) / 255.0
    bgr_t = torch.cat([bgr_t[None], bgr_t[None]], dim=0)
    both = torch.nn.functional.grid_sample(bgr_t, grids, mode="bilinear",
                                           padding_mode="border", align_corners=False)
    sbs_low = torch.cat([both[0], both[1]], dim=-1)
    out = sbs_low.permute(1, 2, 0).contiguous().mul(255.0).to(torch.uint8)
    out = torch.nn.functional.interpolate(
        out[None].permute(0, 3, 1, 2).float(), size=(OUT_H, 2 * OUT_W),
        mode="bilinear", align_corners=False)[0]
    return out.permute(1, 2, 0).contiguous().to(torch.uint8).cpu().numpy()


# ---------- 找窗口 ----------
def find_window(keyword="逆战"):
    """按标题找可见窗口，返回 (hwnd, title)"""
    user32 = ctypes.windll.user32
    EnumWindowsProc = ctypes.WINFUNCTYPE(ctypes.c_bool, ctypes.c_void_p, ctypes.c_void_p)
    found = []

    def cb(hwnd, lparam):
        if user32.IsWindowVisible(hwnd):
            n = user32.GetWindowTextLengthW(hwnd)
            if n > 0:
                buf = ctypes.create_unicode_buffer(n + 1)
                user32.GetWindowTextW(hwnd, buf, n + 1)
                if keyword in buf.value:
                    found.append((hwnd, buf.value))
        return True

    user32.EnumWindows(EnumWindowsProc(cb), 0)
    return found[0] if found else None


def bring_to_front(hwnd):
    """把窗口恢复到前台（GraphicsCapture 需要窗口至少部分可见）"""
    user32 = ctypes.windll.user32
    user32.ShowWindow(hwnd, 9)  # SW_RESTORE
    user32.SetForegroundWindow(hwnd)


# ---------- 无边框居中窗口 ----------
def make_borderless_centered(win_name, w, h):
    """创建无边框窗口并居中（物理屏中央），返回 hwnd"""
    cv2.namedWindow(win_name, cv2.WINDOW_NORMAL)
    cv2.resizeWindow(win_name, w, h)
    # 找到窗口 hwnd（OpenCV 用 Qt 时名字可能带后缀）
    user32 = ctypes.windll.user32
    hwnd = user32.FindWindowW(None, win_name)
    if not hwnd:
        hwnd = user32.FindWindowW(None, win_name + " ")
    if hwnd:
        style = user32.GetWindowLongW(hwnd, -16)  # GWL_STYLE
        style &= ~0x00C00000  # WS_CAPTION
        style &= ~0x00040000  # WS_THICKFRAME
        style &= ~0x00080000  # WS_SYSMENU
        user32.SetWindowLongW(hwnd, -16, style)
        # 屏幕尺寸
        sm_w = user32.GetSystemMetrics(0)
        sm_h = user32.GetSystemMetrics(1)
        x = (sm_w - w) // 2
        y = (sm_h - h) // 2
        user32.SetWindowPos(hwnd, -1, x, y, w, h, 0x0040)
        user32.SetWindowPos(hwnd, -2, 0, 0, 0, 0, 0x0001 | 0x0002)  # 置顶
    return hwnd


def main():
    mode = sys.argv[1] if len(sys.argv) > 1 else "live"
    keyword = sys.argv[2] if len(sys.argv) > 2 else "逆战"
    _warmup()

    win = find_window(keyword)
    if not win:
        print(f"[win] 没找到标题含「{keyword}」的窗口，请先打开游戏或用: python midas_sbs.py live <关键词>")
        return
    hwnd, title = win
    print(f"[win] 捕获窗口: {title} (hwnd={hwnd})")

    from windows_capture import WindowsCapture, Frame, InternalCaptureControl

    cap_lock = threading.Lock()
    cap_data = [None]
    cap_closed = [False]
    _err_shown = [0]

    capture = WindowsCapture(window_hwnd=hwnd, draw_border=False)

    @capture.event
    def on_frame_arrived(frame: Frame, capture_control: InternalCaptureControl):
        try:
            bgr = frame.convert_to_bgr().frame_buffer.copy()  # 只做一次拷贝（~2ms）
            with cap_lock:
                cap_data[0] = bgr
            if mode == "shot":
                capture_control.stop()  # shot 模式拿第一帧即停
        except Exception as e:
            if _err_shown[0] < 3:
                _err_shown[0] += 1
                print(f"[cap] 回调错误: {str(e)[:120]}")

    @capture.event
    def on_closed():
        cap_closed[0] = True

    if mode == "shot":
        capture.start()
        t0 = time.time()
        while cap_data[0] is None and not cap_closed[0] and time.time() - t0 < 15:
            time.sleep(0.05)
        time.sleep(0.3)
        if cap_data[0] is not None:
            bgr = cap_data[0]
            rgb = cv2.cvtColor(bgr, cv2.COLOR_BGR2RGB)
            small = cv2.resize(rgb, (DEPTH_SIZE, DEPTH_SIZE), interpolation=cv2.INTER_AREA)
            bgr_low = cv2.resize(bgr, (WARP_W, WARP_H), interpolation=cv2.INTER_AREA)
            depth = estimate_depth_t_np(small)
            sbs = dibr_sbs_t_np(bgr_low, depth)
            torch.cuda.synchronize()
            cv2.imwrite(r"G:\24youxi\VR3D\game_sbs_test.png", sbs)
            print("[shot] 已保存 game_sbs_test.png")
        else:
            print("[shot] 超时未拿到帧")
        return

    # live
    bring_to_front(hwnd)  # 拉游戏到前台，确保捕获能拿到帧
    time.sleep(0.5)
    print("[live] 启动捕获（专用线程）...")
    capture_control = capture.start_free_threaded()  # 非阻塞！
    print("[live] 捕获线程已启动，创建全屏窗口...")
    win_name = "SBS3D"
    cv2.namedWindow(win_name, cv2.WINDOW_NORMAL)
    cv2.setWindowProperty(win_name, cv2.WND_PROP_FULLSCREEN, cv2.WINDOW_FULLSCREEN)
    # 先显示一帧黑屏，确保窗口可见
    cv2.imshow(win_name, np.zeros((OUT_H, 2 * OUT_W, 3), np.uint8))
    cv2.waitKey(1)
    print(f"[live] 全屏窗口已创建（SBS {2*OUT_W}x{OUT_H}，每眼 {OUT_W}x{OUT_H}），进入主循环")

    fps = 0.0
    no_frame_t = time.time()
    try:
        while True:
            with cap_lock:
                bgr = cap_data[0]
            if bgr is None:
                if time.time() - no_frame_t > 15:
                    print("[err] 15秒没捕获到游戏帧——游戏是否最小化/被遮挡/独占全屏？请保持窗口可见")
                    break
                time.sleep(0.005); continue
            no_frame_t = time.time()
            rgb = cv2.cvtColor(bgr, cv2.COLOR_BGR2RGB)
            small = cv2.resize(rgb, (DEPTH_SIZE, DEPTH_SIZE), interpolation=cv2.INTER_AREA)
            bgr_low = cv2.resize(bgr, (WARP_W, WARP_H), interpolation=cv2.INTER_AREA)
            t0 = time.perf_counter()
            depth = estimate_depth_t_np(small)
            sbs = dibr_sbs_t_np(bgr_low, depth)
            torch.cuda.synchronize()
            dt = time.perf_counter() - t0
            fps = 0.9 * fps + 0.1 * (1.0 / max(dt, 1e-4))
            cv2.putText(sbs, f"{fps:.0f}fps d={DISPARITY} c={CONVERGENCE}",
                        (20, 40), cv2.FONT_HERSHEY_SIMPLEX, 1.0, (0, 255, 0), 2)
            cv2.imshow(win_name, sbs)
            if cv2.waitKey(1) & 0xFF == 27:
                break
    except KeyboardInterrupt:
        pass
    finally:
        try:
            capture_control.stop()
        except Exception:
            pass
        cv2.destroyAllWindows()


if __name__ == "__main__":
    main()
