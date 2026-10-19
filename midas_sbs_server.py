# -*- coding: utf-8 -*-
"""VR3D PC-side capture, depth estimation, and low-latency TCP transport.

Protocol:
    Stream config, sent once after connect:
        4s magic "V3D1", uint32 version, uint32 color width,
        uint32 color height, uint32 depth size
    Each frame:
        uint32 little-endian payload length
        YUV420/I420 bytes for the negotiated color width x height
        float32 depth map, depth size x depth size, normalized to [0, 1]

The color path deliberately stays on the CPU. Capture uses the selected DXGI
desktop output's native resolution; Godot receives the exact dimensions and
uses the same aspect for both the stream texture and the virtual canvas.
"""
from __future__ import annotations

import ctypes
from ctypes import wintypes
import os
import socket
import struct
import threading
import time
from pathlib import Path

# Keep native math libraries single-threaded by default. The depth input is only
# 96x96; extra OpenMP/MKL workers mostly spin and compete with the 90 Hz capture
# and transport threads. These must be set before importing torch.
os.environ.setdefault("OMP_NUM_THREADS", "1")
os.environ.setdefault("MKL_NUM_THREADS", "1")
os.environ.setdefault("OPENBLAS_NUM_THREADS", "1")
os.environ.setdefault("NUMEXPR_NUM_THREADS", "1")
os.environ.setdefault("OMP_WAIT_POLICY", "PASSIVE")

import cv2
import numpy as np
import torch

# Windows CUDA defaults to a spin-wait synchronisation policy. MiDaS is called
# from a dedicated Python thread, so that spin burns a large amount of CPU while
# the GPU finishes a very small 96x96 inference. cudaDeviceScheduleBlockingSync
# makes the thread sleep instead. The flag must be set before the first CUDA
# context is created; importing torch alone does not create one.
_CUDART = None
_CUDA_BLOCKING_SYNC_ENABLED = False
_CUDA_BLOCKING_SYNC_ERROR = ""


def _enable_cuda_blocking_sync() -> bool:
    global _CUDART, _CUDA_BLOCKING_SYNC_ERROR
    if os.name != "nt":
        return False
    if os.environ.get("VR3D_CUDA_BLOCKING_SYNC", "1").strip().lower() in {
        "0", "false", "no", "off",
    }:
        return False
    try:
        torch_dir = Path(torch.__file__).resolve().parent
        cudart_candidates = sorted((torch_dir / "lib").glob("cudart64_*.dll"))
        if not cudart_candidates:
            raise FileNotFoundError(f"cudart64_*.dll not found under {torch_dir / 'lib'}")
        cudart = ctypes.CDLL(str(cudart_candidates[-1]))
        cudart.cudaSetDeviceFlags.argtypes = [ctypes.c_uint]
        cudart.cudaSetDeviceFlags.restype = ctypes.c_int
        # cudaDeviceScheduleBlockingSync == 0x04
        result = int(cudart.cudaSetDeviceFlags(0x04))
        if result != 0:
            _CUDA_BLOCKING_SYNC_ERROR = f"cudaSetDeviceFlags returned {result}"
            return False
        _CUDART = cudart
        return True
    except Exception as exc:
        _CUDA_BLOCKING_SYNC_ERROR = str(exc)[:200]
        return False


_CUDA_BLOCKING_SYNC_ENABLED = _enable_cuda_blocking_sync()

# OpenCV otherwise fans the full-frame color conversion and resize out to all
# logical CPUs. That uses ~11.4 ms of CPU per frame on this machine for only
# ~0.8 ms of wall-clock gain. The 90 Hz sender has an 11.1 ms budget, so one
# OpenCV worker keeps latency safe while avoiding a large CPU spike.
cv2.setNumThreads(1)

# MiDaS runs on the GPU and only receives a 96x96 tensor. Letting PyTorch create
# 8 CPU workers for this workload costs far more in thread wakeups than it saves.
_TORCH_THREADS = max(1, int(os.environ.get("VR3D_TORCH_THREADS", "1")))
_TORCH_INTEROP_THREADS = max(
    1, int(os.environ.get("VR3D_TORCH_INTEROP_THREADS", "1"))
)
torch.set_num_threads(_TORCH_THREADS)
try:
    torch.set_num_interop_threads(_TORCH_INTEROP_THREADS)
except RuntimeError:
    # Some embedding hosts initialize the inter-op pool before importing us.
    pass

ROOT = Path(__file__).resolve().parent
MODEL = Path(os.environ.get("VR3D_MODEL", ROOT / "models" / "model-small-traced.pt"))
DEPTH_SIZE = 96
DEPTH_N = DEPTH_SIZE
PORT = int(os.environ.get("VR3D_PORT", "48372"))
STREAM_MAGIC = b"V3D1"
STREAM_CONFIG_VERSION = 1
STREAM_CONFIG_FORMAT = "<4sIIII"
STREAM_CONFIG_SIZE = struct.calcsize(STREAM_CONFIG_FORMAT)
# Fallback values used only before DXCam reports the real desktop dimensions.
COLOR_W, COLOR_H = 2560, 1440
CAP_FPS = max(1, int(os.environ.get("VR3D_CAPTURE_FPS", "90")))
SEND_FPS = max(1, int(os.environ.get("VR3D_SEND_FPS", "90")))
DEPTH_FPS = max(1, int(os.environ.get("VR3D_DEPTH_FPS", "30")))
# MoonlightXR-style post-processing. Robust percentile range and both range and
# per-texel EMA smoothing prevent MiDaS's frame-to-frame scale/noise breathing,
# which becomes obvious as edge jitter once disparity is increased.
DEPTH_PERCENTILE_CLIP = min(max(float(os.environ.get("VR3D_DEPTH_PERCENTILE", "0.02")), 0.0), 0.20)
DEPTH_RANGE_TAU_SECONDS = max(float(os.environ.get("VR3D_DEPTH_RANGE_TAU", "0.89")), 0.05)
DEPTH_SMOOTH_TAU_SECONDS = max(float(os.environ.get("VR3D_DEPTH_SMOOTH_TAU", "0.158")), 0.02)
FRAME_ACK = b"\x06"
DEPTH_PAYLOAD_SIZE = DEPTH_N * DEPTH_N * 4
PAYLOAD_SIZE = COLOR_W * COLOR_H * 3 // 2 + DEPTH_PAYLOAD_SIZE
DUPLICATE_PROTOCOL = os.environ.get("VR3D_DUPLICATE_PROTOCOL", "1").strip().lower() not in {"0", "false", "no", "off"}

HAS_CUDA = torch.cuda.is_available()
device = torch.device("cuda" if HAS_CUDA else "cpu")
MODEL_DTYPE = torch.float16 if HAS_CUDA else torch.float32
print(f"[init] device={device} model={MODEL}")
print(
    f"[init] capture_fps={CAP_FPS} send_fps={SEND_FPS} "
    f"depth_fps={DEPTH_FPS} depth_smooth={DEPTH_SMOOTH_TAU_SECONDS:.3f}s "
    f"range_smooth={DEPTH_RANGE_TAU_SECONDS:.2f}s clip={DEPTH_PERCENTILE_CLIP:.2f} "
    f"color=desktop(auto) "
    f"torch_threads={_TORCH_THREADS}/{_TORCH_INTEROP_THREADS} "
    f"cuda_blocking_sync={_CUDA_BLOCKING_SYNC_ENABLED}"
)

if not MODEL.is_file():
    raise FileNotFoundError(f"MiDaS model not found: {MODEL}")

# Load on CPU first so model loading does not depend on CUDA deserialization.
midas = torch.jit.load(str(MODEL), map_location="cpu").eval().to(device)
if HAS_CUDA:
    midas = midas.half()
else:
    midas = midas.float()

MEAN = torch.tensor([0.485, 0.456, 0.406], device=device, dtype=MODEL_DTYPE).view(3, 1, 1)
STD = torch.tensor([0.229, 0.224, 0.225], device=device, dtype=MODEL_DTYPE).view(3, 1, 1)
_warmed = False

CURSOR_ENABLED = os.environ.get("VR3D_CURSOR", "1").strip().lower() not in {
    "0", "false", "no", "off",
}
_CURSOR_SHOWING = 0x00000001
_MONITOR_DEFAULTTOPRIMARY = 0x00000001
_MONITORINFOF_PRIMARY = 0x00000001


class _CursorInfo(ctypes.Structure):
    _fields_ = [
        ("cbSize", wintypes.DWORD),
        ("flags", wintypes.DWORD),
        ("hCursor", wintypes.HANDLE),
        ("ptScreenPos", wintypes.POINT),
    ]


class _MonitorInfo(ctypes.Structure):
    _fields_ = [
        ("cbSize", wintypes.DWORD),
        ("rcMonitor", wintypes.RECT),
        ("rcWork", wintypes.RECT),
        ("dwFlags", wintypes.DWORD),
    ]


def _enable_physical_pixel_coordinates() -> None:
    """Keep Win32 cursor coordinates in the same physical-pixel space as DXGI."""
    if os.name != "nt":
        return
    user32 = ctypes.windll.user32
    try:
        # PER_MONITOR_AWARE_V2. This can legitimately fail if another library
        # already selected the process DPI mode, so fall back without logging.
        user32.SetProcessDpiAwarenessContext(ctypes.c_void_p(-4))
    except (AttributeError, OSError):
        try:
            user32.SetProcessDPIAware()
        except (AttributeError, OSError):
            pass


class SoftwareCursor:
    """Composite a small low-cost cursor directly into an I420 frame."""

    def __init__(self, enabled: bool = True) -> None:
        self.enabled = bool(enabled and os.name == "nt")
        self.user32 = ctypes.windll.user32 if self.enabled else None
        self.monitor_rect = (0, 0, COLOR_W, COLOR_H)
        self.outer_mask, self.inner_mask = self._make_arrow_masks()
        if not self.enabled:
            return

        self.user32.GetCursorInfo.argtypes = [ctypes.POINTER(_CursorInfo)]
        self.user32.GetCursorInfo.restype = wintypes.BOOL
        self.user32.MonitorFromPoint.argtypes = [wintypes.POINT, wintypes.DWORD]
        self.user32.MonitorFromPoint.restype = wintypes.HANDLE
        self.user32.GetMonitorInfoW.argtypes = [wintypes.HANDLE, ctypes.POINTER(_MonitorInfo)]
        self.user32.GetMonitorInfoW.restype = wintypes.BOOL
        self.monitor_rect = self._get_primary_monitor_rect()

    @staticmethod
    def _make_arrow_masks() -> tuple[np.ndarray, np.ndarray]:
        # The pointer tip is (0, 0). A dark outline remains visible on white UI,
        # while the bright fill remains visible on dark games.
        outer = np.zeros((34, 22), dtype=np.uint8)
        inner = np.zeros_like(outer)
        outer_points = np.array(
            [[0, 0], [0, 27], [7, 21], [13, 33], [18, 30], [12, 19], [21, 19]],
            dtype=np.int32,
        )
        inner_points = np.array(
            [[2, 5], [2, 22], [8, 17], [14, 28], [15, 27], [9, 16], [16, 16]],
            dtype=np.int32,
        )
        cv2.fillPoly(outer, [outer_points], 1)
        cv2.fillPoly(inner, [inner_points], 1)
        return outer.astype(bool), inner.astype(bool)

    def _get_primary_monitor_rect(self) -> tuple[int, int, int, int]:
        point = wintypes.POINT(0, 0)
        monitor = self.user32.MonitorFromPoint(point, _MONITOR_DEFAULTTOPRIMARY)
        info = _MonitorInfo()
        info.cbSize = ctypes.sizeof(_MonitorInfo)
        if monitor and self.user32.GetMonitorInfoW(monitor, ctypes.byref(info)):
            rect = info.rcMonitor
            return int(rect.left), int(rect.top), int(rect.right), int(rect.bottom)
        return (0, 0, COLOR_W, COLOR_H)

    def position_in_output(
        self,
        source_width: int,
        source_height: int,
        pad_x: int,
        pad_y: int,
        scaled_width: int,
        scaled_height: int,
    ) -> tuple[int, int] | None:
        if not self.enabled:
            return None
        info = _CursorInfo()
        info.cbSize = ctypes.sizeof(_CursorInfo)
        if not self.user32.GetCursorInfo(ctypes.byref(info)):
            return None
        if not (int(info.flags) & _CURSOR_SHOWING):
            return None

        # Display modes can change while Virtual Desktop/OpenXR is starting.
        # Refresh the monitor bounds so cursor mapping follows the current mode.
        self.monitor_rect = self._get_primary_monitor_rect()
        left, top, right, bottom = self.monitor_rect
        monitor_width = max(1, right - left)
        monitor_height = max(1, bottom - top)
        # Convert Win32 screen coordinates to the captured source, then apply the
        # exact same fit-and-pad transform used by the complete desktop image.
        local_x = (int(info.ptScreenPos.x) - left) * source_width / monitor_width
        local_y = (int(info.ptScreenPos.y) - top) * source_height / monitor_height
        output_x = round(pad_x + local_x * scaled_width / max(1, source_width))
        output_y = round(pad_y + local_y * scaled_height / max(1, source_height))
        return output_x, output_y

    def draw_i420(self, yuv: np.ndarray, position: tuple[int, int] | None) -> bool:
        if position is None:
            return False
        flat = yuv.reshape(-1)
        y_size = COLOR_W * COLOR_H
        uv_size = y_size // 4
        if flat.size != y_size + uv_size * 2:
            return False

        cursor_x, cursor_y = position
        mask_h, mask_w = self.outer_mask.shape
        x0 = max(0, cursor_x)
        y0 = max(0, cursor_y)
        x1 = min(COLOR_W, cursor_x + mask_w)
        y1 = min(COLOR_H, cursor_y + mask_h)
        if x0 >= x1 or y0 >= y1:
            return False

        mask_x0 = x0 - cursor_x
        mask_y0 = y0 - cursor_y
        mask_x1 = mask_x0 + (x1 - x0)
        mask_y1 = mask_y0 + (y1 - y0)
        outer = self.outer_mask[mask_y0:mask_y1, mask_x0:mask_x1]
        inner = self.inner_mask[mask_y0:mask_y1, mask_x0:mask_x1]

        y_plane = flat[:y_size].reshape(COLOR_H, COLOR_W)
        y_region = y_plane[y0:y1, x0:x1]
        y_region[outer] = 16
        y_region[inner] = 235

        # Neutralize chroma under the cursor so the black/white arrow is stable
        # regardless of the source image. Only a few hundred entries are touched.
        ys, xs = np.nonzero(outer)
        if ys.size:
            uv_y = (ys + y0) // 2
            uv_x = (xs + x0) // 2
            u_plane = flat[y_size:y_size + uv_size].reshape(COLOR_H // 2, COLOR_W // 2)
            v_plane = flat[y_size + uv_size:].reshape(COLOR_H // 2, COLOR_W // 2)
            u_plane[uv_y, uv_x] = 128
            v_plane[uv_y, uv_x] = 128
        return True

    def snapshot_i420(
        self,
        yuv: np.ndarray,
        position: tuple[int, int] | None,
    ) -> tuple[object, ...] | None:
        """Back up only the pixels a cursor draw can touch."""
        if position is None:
            return None
        flat = yuv.reshape(-1)
        y_size = COLOR_W * COLOR_H
        uv_size = y_size // 4
        if flat.size != y_size + uv_size * 2:
            return None

        cursor_x, cursor_y = position
        mask_h, mask_w = self.outer_mask.shape
        x0 = max(0, cursor_x)
        y0 = max(0, cursor_y)
        x1 = min(COLOR_W, cursor_x + mask_w)
        y1 = min(COLOR_H, cursor_y + mask_h)
        if x0 >= x1 or y0 >= y1:
            return None

        y_plane = flat[:y_size].reshape(COLOR_H, COLOR_W)
        u_plane = flat[y_size:y_size + uv_size].reshape(COLOR_H // 2, COLOR_W // 2)
        v_plane = flat[y_size + uv_size:].reshape(COLOR_H // 2, COLOR_W // 2)
        uv_x0 = max(0, x0 // 2)
        uv_y0 = max(0, y0 // 2)
        uv_x1 = min(COLOR_W // 2, (x1 + 1) // 2)
        uv_y1 = min(COLOR_H // 2, (y1 + 1) // 2)
        return (
            x0,
            y0,
            x1,
            y1,
            uv_x0,
            uv_y0,
            uv_x1,
            uv_y1,
            y_plane[y0:y1, x0:x1].copy(),
            u_plane[uv_y0:uv_y1, uv_x0:uv_x1].copy(),
            v_plane[uv_y0:uv_y1, uv_x0:uv_x1].copy(),
        )

    def restore_i420(self, yuv: np.ndarray, snapshot: tuple[object, ...] | None) -> bool:
        if snapshot is None:
            return False
        flat = yuv.reshape(-1)
        y_size = COLOR_W * COLOR_H
        uv_size = y_size // 4
        if flat.size != y_size + uv_size * 2:
            return False
        (
            x0,
            y0,
            x1,
            y1,
            uv_x0,
            uv_y0,
            uv_x1,
            uv_y1,
            y_backup,
            u_backup,
            v_backup,
        ) = snapshot
        y_plane = flat[:y_size].reshape(COLOR_H, COLOR_W)
        u_plane = flat[y_size:y_size + uv_size].reshape(COLOR_H // 2, COLOR_W // 2)
        v_plane = flat[y_size + uv_size:].reshape(COLOR_H // 2, COLOR_W // 2)
        y_plane[y0:y1, x0:x1] = y_backup
        u_plane[uv_y0:uv_y1, uv_x0:uv_x1] = u_backup
        v_plane[uv_y0:uv_y1, uv_x0:uv_x1] = v_backup
        return True


_enable_physical_pixel_coordinates()


def _warmup() -> None:
    """Warm the traced model with the same tensor path used by make_depth()."""
    global _warmed
    if _warmed:
        return
    print("[init] warming MiDaS...")
    # Use the real input pipeline (uint8 HWC -> float NCHW -> normalized) and
    # synchronize every iteration. The first real inference used to trigger
    # lazy CUDA/cuDNN work and block the sender for >12 s.
    warm_cpu = torch.randint(
        0, 256, (DEPTH_SIZE, DEPTH_SIZE, 3), dtype=torch.uint8
    )
    warm = warm_cpu.permute(2, 0, 1).to(device=device, dtype=MODEL_DTYPE)
    warm.div_(255.0)
    warm = (warm - MEAN) / STD
    warm = warm.unsqueeze(0).contiguous()
    with torch.inference_mode():
        for _ in range(5):
            midas(warm)
            if HAS_CUDA:
                torch.cuda.synchronize()
    _warmed = True
    print("[init] warmup complete")


# INTER_AREA with a ratio far from integral is unexpectedly slow in OpenCV: a
# direct 2560x1440 -> 96x96 pass costs ~7.3 ms per frame, which is more than the
# MiDaS inference it feeds. Pre-reducing to roughly 640 px on the long edge with
# an integral factor lets INTER_AREA use cheap box sums, so the same result costs
# ~1.5 ms. Measured mean absolute difference against the direct resize stays
# under 1.5/255 across 1280x720 .. 3840x2160.
DEPTH_PREEDGE = 640


def _downscale_to_depth_input(bgr: np.ndarray) -> np.ndarray:
    source_height, source_width = bgr.shape[:2]
    factor = max(1, int(round(max(source_width, source_height) / float(DEPTH_PREEDGE))))
    if factor > 1:
        stage_width = max(DEPTH_SIZE, source_width // factor)
        stage_height = max(DEPTH_SIZE, source_height // factor)
        if stage_width != source_width or stage_height != source_height:
            bgr = cv2.resize(
                bgr, (stage_width, stage_height), interpolation=cv2.INTER_AREA
            )
    return cv2.resize(bgr, (DEPTH_SIZE, DEPTH_SIZE), interpolation=cv2.INTER_AREA)


def _downscale_bgra_to_depth_input(bgra: np.ndarray) -> np.ndarray:
    """Reduce BGRA directly without a full-frame BGR conversion.

    OpenCV's INTER_AREA on the four-channel desktop is much slower than on
    BGR. The first reduction therefore uses INTER_LINEAR, while the final
    640x360 -> 96x96 pass keeps INTER_AREA. On a real desktop frame this
    changed the normalized MiDaS output by only ~0.0016 (correlation
    0.99998 versus the previous BGR path).
    """
    source_height, source_width = bgra.shape[:2]
    factor = max(1, int(round(max(source_width, source_height) / float(DEPTH_PREEDGE))))
    if factor > 1:
        stage_width = max(DEPTH_SIZE, source_width // factor)
        stage_height = max(DEPTH_SIZE, source_height // factor)
        if stage_width != source_width or stage_height != source_height:
            bgra = cv2.resize(
                bgra, (stage_width, stage_height), interpolation=cv2.INTER_LINEAR
            )
    return cv2.resize(bgra, (DEPTH_SIZE, DEPTH_SIZE), interpolation=cv2.INTER_AREA)


def make_depth(
    frame: np.ndarray,
    *,
    bgra: bool = False,
    downscaled: bool = False,
) -> np.ndarray:
    """Estimate raw inverse depth and return contiguous float32 CPU data."""
    # MiDaS only consumes 96x96. The capture thread may already have produced
    # that small input from the zero-copy BGRA view, avoiding another full-frame
    # resize in the depth worker.
    small = frame if downscaled else _downscale_to_depth_input(frame)
    color_code = cv2.COLOR_BGRA2RGB if bgra else cv2.COLOR_BGR2RGB
    rgb_small = cv2.cvtColor(small, color_code)
    rgb_small = np.ascontiguousarray(rgb_small)
    image = torch.from_numpy(rgb_small).permute(2, 0, 1)
    image = image.to(device=device, dtype=MODEL_DTYPE).div_(255.0)
    image = (image - MEAN) / STD

    with torch.inference_mode():
        output = midas(image.unsqueeze(0))
    if isinstance(output, (tuple, list)):
        output = output[0]
    while output.ndim > 2:
        output = output[0]

    return np.ascontiguousarray(output.float().cpu().numpy(), dtype=np.float32)



class DepthPostProcessor:
    """Stabilize MiDaS depth with MoonlightXR's robust range and temporal EMA.

    MiDaS returns relative depth, so independent min/max normalization every
    inference makes the whole image subtly breathe. At high disparity that looks
    like edge jitter. MoonlightXR instead clips a percentile range, smooths the
    range over time, then applies a per-texel EMA to the normalized depth.
    """

    def __init__(self) -> None:
        self._smooth_lo = 0.0
        self._smooth_hi = 1.0
        self._smoothed: np.ndarray | None = None
        self._last_time = 0.0
        self._range_valid = False

    def process(self, raw_depth: np.ndarray) -> np.ndarray:
        raw = np.nan_to_num(
            np.asarray(raw_depth, dtype=np.float32),
            nan=0.0,
            posinf=0.0,
            neginf=0.0,
        )
        lo, hi = np.percentile(
            raw,
            [DEPTH_PERCENTILE_CLIP * 100.0, (1.0 - DEPTH_PERCENTILE_CLIP) * 100.0],
        )
        if hi <= lo:
            hi = lo + 1e-3

        now = time.perf_counter()
        if self._last_time <= 0.0:
            dt = DEPTH_SMOOTH_TAU_SECONDS
        else:
            dt = min(max(now - self._last_time, 1.0 / 60.0), 1.0)
        self._last_time = now

        if not self._range_valid:
            self._smooth_lo = float(lo)
            self._smooth_hi = float(hi)
            self._range_valid = True
        else:
            range_alpha = 1.0 - np.exp(-dt / DEPTH_RANGE_TAU_SECONDS)
            self._smooth_lo += range_alpha * (float(lo) - self._smooth_lo)
            self._smooth_hi += range_alpha * (float(hi) - self._smooth_hi)

        scale = 1.0 / max(self._smooth_hi - self._smooth_lo, 1e-6)
        normalized = np.clip((raw - self._smooth_lo) * scale, 0.0, 1.0)

        if self._smoothed is None or self._smoothed.shape != normalized.shape:
            self._smoothed = normalized.copy()
        else:
            depth_alpha = 1.0 - np.exp(-dt / DEPTH_SMOOTH_TAU_SECONDS)
            self._smoothed += depth_alpha * (normalized - self._smoothed)

        return np.ascontiguousarray(self._smoothed, dtype=np.float32)


def serve() -> None:
    global COLOR_W, COLOR_H, PAYLOAD_SIZE

    import dxcam

    cap_lock = threading.Lock()
    # Each entry is (transport_i420, depth_source_96_bgra, transform). The
    # transport I420 frame uses the selected desktop output's dimensions.
    # depth_source is already reduced from the complete desktop, so MiDaS sees
    # every desktop pixel without carrying another full-resolution frame through
    # the Python heap.
    cap_data: list[tuple[np.ndarray, np.ndarray, tuple[int, int, int, int, int, int]] | None] = [None]
    cap_seq = [0]
    errors = [0]

    # Capture display output 0 with its native desktop dimensions. BGRA is
    # DXcam's zero-conversion path; I420 conversion happens directly from it.
    camera = dxcam.create(output_idx=0, output_color="BGRA")
    if camera is None:
        raise RuntimeError("dxcam initialization failed")

    camera_width = int(getattr(camera, "width", 0) or 0)
    camera_height = int(getattr(camera, "height", 0) or 0)
    if camera_width < 2 or camera_height < 2:
        raise RuntimeError(
            f"dxcam reported invalid desktop size {camera_width}x{camera_height}"
        )
    # YUV420 needs even dimensions. Normal desktop modes are already even; a
    # one-pixel reduction keeps unusual/odd modes transport-safe.
    COLOR_W = camera_width - (camera_width % 2)
    COLOR_H = camera_height - (camera_height % 2)
    if COLOR_W < 2 or COLOR_H < 2:
        raise RuntimeError(
            f"desktop size cannot be represented as I420: {camera_width}x{camera_height}"
        )
    PAYLOAD_SIZE = COLOR_W * COLOR_H * 3 // 2 + DEPTH_PAYLOAD_SIZE
    stream_config = struct.pack(
        STREAM_CONFIG_FORMAT,
        STREAM_MAGIC,
        STREAM_CONFIG_VERSION,
        COLOR_W,
        COLOR_H,
        DEPTH_N,
    )
    print(
        f"[cap] desktop output={camera_width}x{camera_height} "
        f"transport={COLOR_W}x{COLOR_H} aspect={COLOR_W / COLOR_H:.5f} "
        f"payload={PAYLOAD_SIZE / 1024 / 1024:.2f}MiB"
    )
    software_cursor = SoftwareCursor(CURSOR_ENABLED)
    cursor_state = "on" if software_cursor.enabled else "off"

    transform_last: list[tuple[int, int, int, int, int, int] | None] = [None]

    def normalize_frame(
        frame: np.ndarray | None,
    ) -> tuple[np.ndarray, np.ndarray, tuple[int, int, int, int, int, int]] | None:
        if frame is None or frame.ndim != 3 or frame.shape[2] not in (3, 4):
            return None
        source_height, source_width = frame.shape[:2]
        if source_width < 2 or source_height < 2:
            return None
        is_bgra = frame.shape[2] == 4

        # Reduce the original desktop for MiDaS before any letterboxing. This
        # reads the zero-copy DXcam ring view once and produces only 96x96.
        depth_small = (
            _downscale_bgra_to_depth_input(frame)
            if is_bgra
            else _downscale_to_depth_input(frame)
        )

        if source_width == COLOR_W and source_height == COLOR_H:
            transport = frame
            resize_state = "native"
        else:
            # The negotiated transport follows the desktop aspect. A resize here
            # only covers an odd-pixel desktop or a display-mode change after the
            # stream was configured; no synthetic letterboxing is added.
            interpolation = (
                cv2.INTER_AREA
                if source_width > COLOR_W or source_height > COLOR_H
                else cv2.INTER_LINEAR
            )
            transport = np.ascontiguousarray(
                cv2.resize(frame, (COLOR_W, COLOR_H), interpolation=interpolation)
            )
            resize_state = "scaled"

        # Direct BGRA -> I420 is one conversion and one write. The old path did
        # DXcam BGRA->BGR, frame_view.copy(), then BGR->I420 in the sender.
        # BGR remains supported for the fake-camera/older-DXcam fallback path.
        yuv_code = cv2.COLOR_BGRA2YUV_I420 if is_bgra else cv2.COLOR_BGR2YUV_I420
        transport_i420 = np.ascontiguousarray(cv2.cvtColor(transport, yuv_code))

        transform = (
            source_width,
            source_height,
            0,
            0,
            COLOR_W,
            COLOR_H,
        )
        if transform_last[0] != transform:
            print(
                f"[cap] full desktop={source_width}x{source_height} -> "
                f"transport={COLOR_W}x{COLOR_H} ({resize_state}, no crop)"
            )
            transform_last[0] = transform
        return transport_i420, depth_small, transform

    def grab_loop() -> None:
        last_frame_time: float | None = None
        capture_events = 0
        capture_unique = 0
        capture_fetch_total = 0.0
        capture_process_total = 0.0
        stats_started = time.perf_counter()

        def report_stats() -> None:
            nonlocal capture_events, capture_unique
            nonlocal capture_fetch_total, capture_process_total
            nonlocal stats_started
            stats_now = time.perf_counter()
            if stats_now - stats_started < 2.0:
                return
            elapsed = stats_now - stats_started
            avg_fetch_ms = (
                capture_fetch_total * 1000.0 / capture_events
                if capture_events
                else 0.0
            )
            avg_process_ms = (
                capture_process_total * 1000.0 / capture_unique
                if capture_unique
                else 0.0
            )
            print(
                f"[cap] events={capture_events / elapsed:.1f}fps "
                f"unique={capture_unique / elapsed:.1f}fps "
                f"wait={avg_fetch_ms:.1f}ms "
                f"convert={avg_process_ms:.1f}ms"
            )
            capture_events = 0
            capture_unique = 0
            capture_fetch_total = 0.0
            capture_process_total = 0.0
            stats_started = stats_now

        while True:
            try:
                # get_latest_frame blocks on dxcam's frame-available event, so
                # an idle desktop no longer spins this thread at ~1000 Hz.
                fetch_started = time.perf_counter()
                latest = camera.get_latest_frame(copy=False, with_timestamp=True)
                fetch_elapsed = time.perf_counter() - fetch_started
                if latest is None:
                    time.sleep(0.001)
                    continue
                frame_view, frame_time = latest
                capture_events += 1
                capture_fetch_total += fetch_elapsed

                # video_mode repeats the previous frame with the same tick.
                # Skip duplicates before copying the full desktop image.
                if frame_time == last_frame_time:
                    report_stats()
                    continue
                last_frame_time = frame_time

                # frame_view points directly at DXcam's ring slot. Consume it
                # immediately; at 90 Hz the slot is not reused for ~8 frames.
                normalize_started = time.perf_counter()
                normalized = normalize_frame(frame_view)
                normalize_elapsed = time.perf_counter() - normalize_started
                if normalized is not None:
                    with cap_lock:
                        cap_data[0] = normalized
                        cap_seq[0] += 1
                    capture_unique += 1
                    capture_process_total += normalize_elapsed

                report_stats()
            except Exception as exc:
                if errors[0] < 3:
                    errors[0] += 1
                    print(f"[cap] capture error: {str(exc)[:160]}")
                time.sleep(0.01)

    latest_depth: list[np.ndarray | None] = [None]
    latest_depth_seq = [0]
    depth_lock = threading.Lock()

    depth_warmup_done = threading.Event()
    depth_post = DepthPostProcessor()

    def depth_worker() -> None:
        try:
            _warmup()
        except Exception as exc:
            print(f"[init] warmup failed: {str(exc)[:160]}")
        finally:
            depth_warmup_done.set()

        seen_seq = -1
        interval = 1.0 / DEPTH_FPS
        depth_count = 0
        depth_total = 0.0
        stats_started = time.perf_counter()
        while True:
            with cap_lock:
                captured = cap_data[0]
                sequence = cap_seq[0]
            if captured is None or sequence == seen_seq:
                time.sleep(0.002)
                continue
            seen_seq = sequence
            infer_started = time.perf_counter()
            try:
                _transport_i420, depth_source, _transform = captured
                depth_is_bgra = depth_source.ndim == 3 and depth_source.shape[2] == 4
                depth = depth_post.process(
                    make_depth(
                        depth_source,
                        bgra=depth_is_bgra,
                        downscaled=True,
                    )
                )
                infer_elapsed = time.perf_counter() - infer_started
                with depth_lock:
                    latest_depth[0] = depth
                    latest_depth_seq[0] = sequence
                depth_count += 1
                depth_total += infer_elapsed
            except Exception as exc:
                infer_elapsed = time.perf_counter() - infer_started
                if errors[0] < 3:
                    errors[0] += 1
                    print(f"[depth] inference error: {str(exc)[:160]}")

            stats_now = time.perf_counter()
            if stats_now - stats_started >= 2.0:
                stats_elapsed = stats_now - stats_started
                avg_infer_ms = (
                    depth_total * 1000.0 / depth_count if depth_count else 0.0
                )
                print(
                    f"[depth] {depth_count / stats_elapsed:.1f}fps "
                    f"| infer={avg_infer_ms:.1f}ms"
                )
                depth_count = 0
                depth_total = 0.0
                stats_started = stats_now

            if infer_elapsed < interval:
                time.sleep(interval - infer_elapsed)

    threading.Thread(target=depth_worker, name="vr3d-depth", daemon=True).start()
    if not depth_warmup_done.wait(timeout=60.0):
        print("[init] warmup timed out after 60s; starting capture anyway")

    # Start capture only after the depth worker has completed its own CUDA
    # warmup. PyTorch lazy CUDA initialization is per-thread, so warming on
    # the main thread did not prevent a ~15 s stall on the first real frame.
    camera.start(target_fps=CAP_FPS, video_mode=not DUPLICATE_PROTOCOL)
    print(f"[cap] started output=0 target_fps={CAP_FPS} software_cursor={cursor_state}")
    threading.Thread(target=grab_loop, name="vr3d-capture", daemon=True).start()

    server = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
    server.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
    server.bind(("127.0.0.1", PORT))
    server.listen(1)
    print(f"[srv] listening on 127.0.0.1:{PORT}")

    conn: socket.socket | None = None
    sent_seq = -1
    sent_depth_seq = -1
    sent_cursor_position: tuple[int, int] | None = None
    sent_transform: tuple[int, int, int, int, int, int] | None = None
    depth_deadline = 0.0
    depth_fallback_logged = False
    frame_count = 0
    full_count = 0
    depth_count = 0
    heartbeat_count = 0
    stats_started = time.perf_counter()
    encode_total = 0.0
    transport_total = 0.0
    send_interval = 1.0 / SEND_FPS
    next_send = 0.0
    payload_header = struct.pack("<I", PAYLOAD_SIZE)
    depth_header = struct.pack("<I", DEPTH_PAYLOAD_SIZE)
    heartbeat_header = struct.pack("<I", 0)

    try:
        while True:
            if conn is None:
                conn, addr = server.accept()
                conn.setsockopt(socket.IPPROTO_TCP, socket.TCP_NODELAY, 1)
                conn.setsockopt(socket.SOL_SOCKET, socket.SO_SNDBUF, PAYLOAD_SIZE * 2)
                # Wait for the receiver after each frame so TCP cannot become a latency queue.
                conn.settimeout(5.0)
                # Negotiate the exact transport dimensions before the first
                # frame. Godot uses this to rebuild textures/viewports and to
                # set the canvas aspect to the desktop aspect.
                conn.sendall(stream_config)
                sent_seq = -1
                sent_depth_seq = -1
                sent_cursor_position = None
                sent_transform = None
                next_send = 0.0
                depth_deadline = 0.0
                depth_fallback_logged = False
                print(f"[srv] Godot connected: {addr}")

            now = time.perf_counter()
            if now < next_send:
                time.sleep(min(0.002, next_send - now))
                continue

            with cap_lock:
                captured = cap_data[0]
                sequence = cap_seq[0]
            # Send on the fixed cadence even when DXGI reports a repeated frame.
            # A 75-83 Hz source otherwise makes the 90 Hz XR render judder.
            if captured is None:
                time.sleep(0.001)
                continue

            base_yuv, _depth_source, transform = captured
            with depth_lock:
                depth = latest_depth[0]
                depth_sequence = latest_depth_seq[0]
            if depth is None:
                now = time.perf_counter()
                if depth_deadline <= 0.0:
                    depth_deadline = now + 2.0
                if now < depth_deadline:
                    time.sleep(0.002)
                    continue
                # Never hold the whole transport hostage to a cold model.
                # A neutral depth map lets the desktop appear immediately;
                # the first real MiDaS result replaces it as soon as it lands.
                depth = np.full((DEPTH_N, DEPTH_N), 0.5, dtype=np.float32)
                with depth_lock:
                    if latest_depth[0] is None:
                        latest_depth[0] = depth
                        latest_depth_seq[0] = sequence
                    depth = latest_depth[0]
                    depth_sequence = latest_depth_seq[0]
                if not depth_fallback_logged:
                    print("[srv] depth not ready after 2.0s; sending neutral depth")
                    depth_fallback_logged = True

            source_width, source_height, pad_x, pad_y, scaled_width, scaled_height = transform
            cursor_position = software_cursor.position_in_output(
                source_width,
                source_height,
                pad_x,
                pad_y,
                scaled_width,
                scaled_height,
            )
            needs_color = (
                not DUPLICATE_PROTOCOL
                or sequence != sent_seq
                or transform != sent_transform
                or cursor_position != sent_cursor_position
            )
            needs_depth = not DUPLICATE_PROTOCOL or depth_sequence != sent_depth_seq

            # Keep an absolute cadence instead of restarting the timer every frame.
            # This removes cumulative Windows sleep overshoot while clamping stalls so
            # the sender never bursts a queue of obsolete desktop frames.
            started = time.perf_counter()
            if next_send <= 0.0 or started - next_send > send_interval:
                next_send = started
            next_send += send_interval
            try:
                if needs_color:
                    # The capture thread already produced I420. Cursor
                    # compositing mutates the buffer, so back up only the small
                    # cursor rectangle instead of copying the full 5.3 MiB frame.
                    yuv = base_yuv
                    cursor_snapshot = None
                    if cursor_position is not None:
                        cursor_snapshot = software_cursor.snapshot_i420(yuv, cursor_position)
                        if cursor_snapshot is None:
                            # Very defensive fallback for an unexpected buffer shape.
                            yuv = base_yuv.copy()
                        software_cursor.draw_i420(yuv, cursor_position)
                    depth_array = np.asarray(depth, dtype=np.float32, order="C")
                    color_bytes = memoryview(yuv)
                    depth_bytes = memoryview(depth_array)
                    try:
                        if color_bytes.nbytes + depth_bytes.nbytes != PAYLOAD_SIZE:
                            actual_size = color_bytes.nbytes + depth_bytes.nbytes
                            print(f"[srv] skip invalid full payload length={actual_size} expected={PAYLOAD_SIZE}")
                            continue
                        encoded_at = time.perf_counter()
                        # Send the planes directly from their contiguous NumPy buffers;
                        # avoid building another 5.3 MiB concatenated payload every frame.
                        conn.sendall(payload_header)
                        conn.sendall(color_bytes)
                        conn.sendall(depth_bytes)
                        full_count += 1
                    finally:
                        if cursor_snapshot is not None:
                            software_cursor.restore_i420(yuv, cursor_snapshot)
                elif needs_depth:
                    depth_array = np.asarray(depth, dtype=np.float32, order="C")
                    depth_bytes = memoryview(depth_array)
                    if depth_bytes.nbytes != DEPTH_PAYLOAD_SIZE:
                        print(f"[srv] skip invalid depth payload length={depth_bytes.nbytes} expected={DEPTH_PAYLOAD_SIZE}")
                        continue
                    encoded_at = time.perf_counter()
                    conn.sendall(depth_header)
                    conn.sendall(depth_bytes)
                    depth_count += 1
                else:
                    # A 90 Hz heartbeat keeps the receiver cadence and ACK timing
                    # without resending an unchanged 5.3 MiB color frame.
                    encoded_at = time.perf_counter()
                    conn.sendall(heartbeat_header)
                    heartbeat_count += 1
                # ACK means the complete message reached Godot's single-slot mailbox.
                # Texture upload may happen later; stale pending frames are replaced.
                ack = conn.recv(1)
                if ack != FRAME_ACK:
                    raise ConnectionError(f"invalid frame ACK: {ack!r}")
                completed_at = time.perf_counter()
                if needs_color:
                    sent_seq = sequence
                    sent_cursor_position = cursor_position
                    sent_transform = transform
                if needs_color or needs_depth:
                    sent_depth_seq = depth_sequence
                frame_count += 1
                encode_total += encoded_at - started
                transport_total += completed_at - encoded_at
                stats_now = completed_at
                if stats_now - stats_started >= 2.0:
                    fps = frame_count / (stats_now - stats_started)
                    avg_encode_ms = encode_total * 1000.0 / frame_count
                    avg_transport_ms = transport_total * 1000.0 / frame_count
                    print(
                        f"[srv] {fps:.1f} fps | full={full_count} depth={depth_count} hb={heartbeat_count} "
                        f"| full_payload={PAYLOAD_SIZE / 1024 / 1024:.2f}MiB "
                        f"| prep={avg_encode_ms:.2f}ms | send/ack={avg_transport_ms:.2f}ms"
                    )
                    frame_count = 0
                    full_count = 0
                    depth_count = 0
                    heartbeat_count = 0
                    encode_total = 0.0
                    transport_total = 0.0
                    stats_started = stats_now
            except (ConnectionResetError, BrokenPipeError, ConnectionError, socket.timeout, OSError) as exc:
                print(f"[srv] Godot disconnected ({type(exc).__name__}); waiting to reconnect")
                try:
                    conn.close()
                except OSError:
                    pass
                conn = None
                time.sleep(0.25)
    except KeyboardInterrupt:
        print("[srv] stopping")
    finally:
        if conn is not None:
            try:
                conn.close()
            except OSError:
                pass
        try:
            camera.stop()
        except Exception:
            pass
        server.close()


def main() -> None:
    # Capture display output 0 directly. No process/window lookup, focus change,
    # injection, or game-specific handling is performed.
    print("[mode] desktop capture: display output 0 (no target process)")
    serve()


if __name__ == "__main__":
    main()
