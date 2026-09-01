#!/usr/bin/env bash

# Veno Gravador de Tela
# Gravador de tela simples para Linux em um único arquivo .sh.

set -u

if [ "${1:-}" = "--versao" ]; then
    printf '%s\n' "Veno Live Studio Lite 8.0 — Controle automático de vídeo"
    exit 0
fi

mostrar_erro() {
    local mensagem="$1"
    if command -v zenity >/dev/null 2>&1; then
        zenity --error --title="Veno Gravador de Tela" --width=560 --text="$mensagem"
    elif command -v kdialog >/dev/null 2>&1; then
        kdialog --error "$mensagem" --title "Veno Gravador de Tela"
    else
        printf '%s\n' "$mensagem" >&2
    fi
}

if ! command -v python3 >/dev/null 2>&1; then
    mostrar_erro "O Python 3 não está instalado.\n\nTiger OS/Ubuntu/Debian: sudo apt install python3 python3-tk"
    exit 1
fi

if ! python3 -c 'import tkinter' >/dev/null 2>&1; then
    mostrar_erro "A interface gráfica do Python não está instalada.\n\nTiger OS/Ubuntu/Debian: sudo apt install python3-tk"
    exit 1
fi

sessao_grafica="${XDG_SESSION_TYPE:-x11}"
if [ "$sessao_grafica" = "wayland" ]; then
    if ! command -v wf-recorder >/dev/null 2>&1; then
        mostrar_erro "A sessão atual usa Wayland e o wf-recorder não está instalado.\n\nUbuntu/Debian: sudo apt install wf-recorder\n\nSe sua distribuição não oferecer o wf-recorder, encerre a sessão e escolha uma sessão X11/Xorg."
        exit 1
    fi
elif ! command -v ffmpeg >/dev/null 2>&1; then
    mostrar_erro "O FFmpeg não está instalado.\n\nTiger OS/Ubuntu/Debian: sudo apt install ffmpeg\nFedora: sudo dnf install ffmpeg\nArch Linux: sudo pacman -S ffmpeg"
    exit 1
fi

exec python3 - "$@" <<'PYTHON_APP'
import datetime
import os
import re
import shutil
import signal
import subprocess
import sys
import tempfile
import threading
import time
import tkinter as tk
from collections import deque
from tkinter import colorchooser, filedialog, messagebox, simpledialog, ttk

try:
    from PIL import Image, ImageGrab, ImageTk
    PREVIEW_AVAILABLE = True
except ImportError:
    PREVIEW_AVAILABLE = False


APP_NAME = "Veno Live Studio Lite"


def detect_screen_size(root):
    try:
        result = subprocess.run(
            ["xrandr", "--current"],
            stdout=subprocess.PIPE,
            stderr=subprocess.DEVNULL,
            text=True,
            timeout=3,
            check=False,
        )
        match = re.search(r"current\s+(\d+)\s+x\s+(\d+)", result.stdout)
        if match:
            return int(match.group(1)), int(match.group(2))
    except (OSError, subprocess.SubprocessError):
        pass
    return root.winfo_screenwidth(), root.winfo_screenheight()


def list_audio_sources():
    sources = []
    if shutil.which("pactl"):
        try:
            result = subprocess.run(
                ["pactl", "list", "short", "sources"],
                stdout=subprocess.PIPE,
                stderr=subprocess.DEVNULL,
                text=True,
                timeout=4,
                check=False,
            )
            for line in result.stdout.splitlines():
                fields = line.split()
                if len(fields) >= 2 and fields[1] not in sources:
                    sources.append(fields[1])
        except (OSError, subprocess.SubprocessError):
            pass
    if not sources:
        sources.append("default")
    return ["Sem áudio"] + sources


def unique_output_path(folder, prefix, extension):
    safe_prefix = re.sub(r"[^A-Za-z0-9À-ÿ_-]+", "_", prefix.strip()).strip("_") or "gravacao_tela"
    timestamp = datetime.datetime.now().strftime("%Y-%m-%d_%H-%M-%S")
    candidate = os.path.join(folder, f"{safe_prefix}_{timestamp}.{extension}")
    counter = 2
    while os.path.exists(candidate):
        candidate = os.path.join(folder, f"{safe_prefix}_{timestamp}_{counter}.{extension}")
        counter += 1
    return candidate


def start_low_priority_process_group():
    os.setsid()
    try:
        os.nice(8)
    except OSError:
        pass


RESOLUTION_OPTIONS = [
    "854 × 480 (480p)",
    "1280 × 720 (720p)",
    "1600 × 900 (900p)",
    "1920 × 1080 (1080p)",
]


def resolution_for_bitrate(bitrate_kbps):
    """Escolhe a maior resolução segura definida para o bitrate informado."""
    bitrate_kbps = max(300, int(bitrate_kbps))
    if bitrate_kbps < 1000:
        return RESOLUTION_OPTIONS[0]
    if bitrate_kbps < 3000:
        return RESOLUTION_OPTIONS[1]
    if bitrate_kbps <= 10000:
        return RESOLUTION_OPTIONS[2]
    return RESOLUTION_OPTIONS[3]


def parse_resolution(value):
    if isinstance(value, (tuple, list)) and len(value) == 2:
        return max(2, int(value[0])), max(2, int(value[1]))
    match = re.search(r"(\d+)\s*[×xX]\s*(\d+)", str(value or ""))
    if match:
        return int(match.group(1)), int(match.group(2))
    return 854, 480


def detect_encoding_profile():
    cpu_name = "Processador do computador"
    try:
        with open("/proc/cpuinfo", "r", encoding="utf-8", errors="replace") as cpu_file:
            for line in cpu_file:
                if line.lower().startswith("model name"):
                    cpu_name = line.split(":", 1)[1].strip()
                    break
    except OSError:
        pass
    cpu_name = re.sub(r"\s+", " ", cpu_name)
    cores = max(1, os.cpu_count() or 1)
    memory_gb = 0.0
    try:
        with open("/proc/meminfo", "r", encoding="utf-8") as memory_file:
            match = re.search(r"MemTotal:\s+(\d+)", memory_file.read())
            if match:
                memory_gb = int(match.group(1)) / 1024 / 1024
    except OSError:
        pass

    if cores <= 2 or (memory_gb and memory_gb < 4):
        return cpu_name, cores, memory_gb, "ultrafast", 1, 15, "Econômico"
    if cores <= 4 or (memory_gb and memory_gb < 8):
        return cpu_name, cores, memory_gb, "veryfast", min(2, cores), 30, "Equilibrado"
    return cpu_name, cores, memory_gb, "veryfast", min(4, max(2, cores - 1)), 60, "Desempenho"


def append_visual_source_inputs(command, sources, fps):
    entries = []
    input_index = 1
    for source in sources or []:
        source_type = source.get("type")
        path = source.get("path")
        if source_type == "image" and path and os.path.isfile(path):
            command += ["-thread_queue_size", "64", "-loop", "1", "-framerate", str(fps), "-i", path]
            entries.append((source, input_index))
            input_index += 1
        elif source_type == "video" and path and os.path.isfile(path):
            command += ["-thread_queue_size", "64", "-stream_loop", "-1", "-re", "-i", path]
            entries.append((source, input_index))
            input_index += 1
    return entries, input_index


def build_visual_filter(sources, visual_entries, output_width, output_height, base_filter):
    filters = [f"[0:v]{base_filter},setpts=PTS-STARTPTS[base0]"]
    current = "base0"
    for number, (source, input_index) in enumerate(visual_entries, start=1):
        source_width = max(2, int(float(source.get("w", 0.25)) * output_width))
        source_height = max(2, int(float(source.get("h", 0.25)) * output_height))
        x = max(0, int(float(source.get("x", 0.05)) * output_width))
        y = max(0, int(float(source.get("y", 0.05)) * output_height))
        overlay_label = f"overlay{number}"
        next_label = f"base{number}"
        filters.append(
            f"[{input_index}:v]setpts=PTS-STARTPTS,scale={source_width}:{source_height}:flags=fast_bilinear[{overlay_label}]"
        )
        filters.append(
            f"[{current}][{overlay_label}]overlay={x}:{y}:eof_action=repeat:shortest=0[{next_label}]"
        )
        current = next_label

    text_number = 0
    font_path = "/usr/share/fonts/truetype/dejavu/DejaVuSans.ttf"
    font_option = f"fontfile='{font_path}':" if os.path.isfile(font_path) else "font='Sans':"
    for source in sources or []:
        source_type = source.get("type")
        if source_type not in ("text", "clock"):
            continue
        text_number += 1
        x = max(0, int(float(source.get("x", 0.05)) * output_width))
        y = max(0, int(float(source.get("y", 0.05)) * output_height))
        font_size = max(10, int(float(source.get("font_size_norm", 0.045)) * output_height))
        color = str(source.get("color", "#ffffff")).lstrip("#")
        color = f"0x{color[:6]}"
        if source_type == "text":
            text_file = source.get("textfile")
            if not text_file:
                continue
            text_option = f"textfile='{text_file}'"
        else:
            text_option = "text='%{localtime\\:%T}'"
        next_label = f"text{text_number}"
        filters.append(
            f"[{current}]drawtext={font_option}{text_option}:x={x}:y={y}:fontsize={font_size}:"
            f"fontcolor={color}:borderw=2:bordercolor=0x000000@0.75[{next_label}]"
        )
        current = next_label
    return ";".join(filters), current


def add_veno_live_watermark(filter_graph, current_label, output_height):
    """Acrescenta a marca Veno somente ao sinal enviado para a live."""
    font_path = "/usr/share/fonts/truetype/dejavu/DejaVuSans-Bold.ttf"
    font_option = f"fontfile='{font_path}':" if os.path.isfile(font_path) else "font='Sans':"
    font_size = max(18, int(output_height * 0.032))
    watermark_label = "veno_live_watermark"
    watermark = (
        f"[{current_label}]drawtext={font_option}text='V  VENO LIVE':"
        f"x=w-tw-24:y=h-th-22:fontsize={font_size}:fontcolor=0xffffff@0.78:"
        "box=1:boxcolor=0x11182a@0.54:boxborderw=10:shadowx=1:shadowy=1:"
        f"shadowcolor=0x000000@0.65[{watermark_label}]"
    )
    return f"{filter_graph};{watermark}", watermark_label


def build_ffmpeg_command(
    display, width, height, fps, quality, audio_source, draw_mouse, output_path,
    audio_volume=100, overlay_sources=None, target_bitrate_kbps=None,
    output_resolution=None, encoder_preset=None, encoder_threads=None,
):
    profiles = {
        "Econômica — PC fraco": ("ultrafast", "29"),
        "Equilibrada": ("veryfast", "24"),
        "Alta qualidade": ("faster", "19"),
    }
    preset, crf = profiles.get(quality, profiles["Econômica — PC fraco"])
    if encoder_preset in ("ultrafast", "superfast", "veryfast", "faster"):
        preset = encoder_preset
    out_width, out_height = parse_resolution(output_resolution or (width, height))
    command = [
        "ffmpeg",
        "-hide_banner",
        "-loglevel",
        "warning",
        "-progress",
        "pipe:2",
        "-nostats",
        "-y",
        "-thread_queue_size",
        "1024",
        "-f",
        "x11grab",
        "-draw_mouse",
        "1" if draw_mouse else "0",
        "-framerate",
        str(fps),
        "-video_size",
        f"{width}x{height}",
        "-i",
        f"{display}+0,0",
    ]
    visual_entries, next_input_index = append_visual_source_inputs(command, overlay_sources, fps)
    audio_input_index = next_input_index
    if audio_source != "Sem áudio":
        command += [
            "-thread_queue_size",
            "1024",
            "-f",
            "pulse",
            "-i",
            audio_source,
        ]
    filter_graph, final_video = build_visual_filter(
        overlay_sources, visual_entries, out_width, out_height,
        f"scale={out_width}:{out_height}:force_original_aspect_ratio=decrease:flags=fast_bilinear,"
        f"pad={out_width}:{out_height}:(ow-iw)/2:(oh-ih)/2,setsar=1",
    )
    command += [
        "-filter_complex_threads",
        "1",
        "-filter_complex",
        filter_graph,
        "-map",
        f"[{final_video}]",
    ]
    if audio_source != "Sem áudio":
        command += ["-map", f"{audio_input_index}:a:0"]
    command += [
        "-c:v",
        "libx264",
        "-preset",
        preset,
    ]
    if target_bitrate_kbps is not None:
        bitrate_kbps = max(300, min(20000, int(target_bitrate_kbps)))
        command += ["-b:v", f"{bitrate_kbps}k", "-maxrate", f"{bitrate_kbps}k", "-bufsize", f"{bitrate_kbps * 2}k"]
    else:
        command += ["-crf", crf]
    if encoder_threads is not None:
        command += ["-threads", str(max(1, min(8, int(encoder_threads))))]
    command += ["-pix_fmt", "yuv420p", "-max_muxing_queue_size", "1024"]
    if audio_source != "Sem áudio":
        command += ["-c:a", "aac", "-b:a", "128k", "-af", f"volume={max(0, min(100, audio_volume)) / 100:.2f}"]
    if output_path.lower().endswith(".mp4"):
        command += ["-movflags", "+faststart"]
    command.append(output_path)
    return command


def build_youtube_command(
    display, width, height, fps, live_quality, audio_source, draw_mouse, server_url, stream_key,
    audio_volume=100, overlay_sources=None, target_bitrate_kbps=None,
    output_resolution=None, encoder_preset=None, encoder_threads_override=None,
):
    profiles = {
        "360p ultra leve — recomendado": (640, 360, 700, "ultrafast", 15, 1),
        "480p leve": (854, 480, 1200, "ultrafast", 15, 2),
        "720p leve": (1280, 720, 2500, "ultrafast", 24, 2),
        "720p padrão": (1280, 720, 4000 if fps <= 30 else 6000, "veryfast", 60, 3),
        "1080p — PC potente": (1920, 1080, 10000 if fps <= 30 else 12000, "veryfast", 60, 4),
    }
    out_width, out_height, bitrate_kbps, preset, maximum_fps, encoder_threads = profiles.get(
        live_quality, profiles["360p ultra leve — recomendado"]
    )
    if target_bitrate_kbps is not None:
        bitrate_kbps = max(300, min(20000, int(target_bitrate_kbps)))
    if output_resolution is not None:
        out_width, out_height = parse_resolution(output_resolution)
    if encoder_preset in ("ultrafast", "superfast", "veryfast", "faster"):
        preset = encoder_preset
    if encoder_threads_override is not None:
        encoder_threads = max(1, min(8, int(encoder_threads_override)))
    maximum_fps = max(maximum_fps, fps)
    fps = min(fps, maximum_fps)
    bitrate = f"{bitrate_kbps}k"
    buffer_size = f"{bitrate_kbps * 2}k"
    keyframe_interval = max(2, fps * 2)
    destination = f"{server_url.rstrip('/')}/{stream_key}"
    video_filter = (
        f"scale={out_width}:{out_height}:force_original_aspect_ratio=decrease:flags=fast_bilinear,"
        f"pad={out_width}:{out_height}:(ow-iw)/2:(oh-ih)/2,setsar=1"
    )
    command = [
        "ffmpeg",
        "-hide_banner",
        "-loglevel",
        "warning",
        "-progress",
        "pipe:2",
        "-nostats",
        "-thread_queue_size",
        "256",
        "-f",
        "x11grab",
        "-draw_mouse",
        "1" if draw_mouse else "0",
        "-framerate",
        str(fps),
        "-video_size",
        f"{width}x{height}",
        "-rtbufsize",
        "32M",
        "-i",
        f"{display}+0,0",
    ]
    visual_entries, next_input_index = append_visual_source_inputs(command, overlay_sources, fps)
    audio_input_index = next_input_index
    if audio_source != "Sem áudio":
        command += [
            "-thread_queue_size",
            "256",
            "-f",
            "pulse",
            "-i",
            audio_source,
        ]
    filter_graph, final_video = build_visual_filter(
        overlay_sources, visual_entries, out_width, out_height, video_filter,
    )
    filter_graph, final_video = add_veno_live_watermark(filter_graph, final_video, out_height)
    command += [
        "-filter_complex_threads",
        "1",
        "-filter_complex",
        filter_graph,
        "-map",
        f"[{final_video}]",
    ]
    if audio_source != "Sem áudio":
        command += ["-map", f"{audio_input_index}:a:0"]
    command += [
        "-c:v",
        "libx264",
        "-preset",
        preset,
        "-tune",
        "zerolatency",
        "-b:v",
        bitrate,
        "-minrate",
        bitrate,
        "-maxrate",
        bitrate,
        "-bufsize",
        buffer_size,
        "-g",
        str(keyframe_interval),
        "-keyint_min",
        str(keyframe_interval),
        "-sc_threshold",
        "0",
        "-bf",
        "0",
        "-threads",
        str(encoder_threads),
        "-r",
        str(fps),
        "-pix_fmt",
        "yuv420p",
    ]
    if audio_source != "Sem áudio":
        command += [
            "-c:a", "aac", "-b:a", "128k", "-ar", "44100", "-ac", "2",
            "-af", f"volume={max(0, min(100, audio_volume)) / 100:.2f}",
        ]
    command += ["-f", "flv", "-flvflags", "no_duration_filesize", destination]
    return command


def build_wayland_command(quality, audio_source, output_path):
    codecs = {
        "Econômica — PC fraco": "libx264",
        "Equilibrada": "libx264",
        "Alta qualidade": "libx264",
    }
    command = ["wf-recorder", "-f", output_path, "-c", codecs.get(quality, "libx264")]
    if audio_source != "Sem áudio":
        command += ["-a", audio_source]
    return command


class ScreenRecorder:
    def __init__(self, root):
        self.root = root
        self.root.title(APP_NAME)
        self.root.geometry("1180x720")
        self.root.minsize(960, 640)
        self.root.configure(bg="#171a20")

        self.session_type = os.environ.get("XDG_SESSION_TYPE", "x11").lower()
        self.screen_width, self.screen_height = detect_screen_size(root)
        (
            self.cpu_name,
            self.cpu_cores,
            self.memory_gb,
            self.encoder_preset,
            self.encoder_threads,
            self.encoder_max_fps,
            self.encoder_profile_name,
        ) = detect_encoding_profile()
        self.process = None
        self.recording = False
        self.stopping = False
        self.countdown_active = False
        self.start_time = None
        self.output_path = None
        self.last_output = None
        self.stderr_lines = deque(maxlen=80)
        self.closing_after_stop = False
        self.current_mode = "local"
        self.current_stream_key = ""
        self.current_server_url = ""
        self.preview_enabled = False
        self.preview_image = None
        self.scenes = ["Cena principal"]
        self.scene_sources = {"Cena principal": []}
        self.next_source_id = 1
        self.preview_box = None
        self.preview_drag_source = None
        self.preview_drag_offset = (0.0, 0.0)
        self.preview_overlay_images = []
        self.preview_source_cache = {}
        self.temp_source_files = []
        self.audio_muted = False
        self.previous_volume = 100
        self.current_frame = "0"
        self.current_bitrate = "0 kb/s"
        self.current_video_bitrate = 700
        self.current_output_resolution = RESOLUTION_OPTIONS[0]

        default_folder = os.path.join(os.path.expanduser("~"), "Vídeos")
        if not os.path.isdir(default_folder):
            default_folder = os.path.join(os.path.expanduser("~"), "Videos")
        if not os.path.isdir(default_folder):
            default_folder = os.path.expanduser("~")

        self.folder_var = tk.StringVar(value=default_folder)
        self.mode_var = tk.StringVar(value="Gravar no computador")
        self.prefix_var = tk.StringVar(value="gravacao_tela")
        self.format_var = tk.StringVar(value="MP4")
        self.fps_var = tk.StringVar(value="15")
        self.quality_var = tk.StringVar(value="Automática conforme o PC")
        self.server_var = tk.StringVar(value="rtmps://a.rtmps.youtube.com/live2")
        self.stream_key_var = tk.StringVar(value="")
        self.live_quality_var = tk.StringVar(value="360p ultra leve — recomendado")
        self.bitrate_var = tk.StringVar(value="700")
        self.resolution_var = tk.StringVar(value=RESOLUTION_OPTIONS[0])
        self.show_key_var = tk.BooleanVar(value=False)
        self.audio_volume_var = tk.DoubleVar(value=100)
        self.audio_var = tk.StringVar(value="Sem áudio")
        self.mouse_var = tk.BooleanVar(value=True)
        self.minimize_var = tk.BooleanVar(value=True)
        self.delay_var = tk.StringVar(value="3")

        self._configure_style()
        self._build_veno_interface()
        self.bitrate_var.trace_add("write", self._bitrate_changed)
        self._bitrate_changed()
        self._load_audio_sources()
        self._mode_changed()
        self.root.protocol("WM_DELETE_WINDOW", self.close_app)

    def _configure_style(self):
        style = ttk.Style()
        try:
            style.theme_use("clam")
        except tk.TclError:
            pass
        style.configure("Dark.TFrame", background="#171a20")
        style.configure("Card.TFrame", background="#232832")
        style.configure("Dark.TLabel", background="#232832", foreground="#e7ebf1", padding=2)
        style.configure("Muted.TLabel", background="#232832", foreground="#9fa8b7", padding=2)
        style.configure("Dark.TCheckbutton", background="#232832", foreground="#e7ebf1", padding=4)
        style.map("Dark.TCheckbutton", background=[("active", "#303744")])
        style.configure("Dark.TEntry", fieldbackground="#171a20", foreground="#f4f6f8", insertcolor="white", padding=7)
        style.configure("Dark.TSpinbox", fieldbackground="#171a20", foreground="#f4f6f8", insertcolor="white", padding=7)
        style.configure("Dark.TCombobox", fieldbackground="#171a20", foreground="#f4f6f8", padding=6)
        style.map("Dark.TCombobox", fieldbackground=[("readonly", "#171a20")], foreground=[("readonly", "#f4f6f8")])
        style.configure("Primary.TButton", background="#7657ff", foreground="white", padding=(15, 11), borderwidth=0, font=("Sans", 10, "bold"))
        style.map("Primary.TButton", background=[("active", "#8b73ff"), ("disabled", "#3a414d")])
        style.configure("Danger.TButton", background="#d63d48", foreground="white", padding=(15, 11), borderwidth=0, font=("Sans", 10, "bold"))
        style.map("Danger.TButton", background=[("active", "#ea4d59"), ("disabled", "#3a414d")])
        style.configure("Youtube.TButton", background="#ff0033", foreground="white", padding=(15, 11), borderwidth=0, font=("Sans", 10, "bold"))
        style.map("Youtube.TButton", background=[("active", "#ff274f"), ("disabled", "#3a414d")])
        style.configure("Secondary.TButton", background="#303744", foreground="white", padding=(10, 8), borderwidth=0)
        style.map("Secondary.TButton", background=[("active", "#414a59")])
        style.configure("Veno.TButton", background="#17b8a6", foreground="#071915", padding=(12, 9), borderwidth=0, font=("Sans", 9, "bold"))
        style.map("Veno.TButton", background=[("active", "#35d5c3"), ("disabled", "#334542")])

    def _build_veno_interface(self):
        """Interface própria do Veno: navegação lateral, palco central e camadas à direita."""
        self.root.configure(bg="#090d18")

        topbar = tk.Frame(self.root, bg="#11182a", height=62)
        topbar.pack(fill="x")
        topbar.pack_propagate(False)

        brand_mark = tk.Frame(topbar, bg="#7657ff", width=62, height=62)
        brand_mark.pack(side="left")
        brand_mark.pack_propagate(False)
        tk.Label(brand_mark, text="V", bg="#7657ff", fg="white", font=("Sans", 24, "bold")).pack(expand=True)

        brand_text = tk.Frame(topbar, bg="#11182a")
        brand_text.pack(side="left", padx=14, pady=9)
        tk.Label(brand_text, text="VENO LIVE", bg="#11182a", fg="#f6f7ff", font=("Sans", 15, "bold"), anchor="w").pack(fill="x")
        tk.Label(brand_text, text="CENTRAL DE TRANSMISSÃO", bg="#11182a", fg="#17b8a6", font=("Sans", 8, "bold"), anchor="w").pack(fill="x")

        tk.Label(
            topbar, text=f"MODO {self.encoder_profile_name.upper()}", bg="#1a2730", fg="#55e1cf",
            font=("Sans", 8, "bold"), padx=12, pady=6,
        ).pack(side="left", padx=10)

        self.preview_button = ttk.Button(topbar, text="Prévia da tela", command=self.toggle_preview, style="Secondary.TButton")
        self.preview_button.pack(side="right", padx=(6, 12), pady=11)
        self.settings_top_button = ttk.Button(topbar, text="Ajustes", command=self.open_settings, style="Secondary.TButton")
        self.settings_top_button.pack(side="right", pady=11)
        ttk.Button(topbar, text="Gravações", command=self.open_recordings_folder, style="Secondary.TButton").pack(side="right", padx=6, pady=11)

        content = tk.Frame(self.root, bg="#090d18")
        content.pack(fill="both", expand=True, padx=10, pady=10)

        # Barra lateral de cenas: funciona como navegação do projeto.
        sidebar = tk.Frame(content, bg="#11182a", width=205, highlightthickness=1, highlightbackground="#202b42")
        sidebar.pack(side="left", fill="y", padx=(0, 10))
        sidebar.pack_propagate(False)
        tk.Label(sidebar, text="PROJETO", bg="#11182a", fg="#73809a", font=("Sans", 8, "bold"), anchor="w").pack(fill="x", padx=14, pady=(15, 4))
        tk.Label(sidebar, text="Cenas da transmissão", bg="#11182a", fg="#f2f4fb", font=("Sans", 11, "bold"), anchor="w").pack(fill="x", padx=14, pady=(0, 10))

        self.scene_list = tk.Listbox(
            sidebar, bg="#0b1120", fg="#e8ebf5", selectbackground="#7657ff", selectforeground="white",
            borderwidth=0, highlightthickness=0, activestyle="none", exportselection=False,
            font=("Sans", 10),
        )
        self.scene_list.pack(fill="both", expand=True, padx=10)
        self.scene_list.insert(tk.END, self.scenes[0])
        self.scene_list.selection_set(0)
        self.scene_list.bind("<<ListboxSelect>>", lambda _event: self.scene_selected())

        scene_actions = tk.Frame(sidebar, bg="#11182a")
        scene_actions.pack(fill="x", padx=8, pady=8)
        ttk.Button(scene_actions, text="+ Cena", command=self.add_scene, style="Veno.TButton").pack(fill="x", pady=(0, 5))
        scene_small = tk.Frame(scene_actions, bg="#11182a")
        scene_small.pack(fill="x")
        ttk.Button(scene_small, text="Renomear", command=self.rename_scene, style="Secondary.TButton").pack(side="left", fill="x", expand=True, padx=(0, 3))
        ttk.Button(scene_small, text="Excluir", command=self.delete_scene, style="Secondary.TButton").pack(side="left", fill="x", expand=True, padx=(3, 0))

        transition_box = tk.Frame(sidebar, bg="#0d1423")
        transition_box.pack(fill="x", padx=10, pady=(2, 10))
        tk.Label(transition_box, text="TROCA DE CENA", bg="#0d1423", fg="#73809a", font=("Sans", 7, "bold"), anchor="w").pack(fill="x", padx=8, pady=(8, 4))
        self.transition_combo = ttk.Combobox(transition_box, values=["Corte", "Suave"], state="readonly", style="Dark.TCombobox")
        self.transition_combo.set("Suave")
        self.transition_combo.pack(fill="x", padx=8)
        self.transition_duration = ttk.Entry(transition_box, style="Dark.TEntry")
        self.transition_duration.insert(0, "300 ms")
        self.transition_duration.pack(fill="x", padx=8, pady=(5, 8))

        # Painel direito: camadas acima e áudio abaixo.
        inspector = tk.Frame(content, bg="#090d18", width=292)
        inspector.pack(side="right", fill="y", padx=(10, 0))
        inspector.pack_propagate(False)

        layers_card = tk.Frame(inspector, bg="#11182a", highlightthickness=1, highlightbackground="#202b42")
        layers_card.pack(fill="both", expand=True)
        layers_header = tk.Frame(layers_card, bg="#11182a")
        layers_header.pack(fill="x", padx=12, pady=(12, 8))
        title_group = tk.Frame(layers_header, bg="#11182a")
        title_group.pack(side="left", fill="x", expand=True)
        tk.Label(title_group, text="CAMADAS", bg="#11182a", fg="#f2f4fb", font=("Sans", 11, "bold"), anchor="w").pack(fill="x")
        tk.Label(title_group, text="Elementos exibidos na tela", bg="#11182a", fg="#73809a", font=("Sans", 8), anchor="w").pack(fill="x")
        self.add_source_button = ttk.Button(layers_header, text="+ Adicionar", command=self.show_add_source_menu, style="Veno.TButton")
        self.add_source_button.pack(side="right")

        self.source_list = tk.Listbox(
            layers_card, bg="#0b1120", fg="#e8ebf5", selectbackground="#263757", selectforeground="white",
            borderwidth=0, highlightthickness=0, activestyle="none", exportselection=False,
            font=("Sans", 9),
        )
        self.source_list.pack(fill="both", expand=True, padx=10, pady=(0, 8))
        self.source_list.bind("<<ListboxSelect>>", lambda _event: self.source_selected())
        self.source_list.bind("<Double-Button-1>", lambda _event: self.edit_source())

        source_actions = tk.Frame(layers_card, bg="#11182a")
        source_actions.pack(fill="x", padx=8, pady=(0, 9))
        self.source_properties_button = ttk.Button(source_actions, text="Editar camada", command=self.edit_source, style="Secondary.TButton")
        self.source_properties_button.pack(side="left", fill="x", expand=True, padx=(0, 3))
        self.delete_source_button = ttk.Button(source_actions, text="Remover", command=self.delete_source, style="Secondary.TButton")
        self.delete_source_button.pack(side="left", fill="x", expand=True, padx=(3, 0))

        self.add_source_menu = tk.Menu(
            self.root, tearoff=False, bg="#11182a", fg="#f0f3f8",
            activebackground="#7657ff", activeforeground="white",
        )
        self.add_source_menu.add_command(label="Adicionar texto", command=self.add_text_source)
        self.add_source_menu.add_command(label="Adicionar imagem", command=self.add_image_source)
        self.add_source_menu.add_command(label="Adicionar vídeo", command=self.add_video_source)
        self.add_source_menu.add_command(label="Adicionar relógio", command=self.add_clock_source)

        audio_card = tk.Frame(inspector, bg="#11182a", highlightthickness=1, highlightbackground="#202b42")
        audio_card.pack(fill="x", pady=(10, 0))
        audio_title = tk.Frame(audio_card, bg="#11182a")
        audio_title.pack(fill="x", padx=10, pady=(9, 5))
        tk.Label(audio_title, text="ÁUDIO", bg="#11182a", fg="#f2f4fb", font=("Sans", 10, "bold")).pack(side="left")
        self.mute_button = ttk.Button(audio_title, text="Som", width=6, command=self.toggle_mute, style="Secondary.TButton")
        self.mute_button.pack(side="right")
        audio_select = tk.Frame(audio_card, bg="#11182a")
        audio_select.pack(fill="x", padx=10)
        self.audio_combo = ttk.Combobox(audio_select, textvariable=self.audio_var, state="readonly", style="Dark.TCombobox")
        self.audio_combo.pack(side="left", fill="x", expand=True)
        self.audio_combo.bind("<<ComboboxSelected>>", lambda _event: self.refresh_sources())
        self.audio_button = ttk.Button(audio_select, text="↻", width=3, command=self._load_audio_sources, style="Secondary.TButton")
        self.audio_button.pack(side="right", padx=(5, 0))
        self.audio_meter = ttk.Progressbar(audio_card, maximum=100, value=65)
        self.audio_meter.pack(fill="x", padx=10, pady=(8, 3))
        volume_row = tk.Frame(audio_card, bg="#11182a")
        volume_row.pack(fill="x", padx=10, pady=(0, 9))
        self.audio_volume_scale = ttk.Scale(volume_row, from_=0, to=100, variable=self.audio_volume_var, orient="horizontal", command=self.volume_changed)
        self.audio_volume_scale.pack(side="left", fill="x", expand=True)
        self.volume_label = tk.Label(volume_row, text="100%", bg="#11182a", fg="#9ca8bd", width=5, anchor="e")
        self.volume_label.pack(side="right")

        # Palco central com composição direta das camadas.
        stage = tk.Frame(content, bg="#11182a", highlightthickness=1, highlightbackground="#202b42")
        stage.pack(side="left", fill="both", expand=True)
        stage_header = tk.Frame(stage, bg="#11182a", height=46)
        stage_header.pack(fill="x")
        stage_header.pack_propagate(False)
        tk.Label(stage_header, text="PALCO", bg="#11182a", fg="#f4f5fb", font=("Sans", 11, "bold")).pack(side="left", padx=(13, 5))
        tk.Label(stage_header, text=f"{self.screen_width} × {self.screen_height}", bg="#11182a", fg="#73809a", font=("Sans", 8)).pack(side="left")
        self.preview_mode_label = tk.Label(stage_header, text="PRONTO", bg="#1a2730", fg="#55e1cf", font=("Sans", 8, "bold"), padx=10, pady=4)
        self.preview_mode_label.pack(side="right", padx=12)

        self.preview_canvas = tk.Canvas(stage, bg="#050811", highlightthickness=0)
        self.preview_canvas.pack(fill="both", expand=True, padx=10, pady=(0, 7))
        self.preview_canvas.bind("<Configure>", lambda _event: self.draw_preview_placeholder() if not self.preview_enabled else None)
        self.preview_canvas.bind("<ButtonPress-1>", self.preview_source_press)
        self.preview_canvas.bind("<B1-Motion>", self.preview_source_drag)
        self.preview_canvas.bind("<ButtonRelease-1>", self.preview_source_release)

        stage_hint = tk.Label(
            stage, text="Selecione uma camada e arraste diretamente no palco para posicionar",
            bg="#11182a", fg="#73809a", font=("Sans", 8), anchor="w",
        )
        stage_hint.pack(fill="x", padx=12, pady=(0, 8))

        # Faixa de comando: status à esquerda e ações grandes à direita.
        command_bar = tk.Frame(self.root, bg="#11182a", height=104, highlightthickness=1, highlightbackground="#202b42")
        command_bar.pack(fill="x", padx=10, pady=(0, 10))
        command_bar.pack_propagate(False)

        status_area = tk.Frame(command_bar, bg="#11182a")
        status_area.pack(side="left", fill="both", expand=True, padx=13, pady=12)
        status_top = tk.Frame(status_area, bg="#11182a")
        status_top.pack(fill="x")
        self.indicator = tk.Label(status_top, text="●", bg="#11182a", fg="#687180", font=("Sans", 15, "bold"))
        self.indicator.pack(side="left", padx=(0, 7))
        self.status_label = tk.Label(status_top, text="Pronto", bg="#11182a", fg="#f0f2f8", font=("Sans", 10, "bold"), anchor="w")
        self.status_label.pack(side="left")
        self.timer_label = tk.Label(status_top, text="00:00:00", bg="#11182a", fg="#55e1cf", font=("Monospace", 13, "bold"))
        self.timer_label.pack(side="right")
        self.started_at_label = tk.Label(status_top, text="Início: --:--:--", bg="#11182a", fg="#8995aa", font=("Sans", 8))
        self.started_at_label.pack(side="right", padx=(0, 12))
        self.detail_label = tk.Label(status_area, text="Veno econômico • 480p • 700 kbps • 15 FPS", bg="#11182a", fg="#8995aa", font=("Sans", 8), anchor="w")
        self.detail_label.pack(fill="x", pady=(3, 0))
        self.stats_label = tk.Label(status_area, text="Quadros: 0  |  Bitrate: 0 kb/s", bg="#11182a", fg="#657188", font=("Sans", 8), anchor="w")
        self.stats_label.pack(fill="x", pady=(3, 0))

        actions = tk.Frame(command_bar, bg="#11182a")
        actions.pack(side="right", fill="y", padx=10, pady=10)
        self.live_mode_button = ttk.Button(actions, text="●  TRANSMITIR", command=self.live_action_clicked, style="Youtube.TButton")
        self.live_mode_button.grid(row=0, column=0, sticky="ew", padx=3, pady=2)
        self.local_mode_button = ttk.Button(actions, text="GRAVAR", command=self.local_action_clicked, style="Primary.TButton")
        self.local_mode_button.grid(row=0, column=1, sticky="ew", padx=3, pady=2)
        self.stop_button = ttk.Button(actions, text="PARAR", command=self.stop_recording, state="disabled", style="Danger.TButton")
        self.stop_button.grid(row=0, column=2, sticky="ew", padx=3, pady=2)
        self.start_button = self.local_mode_button
        self.live_action_button = self.live_mode_button
        self.settings_button = ttk.Button(actions, text="Ajustes", command=self.open_settings, style="Secondary.TButton")
        self.settings_button.grid(row=1, column=0, sticky="ew", padx=3, pady=2)
        self.open_folder_button = ttk.Button(actions, text="Abrir gravação", command=self.open_last_folder, state="disabled", style="Secondary.TButton")
        self.open_folder_button.grid(row=1, column=1, columnspan=2, sticky="ew", padx=3, pady=2)
        for column in range(3):
            actions.columnconfigure(column, weight=1, uniform="actions")

        self._build_settings_window()
        self.config_widgets = [
            self.folder_entry, self.folder_button, self.prefix_entry, self.format_combo, self.fps_combo,
            self.quality_combo, self.server_entry, self.stream_key_entry, self.show_key_button,
            self.bitrate_spin, self.resolution_combo, self.live_fps_combo, self.audio_combo, self.audio_button,
            self.mouse_check, self.minimize_check, self.delay_combo, self.audio_volume_scale, self.mute_button,
        ]
        self.root.after(100, self.draw_preview_placeholder)
        self.root.after(1000, self._preview_clock_tick)
        self.refresh_sources()

    def _build_settings_window(self):
        self.settings_window = tk.Toplevel(self.root)
        self.settings_window.title("Configurações — Veno Live Studio")
        self.settings_window.geometry("650x520")
        self.settings_window.minsize(590, 480)
        self.settings_window.configure(bg="#1d2025")
        self.settings_window.withdraw()
        self.settings_window.protocol("WM_DELETE_WINDOW", self.settings_window.withdraw)

        notebook = ttk.Notebook(self.settings_window)
        notebook.pack(fill="both", expand=True, padx=12, pady=12)
        live_tab = ttk.Frame(notebook, style="Card.TFrame", padding=18)
        video_tab = ttk.Frame(notebook, style="Card.TFrame", padding=18)
        record_tab = ttk.Frame(notebook, style="Card.TFrame", padding=18)
        general_tab = ttk.Frame(notebook, style="Card.TFrame", padding=18)
        notebook.add(live_tab, text="Transmissão")
        notebook.add(video_tab, text="Vídeo")
        notebook.add(record_tab, text="Gravação")
        notebook.add(general_tab, text="Geral")

        ttk.Label(live_tab, text="YouTube Live — RTMPS", style="Dark.TLabel", font=("Sans", 12, "bold")).pack(fill="x", pady=(0, 12))
        ttk.Label(live_tab, text="URL do servidor", style="Dark.TLabel").pack(fill="x")
        self.server_entry = ttk.Entry(live_tab, textvariable=self.server_var, style="Dark.TEntry")
        self.server_entry.pack(fill="x", pady=(3, 10))
        ttk.Label(live_tab, text="Chave de transmissão", style="Dark.TLabel").pack(fill="x")
        key_row = ttk.Frame(live_tab, style="Card.TFrame")
        key_row.pack(fill="x", pady=(3, 10))
        self.stream_key_entry = ttk.Entry(key_row, textvariable=self.stream_key_var, show="•", style="Dark.TEntry")
        self.stream_key_entry.pack(side="left", fill="x", expand=True)
        self.show_key_button = ttk.Button(key_row, text="Mostrar", command=self.toggle_stream_key, style="Secondary.TButton")
        self.show_key_button.pack(side="right", padx=(6, 0))
        tk.Label(
            live_tab,
            text="A marca-d'água V VENO LIVE será aplicada automaticamente somente durante a transmissão.\n"
            "Bitrate, resolução e processador ficam na aba Vídeo.",
            bg="#232832", fg="#55e1cf", justify="left", anchor="w", pady=12,
        ).pack(fill="x")

        ttk.Label(video_tab, text="Qualidade do vídeo", style="Dark.TLabel", font=("Sans", 12, "bold")).pack(fill="x", pady=(0, 12))
        video_grid = ttk.Frame(video_tab, style="Card.TFrame")
        video_grid.pack(fill="x")
        video_grid.columnconfigure(0, weight=1)
        video_grid.columnconfigure(1, weight=1)
        ttk.Label(video_grid, text="Bitrate do vídeo (kbps)", style="Dark.TLabel").grid(row=0, column=0, sticky="ew", padx=(0, 6))
        ttk.Label(video_grid, text="Resolução de saída", style="Dark.TLabel").grid(row=0, column=1, sticky="ew", padx=(6, 0))
        self.bitrate_spin = ttk.Spinbox(video_grid, from_=300, to=20000, increment=100, textvariable=self.bitrate_var, style="Dark.TSpinbox")
        self.bitrate_spin.grid(row=1, column=0, sticky="ew", padx=(0, 6), pady=(3, 10))
        self.bitrate_spin.bind("<Return>", self._bitrate_changed)
        self.bitrate_spin.bind("<FocusOut>", self._bitrate_changed)
        self.resolution_combo = ttk.Combobox(
            video_grid, textvariable=self.resolution_var, values=RESOLUTION_OPTIONS,
            state="readonly", style="Dark.TCombobox",
        )
        self.resolution_combo.grid(row=1, column=1, sticky="ew", padx=(6, 0), pady=(3, 10))
        self.resolution_combo.bind("<<ComboboxSelected>>", self._resolution_changed)
        ttk.Label(video_grid, text="Quadros por segundo", style="Dark.TLabel").grid(row=2, column=0, sticky="ew", padx=(0, 6))
        self.live_fps_combo = ttk.Combobox(
            video_grid, textvariable=self.fps_var, values=["15", "24", "30", "60"], state="readonly", style="Dark.TCombobox",
        )
        self.live_fps_combo.grid(row=3, column=0, sticky="ew", padx=(0, 6), pady=(3, 10))
        self.bitrate_rule_label = tk.Label(
            video_tab, text="", bg="#1a2730", fg="#55e1cf", justify="left", anchor="w", padx=12, pady=10, wraplength=560,
        )
        self.bitrate_rule_label.pack(fill="x", pady=(3, 12))

        cpu_box = tk.Frame(video_tab, bg="#151d2d", highlightthickness=1, highlightbackground="#2a3853")
        cpu_box.pack(fill="x")
        tk.Label(cpu_box, text="PROCESSADOR DE CODIFICAÇÃO", bg="#151d2d", fg="#8995aa", font=("Sans", 8, "bold"), anchor="w").pack(fill="x", padx=12, pady=(10, 3))
        tk.Label(cpu_box, text=self.cpu_name, bg="#151d2d", fg="#f1f3f8", font=("Sans", 9, "bold"), anchor="w", wraplength=560, justify="left").pack(fill="x", padx=12)
        memory_text = f" • {self.memory_gb:.1f} GB RAM" if self.memory_gb else ""
        tk.Label(
            cpu_box,
            text=f"Automático: perfil {self.encoder_profile_name} • libx264 • {self.encoder_threads} thread(s) de {self.cpu_cores}{memory_text} • até {self.encoder_max_fps} FPS",
            bg="#151d2d", fg="#55e1cf", font=("Sans", 8), anchor="w", wraplength=560, justify="left",
        ).pack(fill="x", padx=12, pady=(4, 10))

        ttk.Label(record_tab, text="Gravação local", style="Dark.TLabel", font=("Sans", 12, "bold")).pack(fill="x", pady=(0, 12))
        ttk.Label(record_tab, text="Pasta de destino", style="Dark.TLabel").pack(fill="x")
        folder_row = ttk.Frame(record_tab, style="Card.TFrame")
        folder_row.pack(fill="x", pady=(3, 10))
        self.folder_entry = ttk.Entry(folder_row, textvariable=self.folder_var, style="Dark.TEntry")
        self.folder_entry.pack(side="left", fill="x", expand=True)
        self.folder_button = ttk.Button(folder_row, text="Escolher", command=self.choose_folder, style="Secondary.TButton")
        self.folder_button.pack(side="right", padx=(6, 0))
        record_grid = ttk.Frame(record_tab, style="Card.TFrame")
        record_grid.pack(fill="x")
        record_grid.columnconfigure(0, weight=1)
        record_grid.columnconfigure(1, weight=1)
        ttk.Label(record_grid, text="Nome", style="Dark.TLabel").grid(row=0, column=0, sticky="ew", padx=(0, 6))
        ttk.Label(record_grid, text="Formato", style="Dark.TLabel").grid(row=0, column=1, sticky="ew", padx=(6, 0))
        self.prefix_entry = ttk.Entry(record_grid, textvariable=self.prefix_var, style="Dark.TEntry")
        self.prefix_entry.grid(row=1, column=0, sticky="ew", padx=(0, 6), pady=(3, 10))
        self.format_combo = ttk.Combobox(record_grid, textvariable=self.format_var, values=["MP4", "MKV"], state="readonly", style="Dark.TCombobox")
        self.format_combo.grid(row=1, column=1, sticky="ew", padx=(6, 0), pady=(3, 10))
        ttk.Label(record_grid, text="FPS", style="Dark.TLabel").grid(row=2, column=0, sticky="ew", padx=(0, 6))
        ttk.Label(record_grid, text="Processamento", style="Dark.TLabel").grid(row=2, column=1, sticky="ew", padx=(6, 0))
        self.fps_combo = ttk.Combobox(record_grid, textvariable=self.fps_var, values=["15", "24", "30", "60"], state="readonly", style="Dark.TCombobox")
        self.fps_combo.grid(row=3, column=0, sticky="ew", padx=(0, 6), pady=(3, 0))
        self.quality_combo = ttk.Combobox(
            record_grid, textvariable=self.quality_var,
            values=["Automática conforme o PC"], state="readonly", style="Dark.TCombobox",
        )
        self.quality_combo.grid(row=3, column=1, sticky="ew", padx=(6, 0), pady=(3, 0))

        ttk.Label(general_tab, text="Opções gerais", style="Dark.TLabel", font=("Sans", 12, "bold")).pack(fill="x", pady=(0, 12))
        self.mouse_check = ttk.Checkbutton(general_tab, text="Capturar ponteiro do mouse", variable=self.mouse_var, style="Dark.TCheckbutton")
        self.mouse_check.pack(fill="x", pady=5)
        self.minimize_check = ttk.Checkbutton(general_tab, text="Minimizar o Studio ao iniciar", variable=self.minimize_var, style="Dark.TCheckbutton")
        self.minimize_check.pack(fill="x", pady=5)
        delay_row = ttk.Frame(general_tab, style="Card.TFrame")
        delay_row.pack(fill="x", pady=10)
        ttk.Label(delay_row, text="Contagem regressiva", style="Dark.TLabel").pack(side="left")
        self.delay_combo = ttk.Combobox(delay_row, textvariable=self.delay_var, values=["0", "3", "5", "10"], width=5, state="readonly", style="Dark.TCombobox")
        self.delay_combo.pack(side="right")
        ttk.Label(general_tab, text="Fonte de áudio e volume são configurados no Mixer de áudio da tela principal.", style="Muted.TLabel").pack(fill="x", pady=12)

        button_row = ttk.Frame(self.settings_window, style="Dark.TFrame", padding=(12, 0, 12, 12))
        button_row.pack(fill="x")
        ttk.Button(button_row, text="Fechar", command=self.settings_window.withdraw, style="Primary.TButton").pack(side="right")

    def open_settings(self):
        self.settings_window.deiconify()
        self.settings_window.transient(self.root)
        self.settings_window.lift()
        self.settings_window.focus_force()

    def open_recordings_folder(self):
        folder = os.path.abspath(os.path.expanduser(self.folder_var.get()))
        if not os.path.isdir(folder):
            messagebox.showerror("Pasta inválida", "A pasta de gravações não existe.", parent=self.root)
            return
        try:
            subprocess.Popen(["xdg-open", folder], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        except OSError as error:
            messagebox.showerror("Não foi possível abrir", str(error), parent=self.root)

    def add_scene(self):
        if self.recording or self.countdown_active:
            return
        name = simpledialog.askstring("Adicionar cena", "Nome da nova cena:", initialvalue=f"Cena {len(self.scenes) + 1}", parent=self.root)
        if not name or not name.strip():
            return
        self.scenes.append(name.strip())
        self.scene_sources[name.strip()] = []
        self.scene_list.insert(tk.END, name.strip())
        index = len(self.scenes) - 1
        self.scene_list.selection_clear(0, tk.END)
        self.scene_list.selection_set(index)
        self.scene_selected()

    def rename_scene(self):
        selection = self.scene_list.curselection()
        if not selection or self.recording or self.countdown_active:
            return
        index = selection[0]
        name = simpledialog.askstring("Renomear cena", "Novo nome:", initialvalue=self.scenes[index], parent=self.root)
        if not name or not name.strip():
            return
        old_name = self.scenes[index]
        self.scenes[index] = name.strip()
        self.scene_sources[name.strip()] = self.scene_sources.pop(old_name, [])
        self.scene_list.delete(index)
        self.scene_list.insert(index, name.strip())
        self.scene_list.selection_set(index)
        self.scene_selected()

    def delete_scene(self):
        selection = self.scene_list.curselection()
        if not selection or len(self.scenes) <= 1 or self.recording or self.countdown_active:
            if len(self.scenes) <= 1:
                messagebox.showinfo("Cenas", "O Studio precisa manter pelo menos uma cena.", parent=self.root)
            return
        index = selection[0]
        removed_name = self.scenes.pop(index)
        self.scene_sources.pop(removed_name, None)
        self.scene_list.delete(index)
        new_index = min(index, len(self.scenes) - 1)
        self.scene_list.selection_set(new_index)
        self.scene_selected()

    def scene_selected(self):
        selection = self.scene_list.curselection()
        scene = self.scenes[selection[0]] if selection else self.scenes[0]
        self.preview_mode_label.config(text=scene.upper())
        self.refresh_sources()
        self.render_preview_sources()

    def current_scene_name(self):
        selection = self.scene_list.curselection()
        return self.scenes[selection[0]] if selection else self.scenes[0]

    def current_sources(self):
        return self.scene_sources.setdefault(self.current_scene_name(), [])

    def refresh_sources(self):
        if not hasattr(self, "source_list"):
            return
        self.source_list.delete(0, tk.END)
        self.source_list.insert(tk.END, "👁  Captura de tela")
        self.source_list_ids = [None]
        audio = self.audio_var.get()
        if audio == "Sem áudio":
            self.source_list.insert(tk.END, "○  Áudio desativado")
        else:
            self.source_list.insert(tk.END, f"👁  Áudio: {audio}")
        self.source_list_ids.append(None)
        labels = {"text": "Texto", "image": "Imagem", "video": "Mídia", "clock": "Relógio"}
        for source in self.current_sources():
            self.source_list.insert(tk.END, f"👁  {labels.get(source.get('type'), 'Fonte')}: {source.get('name', '')}")
            self.source_list_ids.append(source.get("id"))

    def show_add_source_menu(self):
        if self.recording or self.countdown_active:
            return
        try:
            self.add_source_menu.tk_popup(
                self.add_source_button.winfo_rootx(),
                self.add_source_button.winfo_rooty() + self.add_source_button.winfo_height(),
            )
        finally:
            self.add_source_menu.grab_release()

    def _append_source(self, source):
        source["id"] = self.next_source_id
        self.next_source_id += 1
        self.current_sources().append(source)
        self.refresh_sources()
        index = len(self.source_list_ids) - 1
        self.source_list.selection_clear(0, tk.END)
        self.source_list.selection_set(index)
        self.render_preview_sources()

    def add_text_source(self):
        text = simpledialog.askstring("Adicionar texto", "Texto que aparecerá na tela:", parent=self.root)
        if not text:
            return
        size = simpledialog.askinteger("Tamanho", "Tamanho da fonte:", initialvalue=42, minvalue=12, maxvalue=200, parent=self.root)
        if size is None:
            return
        color = colorchooser.askcolor(color="#ffffff", title="Cor do texto", parent=self.root)[1] or "#ffffff"
        estimated_width = min(0.75, max(0.12, len(text) * size * 0.55 / max(1, self.screen_width)))
        self._append_source({
            "type": "text", "name": text[:24], "text": text, "x": 0.05, "y": 0.05,
            "w": estimated_width, "h": min(0.2, size * 1.5 / max(1, self.screen_height)),
            "font_size_norm": size / max(1, self.screen_height), "color": color,
        })

    def add_image_source(self):
        path = filedialog.askopenfilename(
            title="Adicionar imagem",
            filetypes=[("Imagens", "*.png *.jpg *.jpeg *.webp *.bmp *.gif"), ("Todos os arquivos", "*.*")],
            parent=self.root,
        )
        if not path:
            return
        width_norm, height_norm = 0.28, 0.28
        if PREVIEW_AVAILABLE:
            try:
                with Image.open(path) as opened:
                    ratio = opened.height / max(1, opened.width)
                height_norm = min(0.65, width_norm * self.screen_width * ratio / max(1, self.screen_height))
            except Exception:
                pass
        self._append_source({
            "type": "image", "name": os.path.basename(path), "path": path,
            "x": 0.05, "y": 0.08, "w": width_norm, "h": height_norm,
        })

    def add_video_source(self):
        path = filedialog.askopenfilename(
            title="Adicionar mídia de vídeo",
            filetypes=[("Vídeos", "*.mp4 *.mkv *.webm *.mov *.avi *.m4v"), ("Todos os arquivos", "*.*")],
            parent=self.root,
        )
        if not path:
            return
        self._append_source({
            "type": "video", "name": os.path.basename(path), "path": path,
            "x": 0.08, "y": 0.10, "w": 0.34, "h": 0.34,
        })

    def add_clock_source(self):
        size = simpledialog.askinteger("Relógio", "Tamanho da fonte:", initialvalue=44, minvalue=12, maxvalue=200, parent=self.root)
        if size is None:
            return
        color = colorchooser.askcolor(color="#ffffff", title="Cor do relógio", parent=self.root)[1] or "#ffffff"
        self._append_source({
            "type": "clock", "name": "Relógio 24 horas", "x": 0.72, "y": 0.05,
            "w": 0.23, "h": min(0.2, size * 1.5 / max(1, self.screen_height)),
            "font_size_norm": size / max(1, self.screen_height), "color": color,
        })

    def selected_source(self):
        selection = self.source_list.curselection()
        if not selection or selection[0] >= len(getattr(self, "source_list_ids", [])):
            return None
        source_id = self.source_list_ids[selection[0]]
        if source_id is None:
            return None
        for source in self.current_sources():
            if source.get("id") == source_id:
                return source
        return None

    def source_selected(self):
        self.render_preview_sources()

    def edit_source(self):
        if self.recording or self.countdown_active:
            return
        source = self.selected_source()
        if not source:
            return
        source_type = source.get("type")
        if source_type == "text":
            text = simpledialog.askstring("Propriedades do texto", "Texto:", initialvalue=source.get("text", ""), parent=self.root)
            if not text:
                return
            source["text"] = text
            source["name"] = text[:24]
        if source_type in ("text", "clock"):
            current_size = max(12, int(source.get("font_size_norm", 0.045) * self.screen_height))
            size = simpledialog.askinteger("Tamanho", "Tamanho da fonte:", initialvalue=current_size, minvalue=12, maxvalue=200, parent=self.root)
            if size is not None:
                source["font_size_norm"] = size / max(1, self.screen_height)
                if source_type == "text":
                    source["w"] = min(0.9, max(0.12, len(source.get("text", "")) * size * 0.55 / max(1, self.screen_width)))
                    source["h"] = min(0.2, size * 1.5 / max(1, self.screen_height))
            color = colorchooser.askcolor(color=source.get("color", "#ffffff"), title="Cor", parent=self.root)[1]
            if color:
                source["color"] = color
        elif source_type in ("image", "video"):
            current_width = max(5, int(source.get("w", 0.3) * 100))
            width_percent = simpledialog.askinteger(
                "Tamanho da mídia", "Largura em porcentagem da tela:",
                initialvalue=current_width, minvalue=5, maxvalue=100, parent=self.root,
            )
            if width_percent is not None:
                ratio = source.get("h", 0.3) / max(0.01, source.get("w", 0.3))
                source["w"] = width_percent / 100
                source["h"] = min(1.0, source["w"] * ratio)
        self.refresh_sources()
        self.render_preview_sources()

    def delete_source(self):
        if self.recording or self.countdown_active:
            return
        source = self.selected_source()
        if not source:
            return
        self.scene_sources[self.current_scene_name()] = [item for item in self.current_sources() if item.get("id") != source.get("id")]
        self.refresh_sources()
        self.render_preview_sources()

    def _source_by_id(self, source_id):
        for source in self.current_sources():
            if source.get("id") == source_id:
                return source
        return None

    def render_preview_sources(self):
        if not hasattr(self, "preview_canvas") or not self.preview_box:
            return
        canvas = self.preview_canvas
        canvas.delete("overlay_source")
        self.preview_overlay_images = []
        x1, y1, x2, y2 = self.preview_box
        box_width = max(1, x2 - x1)
        box_height = max(1, y2 - y1)
        selected = self.selected_source()
        selected_id = selected.get("id") if selected else None

        for source in self.current_sources():
            source_id = source.get("id")
            source_type = source.get("type")
            left = x1 + float(source.get("x", 0.05)) * box_width
            top = y1 + float(source.get("y", 0.05)) * box_height
            width = max(18, float(source.get("w", 0.25)) * box_width)
            height = max(14, float(source.get("h", 0.12)) * box_height)
            tag = f"source_{source_id}"

            if source_type in ("text", "clock"):
                shown_text = source.get("text", "Texto") if source_type == "text" else datetime.datetime.now().strftime("%H:%M:%S")
                font_size = max(8, int(float(source.get("font_size_norm", 0.045)) * box_height))
                text_tags = ("overlay_source", tag, "preview_clock") if source_type == "clock" else ("overlay_source", tag)
                item = canvas.create_text(
                    left, top, text=shown_text, anchor="nw", fill=source.get("color", "#ffffff"),
                    font=("Sans", font_size, "bold"), tags=text_tags,
                )
                bounds = canvas.bbox(item)
                if bounds:
                    width = max(width, bounds[2] - bounds[0])
                    height = max(height, bounds[3] - bounds[1])
            elif source_type == "image" and PREVIEW_AVAILABLE and os.path.isfile(source.get("path", "")):
                try:
                    cache_key = (source["path"], max(1, int(width)), max(1, int(height)))
                    preview_image = self.preview_source_cache.get(cache_key)
                    if preview_image is None:
                        with Image.open(source["path"]) as opened:
                            rendered = opened.convert("RGBA")
                            rendered.thumbnail((cache_key[1], cache_key[2]), Image.Resampling.LANCZOS)
                        preview_image = ImageTk.PhotoImage(rendered)
                        if len(self.preview_source_cache) > 24:
                            self.preview_source_cache.clear()
                        self.preview_source_cache[cache_key] = preview_image
                    self.preview_overlay_images.append(preview_image)
                    width, height = preview_image.width(), preview_image.height()
                    canvas.create_image(left, top, image=preview_image, anchor="nw", tags=("overlay_source", tag))
                except Exception:
                    canvas.create_rectangle(left, top, left + width, top + height, fill="#303744", outline="#858d99", tags=("overlay_source", tag))
                    canvas.create_text(left + 8, top + 8, text="Imagem indisponível", anchor="nw", fill="#dfe3e8", tags=("overlay_source", tag))
            elif source_type == "video":
                canvas.create_rectangle(left, top, left + width, top + height, fill="#34284e", outline="#aa7cff", tags=("overlay_source", tag))
                canvas.create_text(
                    left + width / 2, top + height / 2, text=f"▶  {source.get('name', 'Vídeo')}",
                    anchor="center", fill="#f1eaff", width=max(30, int(width - 12)), tags=("overlay_source", tag),
                )
            else:
                continue

            if source_id == selected_id:
                canvas.create_rectangle(
                    left - 2, top - 2, left + width + 2, top + height + 2,
                    outline="#ff4655", width=2, dash=(5, 3), tags=("overlay_source", tag),
                )

    def _preview_clock_tick(self):
        try:
            if hasattr(self, "preview_canvas"):
                self.preview_canvas.itemconfigure("preview_clock", text=datetime.datetime.now().strftime("%H:%M:%S"))
            self.root.after(1000, self._preview_clock_tick)
        except tk.TclError:
            pass

    def preview_source_press(self, event):
        if self.recording or self.countdown_active or not self.preview_box:
            return
        source = None
        for item in reversed(self.preview_canvas.find_overlapping(event.x, event.y, event.x, event.y)):
            for tag in self.preview_canvas.gettags(item):
                if tag.startswith("source_"):
                    try:
                        source = self._source_by_id(int(tag.split("_", 1)[1]))
                    except (ValueError, IndexError):
                        source = None
                    break
            if source:
                break
        if not source:
            self.preview_drag_source = None
            return

        self.preview_drag_source = source
        x1, y1, x2, y2 = self.preview_box
        box_width = max(1, x2 - x1)
        box_height = max(1, y2 - y1)
        self.preview_drag_offset = (
            (event.x - x1) / box_width - float(source.get("x", 0.0)),
            (event.y - y1) / box_height - float(source.get("y", 0.0)),
        )
        source_id = source.get("id")
        if source_id in self.source_list_ids:
            index = self.source_list_ids.index(source_id)
            self.source_list.selection_clear(0, tk.END)
            self.source_list.selection_set(index)
            self.source_list.see(index)
        self.render_preview_sources()

    def preview_source_drag(self, event):
        source = self.preview_drag_source
        if not source or not self.preview_box or self.recording or self.countdown_active:
            return
        x1, y1, x2, y2 = self.preview_box
        box_width = max(1, x2 - x1)
        box_height = max(1, y2 - y1)
        offset_x, offset_y = self.preview_drag_offset
        new_x = (event.x - x1) / box_width - offset_x
        new_y = (event.y - y1) / box_height - offset_y
        source["x"] = max(0.0, min(1.0 - min(1.0, float(source.get("w", 0.2))), new_x))
        source["y"] = max(0.0, min(1.0 - min(1.0, float(source.get("h", 0.1))), new_y))
        self.render_preview_sources()

    def preview_source_release(self, _event):
        self.preview_drag_source = None

    def toggle_mute(self):
        if self.recording or self.countdown_active:
            return
        if self.audio_muted:
            self.audio_muted = False
            self.audio_volume_var.set(self.previous_volume or 100)
            self.mute_button.configure(text="Som")
        else:
            self.audio_muted = True
            self.previous_volume = self.audio_volume_var.get()
            self.audio_volume_var.set(0)
            self.mute_button.configure(text="Mudo")
        self.volume_changed(self.audio_volume_var.get())

    def volume_changed(self, value):
        volume = max(0, min(100, int(float(value))))
        if hasattr(self, "volume_label"):
            self.volume_label.config(text=f"{volume}%")
            self.audio_meter.configure(value=min(100, volume * 0.65))

    def toggle_preview(self):
        if self.recording or self.countdown_active:
            messagebox.showinfo("Pré-visualização", "A prévia permanece desligada durante a gravação ou live para economizar processador.", parent=self.root)
            return
        if not PREVIEW_AVAILABLE:
            messagebox.showerror(
                "Pré-visualização indisponível",
                "Instale o Pillow para ativar a prévia:\n\nsudo apt install python3-pil python3-pil.imagetk",
                parent=self.root,
            )
            return
        self.preview_enabled = not self.preview_enabled
        if self.preview_enabled:
            self.preview_button.configure(text="Desativar pré-visualização")
            self.capture_preview()
        else:
            self.preview_button.configure(text="Ativar pré-visualização")
            self.preview_image = None
            self.draw_preview_placeholder()

    def capture_preview(self):
        if not self.preview_enabled or self.recording or self.countdown_active:
            return
        try:
            screenshot = ImageGrab.grab(all_screens=True)
            canvas_width = max(320, self.preview_canvas.winfo_width() - 30)
            canvas_height = max(180, self.preview_canvas.winfo_height() - 30)
            screenshot.thumbnail((canvas_width, canvas_height), Image.Resampling.BILINEAR)
            self.preview_image = ImageTk.PhotoImage(screenshot)
            self.preview_canvas.delete("all")
            x = self.preview_canvas.winfo_width() // 2
            y = self.preview_canvas.winfo_height() // 2
            self.preview_canvas.create_image(x, y, image=self.preview_image, anchor="center")
            self.preview_canvas.create_rectangle(
                x - screenshot.width // 2, y - screenshot.height // 2,
                x + screenshot.width // 2, y + screenshot.height // 2,
                outline="#d22f3f", width=2,
            )
            self.preview_box = (
                x - screenshot.width // 2, y - screenshot.height // 2,
                x + screenshot.width // 2, y + screenshot.height // 2,
            )
            self.render_preview_sources()
            self.root.after(1500, self.capture_preview)
        except Exception as error:
            self.preview_enabled = False
            self.preview_button.configure(text="Ativar pré-visualização")
            self.draw_preview_placeholder()
            messagebox.showerror("Falha na prévia", f"Não foi possível capturar a tela.\n\n{error}", parent=self.root)

    def draw_preview_placeholder(self):
        if not hasattr(self, "preview_canvas") or self.preview_enabled:
            return
        canvas = self.preview_canvas
        width = max(320, canvas.winfo_width())
        height = max(180, canvas.winfo_height())
        canvas.delete("all")
        margin_x = max(35, width // 8)
        margin_y = max(24, height // 9)
        self.preview_box = (margin_x, margin_y, width - margin_x, height - margin_y)
        canvas.create_rectangle(margin_x, margin_y, width - margin_x, height - margin_y, fill="#101217", outline="#343943", width=2)
        canvas.create_text(width // 2, height // 2 - 22, text="CAPTURA DE TELA", fill="#d8dce2", font=("Sans", 15, "bold"))
        canvas.create_text(width // 2, height // 2 + 8, text=f"{self.screen_width} × {self.screen_height}", fill="#7f8895", font=("Sans", 10))
        canvas.create_text(width // 2, height // 2 + 35, text="Prévia desligada para economizar processador", fill="#57b8f5", font=("Sans", 9))
        self.render_preview_sources()

    def show_system_info(self):
        messagebox.showinfo(
            "Informações do sistema",
            f"Sessão gráfica: {self.session_type.upper()}\n"
            f"Tela capturada: {self.screen_width} × {self.screen_height}\n"
            f"Processador: {self.cpu_name}\n"
            f"Perfil automático: {self.encoder_profile_name}\n"
            f"Codificador: libx264 usando {self.encoder_threads} thread(s)\n"
            f"Limite automático: {self.encoder_max_fps} FPS\n"
            f"Saída atual: {self.resolution_var.get()} a {self.bitrate_var.get()} kbps\n"
            f"Pré-visualização: {'disponível' if PREVIEW_AVAILABLE else 'requer Pillow'}",
            parent=self.root,
        )

    def show_about(self):
        messagebox.showinfo(
            "Veno Live Studio",
            "Veno Live Studio Lite 8.0\n\nInterface exclusiva Veno, com gravação local e YouTube Live.\n"
            "Inclui fontes de texto, imagem, mídia de vídeo e relógio posicionáveis na prévia.\n"
            "A transmissão recebe a marca-d'água V VENO LIVE automaticamente.\n"
            "O modo Ultra Leve foi criado para computadores com poucos recursos.",
            parent=self.root,
        )

    def _load_audio_sources(self):
        values = list_audio_sources()
        self.audio_combo.configure(values=values)
        if self.audio_var.get() not in values:
            self.audio_var.set("Sem áudio")
        self.refresh_sources()
        if not self.recording and not self.countdown_active:
            self.detail_label.config(text=f"Mixer atualizado • {len(values) - 1} fonte(s) de áudio")

    def choose_folder(self):
        folder = filedialog.askdirectory(title="Escolher pasta para as gravações", initialdir=self.folder_var.get(), parent=self.root)
        if folder:
            self.folder_var.set(folder)

    def toggle_stream_key(self):
        self.show_key_var.set(not self.show_key_var.get())
        if self.show_key_var.get():
            self.stream_key_entry.configure(show="")
            self.show_key_button.configure(text="Ocultar")
        else:
            self.stream_key_entry.configure(show="•")
            self.show_key_button.configure(text="Mostrar")

    def select_mode(self, mode):
        if self.recording or self.countdown_active:
            return
        self.mode_var.set("Live no YouTube" if mode == "live" else "Gravar no computador")
        self._mode_changed()

    def _bitrate_changed(self, *_args):
        try:
            bitrate = int(float(self.bitrate_var.get().strip()))
        except (ValueError, AttributeError):
            return
        bitrate = max(300, min(20000, bitrate))
        automatic_resolution = resolution_for_bitrate(bitrate)
        self.resolution_var.set(automatic_resolution)
        if hasattr(self, "bitrate_rule_label"):
            self.bitrate_rule_label.config(
                text=f"Aplicação automática: {bitrate} kbps → {automatic_resolution}\n"
                "Abaixo de 1000: 480p  |  1000–2999: 720p  |  3000–10000: 900p  |  acima de 10000: 1080p"
            )
        if hasattr(self, "detail_label") and not self.recording and not self.countdown_active:
            self.detail_label.config(
                text=f"{automatic_resolution} • {bitrate} kbps • CPU {self.encoder_profile_name} • até {self.encoder_max_fps} FPS"
            )

    def _resolution_changed(self, _event=None):
        try:
            bitrate = int(float(self.bitrate_var.get().strip()))
        except (ValueError, AttributeError):
            return
        allowed = resolution_for_bitrate(bitrate)
        selected = self.resolution_var.get()
        try:
            if RESOLUTION_OPTIONS.index(selected) > RESOLUTION_OPTIONS.index(allowed):
                self.resolution_var.set(allowed)
        except ValueError:
            self.resolution_var.set(allowed)
        if hasattr(self, "bitrate_rule_label"):
            self.bitrate_rule_label.config(
                text=f"Resolução selecionada: {self.resolution_var.get()} • limite permitido pelo bitrate: {allowed}\n"
                "A resolução nunca ultrapassa o limite seguro definido pelo bitrate."
            )

    def _validate_video_settings(self):
        try:
            bitrate = int(float(self.bitrate_var.get().strip()))
        except (ValueError, AttributeError):
            messagebox.showerror("Bitrate inválido", "Informe um bitrate entre 300 e 20000 kbps.", parent=self.root)
            return False
        if not 300 <= bitrate <= 20000:
            messagebox.showerror("Bitrate inválido", "O bitrate deve ficar entre 300 e 20000 kbps.", parent=self.root)
            return False
        allowed = resolution_for_bitrate(bitrate)
        selected = self.resolution_var.get()
        try:
            if RESOLUTION_OPTIONS.index(selected) > RESOLUTION_OPTIONS.index(allowed):
                selected = allowed
                self.resolution_var.set(selected)
        except ValueError:
            selected = allowed
            self.resolution_var.set(selected)
        fps = min(int(self.fps_var.get()), self.encoder_max_fps)
        self.fps_var.set(str(fps))
        self.current_video_bitrate = bitrate
        self.current_output_resolution = selected
        return True

    def live_action_clicked(self):
        if self.current_mode == "live" and (self.recording or self.countdown_active):
            self.stop_recording()
            return
        self.select_mode("live")
        self.start_clicked()

    def local_action_clicked(self):
        if self.current_mode == "local" and (self.recording or self.countdown_active):
            self.stop_recording()
            return
        self.select_mode("local")
        self.start_clicked()

    def _mode_changed(self, _event=None):
        if self.recording or self.countdown_active:
            return
        live_mode = self.mode_var.get() == "Live no YouTube"
        if live_mode:
            self.live_mode_button.configure(state="normal", text="Iniciar transmissão", style="Youtube.TButton")
            self.local_mode_button.configure(state="normal", text="Iniciar gravação", style="Primary.TButton")
            self.stop_button.configure(text="Parar transmissão")
            self.open_folder_button.configure(state="disabled")
            self.status_label.config(text="Pronto para transmitir")
            self.detail_label.config(
                text=f"YouTube Live • {self.resolution_var.get()} • {self.bitrate_var.get()} kbps • marca Veno"
            )
        else:
            self.live_mode_button.configure(state="normal", text="Iniciar transmissão", style="Youtube.TButton")
            self.local_mode_button.configure(state="normal", text="Iniciar gravação", style="Primary.TButton")
            self.stop_button.configure(text="Parar gravação")
            if self.last_output:
                self.open_folder_button.configure(state="normal")
            self.status_label.config(text="Pronto para gravar")
            self.detail_label.config(
                text=f"Gravação local • {self.resolution_var.get()} • {self.bitrate_var.get()} kbps"
            )

    def _set_config_enabled(self, enabled):
        normal_state = "normal" if enabled else "disabled"
        readonly_state = "readonly" if enabled else "disabled"
        for widget in (
            self.local_mode_button,
            self.live_mode_button,
            self.folder_entry,
            self.folder_button,
            self.prefix_entry,
            self.server_entry,
            self.stream_key_entry,
            self.show_key_button,
            self.audio_button,
            self.mouse_check,
            self.minimize_check,
            self.audio_volume_scale,
            self.mute_button,
            self.settings_button,
            self.settings_top_button,
            self.bitrate_spin,
            self.add_source_button,
            self.source_properties_button,
            self.delete_source_button,
        ):
            widget.configure(state=normal_state)
        for widget in (
            self.format_combo,
            self.fps_combo,
            self.quality_combo,
            self.resolution_combo,
            self.live_fps_combo,
            self.audio_combo,
            self.delay_combo,
        ):
            widget.configure(state=readonly_state)
        self.start_button.configure(state=normal_state)
        self.scene_list.configure(state=normal_state)
        self.transition_combo.configure(state=readonly_state)
        self.transition_duration.configure(state=normal_state)
        if enabled:
            self._mode_changed()

    def _cleanup_temp_sources(self):
        for path in self.temp_source_files:
            try:
                os.unlink(path)
            except OSError:
                pass
        self.temp_source_files = []

    def _prepare_sources_for_ffmpeg(self):
        self._cleanup_temp_sources()
        prepared = []
        for source in self.current_sources():
            item = dict(source)
            if item.get("type") == "text":
                temporary = tempfile.NamedTemporaryFile(
                    mode="w", encoding="utf-8", prefix="veno_texto_", suffix=".txt", delete=False,
                )
                try:
                    temporary.write(item.get("text", ""))
                finally:
                    temporary.close()
                try:
                    os.chmod(temporary.name, 0o600)
                except OSError:
                    pass
                item["textfile"] = temporary.name
                self.temp_source_files.append(temporary.name)
            prepared.append(item)
        return prepared

    def _validate_visual_sources(self):
        missing = []
        for source in self.current_sources():
            if source.get("type") in ("image", "video") and not os.path.isfile(source.get("path", "")):
                missing.append(source.get("name", "arquivo"))
        if missing:
            messagebox.showerror(
                "Fonte não encontrada",
                "Um arquivo usado na cena não existe mais:\n\n" + "\n".join(missing[:5]),
                parent=self.root,
            )
            return False
        if self.session_type == "wayland" and self.current_sources():
            messagebox.showerror(
                "Fontes visuais no X11",
                "Texto, imagem, vídeo e relógio sobre a tela exigem uma sessão X11/Xorg nesta versão.\n\n"
                "Encerre a sessão e escolha X11 ou Xorg na tela de login.",
                parent=self.root,
            )
            return False
        return True

    def _validate_settings(self):
        folder = os.path.abspath(os.path.expanduser(self.folder_var.get().strip()))
        if not os.path.isdir(folder):
            messagebox.showerror("Pasta inválida", "Escolha uma pasta existente para salvar a gravação.", parent=self.root)
            return None
        if not os.access(folder, os.W_OK):
            messagebox.showerror("Sem permissão", "O programa não possui permissão para gravar nessa pasta.", parent=self.root)
            return None
        try:
            free_bytes = shutil.disk_usage(folder).free
            if free_bytes < 100 * 1024 * 1024:
                messagebox.showerror("Espaço insuficiente", "Há menos de 100 MB livres na pasta escolhida.", parent=self.root)
                return None
            if free_bytes < 500 * 1024 * 1024:
                proceed = messagebox.askyesno("Pouco espaço", "Há menos de 500 MB livres. Deseja iniciar mesmo assim?", parent=self.root)
                if not proceed:
                    return None
        except OSError:
            pass
        return folder

    def _validate_live_settings(self):
        if self.session_type == "wayland":
            messagebox.showerror(
                "Live indisponível nesta sessão",
                "A transmissão direta para o YouTube deste programa requer uma sessão X11/Xorg.\n\n"
                "Encerre a sessão do Linux e escolha X11 ou Xorg na tela de login.",
                parent=self.root,
            )
            return None
        server_url = self.server_var.get().strip()
        stream_key = self.stream_key_var.get().strip()
        if not server_url.startswith(("rtmps://", "rtmp://")) or any(char.isspace() for char in server_url):
            messagebox.showerror(
                "Servidor inválido",
                "Cole a URL RTMP ou RTMPS mostrada na Sala de controle ao vivo do YouTube.",
                parent=self.root,
            )
            return None
        if len(stream_key) < 6 or any(char.isspace() for char in stream_key) or "/" in stream_key:
            messagebox.showerror(
                "Chave inválida",
                "Cole somente a chave de transmissão do YouTube, sem espaços e sem a URL do servidor.",
                parent=self.root,
            )
            return None
        if server_url.startswith("rtmps://"):
            try:
                protocols = subprocess.run(
                    ["ffmpeg", "-hide_banner", "-protocols"],
                    stdout=subprocess.PIPE,
                    stderr=subprocess.DEVNULL,
                    text=True,
                    timeout=4,
                    check=False,
                ).stdout
                if "rtmps" not in protocols.split():
                    messagebox.showerror(
                        "RTMPS indisponível",
                        "A versão instalada do FFmpeg não possui suporte a RTMPS. Atualize o FFmpeg do sistema.",
                        parent=self.root,
                    )
                    return None
            except (OSError, subprocess.SubprocessError):
                pass
        if self.audio_var.get() == "Sem áudio":
            proceed = messagebox.askyesno(
                "Live sem áudio",
                "Nenhuma fonte de áudio foi selecionada. Deseja transmitir sem som?",
                parent=self.root,
            )
            if not proceed:
                return None
        return server_url, stream_key

    def start_clicked(self):
        if self.recording or self.countdown_active:
            return
        if not self._validate_video_settings():
            return
        if not self._validate_visual_sources():
            return
        live_mode = self.mode_var.get() == "Live no YouTube"
        if live_mode:
            live_settings = self._validate_live_settings()
            if not live_settings:
                return
            self.current_mode = "live"
            self.current_server_url, self.current_stream_key = live_settings
            self.output_path = None
        else:
            folder = self._validate_settings()
            if not folder:
                return
            extension = self.format_var.get().lower()
            self.output_path = unique_output_path(folder, self.prefix_var.get(), extension)
            self.current_mode = "local"
            self.current_server_url = ""
            self.current_stream_key = ""
        if self.preview_enabled:
            self.preview_enabled = False
            self.preview_image = None
            self.preview_button.configure(text="Ativar pré-visualização")
            self.draw_preview_placeholder()
        self.settings_window.withdraw()
        self.current_frame = "0"
        self.current_bitrate = "0 kb/s"
        self.stderr_lines.clear()
        self._set_config_enabled(False)
        self.stop_button.configure(state="normal", text="Cancelar início")
        if self.current_mode == "live":
            self.live_action_button.configure(state="normal", text="Cancelar início")
            self.preview_mode_label.config(text="CONECTANDO AO YOUTUBE")
        else:
            self.preview_mode_label.config(text="PREPARANDO GRAVAÇÃO")
        self.countdown_active = True
        seconds = int(self.delay_var.get())
        self._countdown_step(seconds)

    def _countdown_step(self, seconds):
        if not self.countdown_active:
            return
        if seconds > 0:
            self.indicator.config(fg="#f0b429")
            action = "Live começará" if self.current_mode == "live" else "Gravação começará"
            self.status_label.config(text=f"{action} em {seconds}...")
            self.detail_label.config(text="Prepare a tela que deseja gravar")
            self.root.after(1000, lambda: self._countdown_step(seconds - 1))
            return
        self.countdown_active = False
        if self.minimize_var.get():
            self.root.iconify()
            self.root.after(450, self._start_process)
        else:
            self._start_process()

    def _start_process(self):
        fps = min(int(self.fps_var.get()), self.encoder_max_fps)
        quality = self.quality_var.get()
        audio = self.audio_var.get()
        try:
            overlay_sources = self._prepare_sources_for_ffmpeg()
        except OSError as error:
            self._cleanup_temp_sources()
            self._reset_after_recording()
            self.root.deiconify()
            messagebox.showerror("Falha nas fontes", f"Não foi possível preparar o texto da cena.\n\n{error}", parent=self.root)
            return
        if self.current_mode == "live":
            display = os.environ.get("DISPLAY", ":0.0")
            command = build_youtube_command(
                display,
                self.screen_width,
                self.screen_height,
                fps,
                self.live_quality_var.get(),
                audio,
                self.mouse_var.get(),
                self.current_server_url,
                self.current_stream_key,
                self.audio_volume_var.get(),
                overlay_sources,
                self.current_video_bitrate,
                self.current_output_resolution,
                self.encoder_preset,
                self.encoder_threads,
            )
        elif self.session_type == "wayland":
            command = build_wayland_command(quality, audio, self.output_path)
        else:
            display = os.environ.get("DISPLAY", ":0.0")
            command = build_ffmpeg_command(
                display,
                self.screen_width,
                self.screen_height,
                fps,
                quality,
                audio,
                self.mouse_var.get(),
                self.output_path,
                self.audio_volume_var.get(),
                overlay_sources,
                self.current_video_bitrate,
                self.current_output_resolution,
                self.encoder_preset,
                self.encoder_threads,
            )
        try:
            self.process = subprocess.Popen(
                command,
                stdin=subprocess.PIPE,
                stdout=subprocess.DEVNULL,
                stderr=subprocess.PIPE,
                text=True,
                bufsize=1,
                preexec_fn=start_low_priority_process_group,
            )
        except OSError as error:
            self.process = None
            self._cleanup_temp_sources()
            self._reset_after_recording()
            self.root.deiconify()
            self.root.lift()
            messagebox.showerror("Não foi possível iniciar", f"O gravador não pôde ser iniciado.\n\n{error}", parent=self.root)
            return

        self.recording = True
        self.stopping = False
        self.start_time = time.monotonic()
        self.started_at_label.config(text=f"Início: {datetime.datetime.now().strftime('%H:%M:%S')}")
        self.indicator.config(fg="#ff4655")
        if self.current_mode == "live":
            self.status_label.config(text="AO VIVO — YOUTUBE")
            self.detail_label.config(
                text=f"{self.current_output_resolution} • {self.current_video_bitrate} kbps • marca V VENO LIVE aplicada"
            )
            self.preview_mode_label.config(text="● AO VIVO")
            self.stop_button.configure(state="normal", text="Encerrar transmissão")
            self.live_action_button.configure(state="normal", text="Encerrar transmissão")
        else:
            self.status_label.config(text="GRAVANDO")
            self.detail_label.config(
                text=f"{os.path.basename(self.output_path)} • {self.current_output_resolution} • {self.current_video_bitrate} kbps"
            )
            self.preview_mode_label.config(text="● REC")
            self.stop_button.configure(state="normal", text="Parar gravação")
        threading.Thread(target=self._drain_stderr, daemon=True).start()
        self._update_timer()
        self.root.after(500, self._check_process)

    def _drain_stderr(self):
        process = self.process
        if not process or process.stderr is None:
            return
        try:
            for line in process.stderr:
                clean = line.strip()
                if clean:
                    if clean.startswith("frame="):
                        self.current_frame = clean.split("=", 1)[1].strip() or "0"
                        continue
                    if clean.startswith("bitrate="):
                        self.current_bitrate = clean.split("=", 1)[1].strip() or "0 kb/s"
                        continue
                    if clean.startswith(("progress=", "fps=", "out_time", "speed=", "total_size=", "dup_frames=", "drop_frames=")):
                        continue
                    if self.current_stream_key:
                        clean = clean.replace(self.current_stream_key, "********")
                    self.stderr_lines.append(clean)
        except (OSError, ValueError):
            pass

    def _update_timer(self):
        if not self.recording or self.start_time is None:
            return
        elapsed = max(0, int(time.monotonic() - self.start_time))
        hours, remainder = divmod(elapsed, 3600)
        minutes, seconds = divmod(remainder, 60)
        self.timer_label.config(text=f"{hours:02d}:{minutes:02d}:{seconds:02d}")
        self.stats_label.config(text=f"Quadros: {self.current_frame}  |  Bitrate: {self.current_bitrate}")
        self.root.after(500, self._update_timer)

    def stop_recording(self):
        if self.countdown_active:
            self.countdown_active = False
            self.indicator.config(fg="#687180")
            self._reset_after_recording()
            self.status_label.config(text="Transmissão cancelada" if self.current_mode == "live" else "Gravação cancelada")
            self.detail_label.config(text="Nenhum dado foi enviado" if self.current_mode == "live" else "Nenhum arquivo foi criado")
            self.preview_mode_label.config(text="PRONTO")
            return
        if not self.recording or not self.process or self.stopping:
            return
        self.stopping = True
        if self.current_mode == "live":
            self.live_action_button.configure(state="disabled", text="Encerrando...")
        if self.current_mode == "live":
            self.status_label.config(text="Encerrando a transmissão...")
            self.detail_label.config(text="Aguarde a conexão com o YouTube ser finalizada")
        else:
            self.status_label.config(text="Finalizando o vídeo...")
            self.detail_label.config(text="Aguarde o arquivo ser fechado corretamente")
        self.stop_button.configure(state="disabled")
        try:
            if self.session_type != "wayland" and self.process.stdin:
                self.process.stdin.write("q\n")
                self.process.stdin.flush()
            else:
                os.killpg(os.getpgid(self.process.pid), signal.SIGINT)
        except (OSError, ValueError, BrokenPipeError):
            try:
                os.killpg(os.getpgid(self.process.pid), signal.SIGINT)
            except OSError:
                pass
        self.root.after(200, self._check_process)
        self.root.after(12000, self._force_stop_if_needed)

    def _force_stop_if_needed(self):
        if self.stopping and self.process and self.process.poll() is None:
            try:
                os.killpg(os.getpgid(self.process.pid), signal.SIGTERM)
            except OSError:
                pass

    def _check_process(self):
        if not self.process:
            return
        return_code = self.process.poll()
        if return_code is None:
            self.root.after(500, self._check_process)
            return
        expected_stop = self.stopping
        self._finish_recording(return_code, expected_stop)

    def _finish_recording(self, return_code, expected_stop):
        output = self.output_path
        valid_file = bool(output and os.path.isfile(output) and os.path.getsize(output) > 1024)
        live_finished = self.current_mode == "live" and expected_stop
        self.recording = False
        self.stopping = False
        self.process = None
        self._cleanup_temp_sources()
        self.root.deiconify()
        self.root.lift()
        self.indicator.config(fg="#32c671" if valid_file or live_finished else "#d63d48")
        self._reset_after_recording()

        if self.current_mode == "live":
            if live_finished:
                self.status_label.config(text="Live encerrada")
                self.detail_label.config(text="O envio para o YouTube foi finalizado")
                self.preview_mode_label.config(text="TRANSMISSÃO ENCERRADA")
                if not self.closing_after_stop:
                    messagebox.showinfo(
                        "Live encerrada",
                        "A transmissão foi encerrada no programa.\n\nConfira o YouTube Studio para confirmar o encerramento do evento.",
                        parent=self.root,
                    )
            else:
                self.status_label.config(text="A conexão da live foi interrompida")
                self.preview_mode_label.config(text="ERRO NA TRANSMISSÃO")
                details = "\n".join(list(self.stderr_lines)[-8:])
                if not details:
                    details = f"O transmissor encerrou com o código {return_code}."
                if not self.closing_after_stop:
                    messagebox.showerror(
                        "Falha na transmissão",
                        "Não foi possível manter a conexão com o YouTube.\n\n"
                        "Confira a chave, a URL RTMPS, a internet e a fonte de áudio.\n\n"
                        f"Detalhes:\n{details}",
                        parent=self.root,
                    )
        elif valid_file:
            self.last_output = output
            self.open_folder_button.configure(state="normal")
            self.status_label.config(text="Gravação salva com sucesso")
            self.detail_label.config(text=output)
            self.preview_mode_label.config(text="GRAVAÇÃO SALVA")
            if not self.closing_after_stop:
                messagebox.showinfo("Gravação concluída", f"O vídeo foi salvo em:\n\n{output}", parent=self.root)
        else:
            self.status_label.config(text="Falha na gravação")
            self.preview_mode_label.config(text="ERRO NA GRAVAÇÃO")
            details = "\n".join(list(self.stderr_lines)[-8:])
            if not details:
                details = f"O gravador encerrou com o código {return_code}."
            if not expected_stop or not self.closing_after_stop:
                messagebox.showerror(
                    "Falha na gravação",
                    "Não foi possível criar um vídeo válido.\n\n"
                    "Verifique se outro programa está usando a captura de tela ou a fonte de áudio.\n\n"
                    f"Detalhes:\n{details}",
                    parent=self.root,
                )

        if self.closing_after_stop:
            self.root.destroy()

    def _reset_after_recording(self):
        self._set_config_enabled(True)
        self.start_button.configure(state="normal")
        stop_text = "Parar transmissão" if self.mode_var.get() == "Live no YouTube" else "Parar gravação"
        self.stop_button.configure(state="disabled", text=stop_text)
        self.live_action_button.configure(state="normal", text="Iniciar transmissão")
        self.local_mode_button.configure(state="normal", text="Iniciar gravação")
        if not self.recording:
            self.start_time = None
            self.timer_label.config(text="00:00:00")
            self.started_at_label.config(text="Início: --:--:--")
            self.stats_label.config(text="Quadros: 0  |  Bitrate: 0 kb/s")

    def open_last_folder(self):
        if not self.last_output:
            return
        folder = os.path.dirname(self.last_output)
        try:
            subprocess.Popen(["xdg-open", folder], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        except OSError as error:
            messagebox.showerror("Não foi possível abrir", str(error), parent=self.root)

    def close_app(self):
        if self.countdown_active:
            self.countdown_active = False
            self._cleanup_temp_sources()
            self.root.destroy()
            return
        if self.recording:
            if self.current_mode == "live":
                question = "Deseja encerrar a live no YouTube e fechar o programa?"
            else:
                question = "Deseja parar, salvar a gravação e fechar o programa?"
            proceed = messagebox.askyesno(
                "Transmissão em andamento",
                question,
                parent=self.root,
            )
            if proceed:
                self.closing_after_stop = True
                self.stop_recording()
            return
        self._cleanup_temp_sources()
        self.root.destroy()


def main():
    try:
        root = tk.Tk()
    except tk.TclError as error:
        print(f"Não foi possível abrir a interface gráfica: {error}", file=sys.stderr)
        return 1
    ScreenRecorder(root)
    root.mainloop()
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
PYTHON_APP
