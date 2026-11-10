@echo off & title Video to Sequence & (where python >nul 2>&1 || (echo Python not found. Install Python 3 from python.org and enable "Add to PATH". & pause & exit /b 1)) & python -x "%~f0" %* & exit /b
# -*- coding: utf-8 -*-
# ---------------------------------------------------------------------------
#  Видео -> секвенция кадров для фотограмметрии.
#  Запуск: двойной клик по этому .bat. Видео ищутся в той же папке.
#  Нужны: Python 3, ffmpeg (в PATH или рядом с батником), opencv-python, numpy
#  (opencv/numpy ставятся автоматически при первом запуске).
#  Файл одновременно является батником и Python-скриптом: первая строка
#  запускает python -x, который пропускает её и выполняет остальное.
# ---------------------------------------------------------------------------
import os, sys, json, shutil, subprocess, time, msvcrt

HERE = os.path.dirname(os.path.abspath(sys.argv[0]))
VIDEO_EXT = ('.mp4', '.mov', '.mkv', '.avi', '.m4v', '.webm', '.mts', '.m2ts', '.wmv', '.mpg', '.mpeg', '.3gp')
FPS_CHOICES = ['1', '2', '3', '4', '5', '6', '10', '15', 'all']
STRICT = [  # (рус, англ), доля от локальной медианы, доля от общей медианы
    (('мягкая', 'soft'), 0.35, 0.15),
    (('средняя', 'medium'), 0.50, 0.25),
    (('строгая', 'strict'), 0.65, 0.35),
]
NUMBERING = [  # нумерация файлов секвенции
    ('1, 2, 3...', '1, 2, 3...'),
    ('0, 1, 2...', '0, 1, 2...'),
    ('номер кадра в видео (с 0)', 'video frame number (from 0)'),
]
FOCAL_CHOICES = [13, 14, 16, 18, 20, 21, 22, 23, 24, 25, 26, 27, 28, 29, 30, 32, 35, 40, 50, 70, 85]
DEFAULT_F35 = 26          # мм экв. 35 мм; типично для основной камеры телефона
EXIF_MAKE = 'VideoToSeq'   # Make в EXIF (камера из видео неизвестна)
ANALYSIS_LONG_SIDE = 960   # разрешение для анализа резкости
CLUSTER = 30               # кандидатов в кластере (при 3 кадр/с это ~10 с видео)
DUP_THRESHOLD = 1.5        # средняя разница миниатюр (0..255), ниже = дубликат
BYTES_PER_PX = {'jpg': 0.5, 'png': 3.5}   # примерный размер кадра на пиксель (4K PNG ~28 МБ)
DARK, BRIGHT = 15, 240     # средняя яркость кадра вне этих границ = брак экспозиции

os.system('')  # включает ANSI-последовательности в консоли Windows
CLS = '\x1b[H\x1b[2J\x1b[3J'
INV, DIM, GRN, YEL, RED, CYN, RST = '\x1b[7m', '\x1b[90m', '\x1b[92m', '\x1b[93m', '\x1b[91m', '\x1b[96m', '\x1b[0m'
LANG = ['en']   # язык интерфейса: 'en' или 'ru' (выбирается на первой странице)
REASONS = {'blur': ('размытие', 'blur'), 'dup': ('дубликат', 'duplicate'),
           'exposure': ('экспозиция', 'exposure')}


def T(ru, en):
    """Строка на текущем языке интерфейса."""
    return en if LANG[0] == 'en' else ru


# ----------------------------------------------------------------- утилиты
def wait_key():
    """Возвращает 'up','down','left','right','enter','esc' или символ."""
    ch = msvcrt.getwch()
    if ch in ('\x00', '\xe0'):
        return {'H': 'up', 'P': 'down', 'K': 'left', 'M': 'right'}.get(msvcrt.getwch(), '')
    if ch == '\r':
        return 'enter'
    if ch == '\x1b':
        return 'esc'
    if ch == '\x03':
        raise KeyboardInterrupt
    return ch.lower()


def pause(msg=None):
    print(DIM + (msg or T('Нажмите любую клавишу...', 'Press any key...')) + RST)
    msvcrt.getwch()


def find_tool(name):
    local = os.path.join(HERE, name + '.exe')
    if os.path.isfile(local):
        return local
    return shutil.which(name)


def ensure_libs():
    try:
        import numpy, cv2  # noqa
        return True
    except ImportError:
        pass
    print(YEL + T('Для очистки нужны пакеты opencv-python и numpy.',
                 'Cleaning needs the opencv-python and numpy packages.') + RST)
    print(T('Установить сейчас? (Y/N)', 'Install now? (Y/N)'))
    if wait_key() not in ('y', 'н'):
        return False
    r = subprocess.call([sys.executable, '-m', 'pip', 'install', '--user', 'opencv-python', 'numpy'])
    if r != 0:
        print(RED + T('Не удалось установить пакеты.', 'Failed to install packages.') + RST)
        pause()
        return False
    import site, importlib
    site.addsitedir(site.getusersitepackages())
    importlib.invalidate_caches()
    return True


def human_size(n):
    units = T('Б КБ МБ ГБ ТБ', 'B KB MB GB TB').split()
    for i, u in enumerate(units[:4]):
        if n < 1024:
            return f'{n:.1f} {u}' if i == 3 else f'{n:.0f} {u}'
        n /= 1024
    return f'{n:.1f} {units[4]}'


def fmt_time(s):
    s = int(s)
    return f'{s // 3600}:{s % 3600 // 60:02d}:{s % 60:02d}' if s >= 3600 else f'{s // 60}:{s % 60:02d}'


def bar(done, total, start, label):
    total = max(total, 1)
    frac = min(done / total, 1.0)
    n = int(frac * 30)
    el = time.time() - start
    eta = el / frac - el if frac > 0.01 else 0
    sys.stdout.write(f'\r  {label} [{"#" * n}{"." * (30 - n)}] {frac * 100:5.1f}%  '
                     f'{done}/{total}  {T("прошло", "elapsed")} {fmt_time(el)}  '
                     f'{T("осталось", "left")} ~{fmt_time(eta)}   ')
    sys.stdout.flush()


# -------------------------------------------------------------- видео-инфо
def probe(ffprobe, path):
    out = subprocess.run([ffprobe, '-v', 'error', '-select_streams', 'v:0', '-show_entries',
                          'stream=width,height,r_frame_rate,avg_frame_rate,nb_frames,duration:'
                          'stream_side_data=rotation:stream_tags=rotate:format=duration',
                          '-of', 'json', path], capture_output=True, text=True, encoding='utf-8')
    d = json.loads(out.stdout or '{}')
    st = (d.get('streams') or [{}])[0]
    if not st.get('width'):
        raise RuntimeError(T('не удалось прочитать видеопоток', 'cannot read the video stream'))
    w, h = int(st['width']), int(st['height'])
    rot = 0
    for sd in st.get('side_data_list', []) or []:
        if 'rotation' in sd:
            rot = int(float(sd['rotation']))
    if not rot and st.get('tags', {}).get('rotate'):
        rot = int(st['tags']['rotate'])
    if abs(rot) % 180 == 90:
        w, h = h, w

    def rate(s):
        try:
            a, b = s.split('/')
            return float(a) / float(b) if float(b) else 0
        except Exception:
            return 0
    fps = rate(st.get('avg_frame_rate', '0/0')) or rate(st.get('r_frame_rate', '0/0')) or 30.0
    dur = float(st.get('duration') or d.get('format', {}).get('duration') or 0)
    frames = int(st.get('nb_frames') or 0) or int(round(dur * fps))
    return {'w': w, 'h': h, 'fps': fps, 'dur': dur, 'frames': frames}


# ------------------------------------------------------------------- EXIF
def build_exif(make, model, serial, f35, w, h):
    """TIFF/EXIF-блок: Make, Model, FocalLength, FocalLengthIn35mmFilm,
    BodySerialNumber и размер кадра. Meshroom/AliceVision берёт из него
    фокусное, а одинаковый серийный номер говорит, что камера одна.
    AliceVision считает фокусное в пикселях только по FocalLengthIn35mmFilm
    (по диагонали кадра), поэтому FocalLength = тот же эквивалент."""
    import struct
    ASCII, SHORT, LONG, RATIONAL = 2, 3, 4, 5

    def ifd(entries, base):
        # entries: [(tag, type, value)], base - смещение начала IFD от начала TIFF
        entries = sorted(entries)
        head = struct.pack('<H', len(entries))
        data_off = base + 2 + 12 * len(entries) + 4
        body, data = b'', b''
        for tag, typ, val in entries:
            if typ == ASCII:
                raw, cnt = val.encode('ascii', 'replace') + b'\x00', len(val) + 1
            elif typ == SHORT:
                raw, cnt = struct.pack('<H', val), 1
            elif typ == LONG:
                raw, cnt = struct.pack('<I', val), 1
            else:
                raw, cnt = struct.pack('<II', *val), 1
            if len(raw) <= 4:
                body += struct.pack('<HHI', tag, typ, cnt) + raw.ljust(4, b'\x00')
            else:
                body += struct.pack('<HHII', tag, typ, cnt, data_off + len(data))
                data += raw + (b'\x00' if len(raw) % 2 else b'')
        return head + body + struct.pack('<I', 0) + data

    exif_entries = [(0x920A, RATIONAL, (int(f35), 1)),           # FocalLength
                    (0xA002, LONG, w), (0xA003, LONG, h),         # PixelX/YDimension
                    (0xA405, SHORT, int(round(f35))),             # FocalLengthIn35mmFilm
                    (0xA431, ASCII, serial)]                      # BodySerialNumber
    ifd0_entries = [(0x010F, ASCII, make), (0x0110, ASCII, model), (0x8769, LONG, 0)]
    ifd0_len = len(ifd(ifd0_entries, 8))
    ifd0_entries[-1] = (0x8769, LONG, 8 + ifd0_len)               # указатель на Exif IFD
    return b'II*\x00' + struct.pack('<I', 8) + ifd(ifd0_entries, 8) + ifd(exif_entries, 8 + ifd0_len)


def exif_for(s, stem, w, h):
    """None, если запись EXIF отключена."""
    if not s['exif']:
        return None
    return build_exif(EXIF_MAKE, f'Video {w}x{h}', stem[:60], s['f35'], w, h)


def disk_estimate(s, info, frames):
    """(примерный размер секвенции, свободно на диске) в байтах."""
    need = int(frames * info['w'] * info['h'] * BYTES_PER_PX[s['fmt']])
    try:
        free = shutil.disk_usage(HERE).free
    except Exception:
        free = None
    return need, free


def fps_key(s):
    """С очисткой и без неё частота хранится отдельно: без очистки по умолчанию берутся все кадры."""
    return 'fps' if s['clean'] else 'fps_raw'


def frame_step(s, info):
    fps_val = FPS_CHOICES[s[fps_key(s)]]
    return fps_val, (1 if fps_val == 'all' else max(1, round(info['fps'] / float(fps_val))))


SETTINGS_FILE = os.path.join(HERE, 'make_sequence.json')


def load_settings(defaults):
    try:
        with open(SETTINGS_FILE, encoding='utf-8') as f:
            saved = json.load(f)
        for k, v in saved.items():
            if k in defaults and type(v) is type(defaults[k]):
                defaults[k] = v
    except Exception:
        pass
    return defaults


def save_settings(s):
    try:
        with open(SETTINGS_FILE, 'w', encoding='utf-8') as f:
            json.dump(s, f, ensure_ascii=False, indent=1)
    except Exception:
        pass


def with_exif(data, ext, tiff):
    """Вставляет EXIF в байты JPEG (APP1 после SOI) или PNG (чанк eXIf). tiff=None - без изменений."""
    import struct, zlib
    if tiff is None:
        return data
    if ext == 'jpg':
        payload = b'Exif\x00\x00' + tiff
        return data[:2] + b'\xff\xe1' + struct.pack('>H', len(payload) + 2) + payload + data[2:]
    # PNG: eXIf сразу после IHDR (8 байт сигнатуры + 25 байт IHDR)
    chunk = struct.pack('>I', len(tiff)) + b'eXIf' + tiff + struct.pack('>I', zlib.crc32(b'eXIf' + tiff))
    return data[:33] + chunk + data[33:]


# ------------------------------------------------------------------- меню
def menu_select_video(videos, s):
    """Пункт 0 - язык интерфейса, дальше список видео."""
    idx = 1
    n = len(videos) + 1
    while True:
        out = [CLS, CYN + T('  ВИДЕО -> СЕКВЕНЦИЯ ДЛЯ ФОТОГРАММЕТРИИ', '  VIDEO -> PHOTOGRAMMETRY SEQUENCE') + RST, '',
               T('  Папка: ', '  Folder: ') + HERE, '',
               T('  Вверх/вниз - выбор, Enter - открыть видео / сменить язык, Esc - выход',
                 '  Up/down - move, Enter - open video / switch language, Esc - exit'), '']
        lang = 'Language / Язык:  ' + ('English' if LANG[0] == 'en' else 'Русский') + '  <>'
        out.append(f' {INV}> {lang} {RST}' if idx == 0 else f'   {lang}')
        out.append('')
        for i, v in enumerate(videos, 1):
            size = human_size(os.path.getsize(os.path.join(HERE, v)))
            line = f'  {v}  {DIM}({size}){RST}'
            out.append(f' {INV}> {v}  ({size}) {RST}' if i == idx else ' ' + line)
        print('\n'.join(out))
        k = wait_key()
        if k == 'up':
            idx = (idx - 1) % n
        elif k == 'down':
            idx = (idx + 1) % n
        elif idx == 0 and k in ('enter', 'left', 'right', ' '):
            s['lang'] = LANG[0] = 'en' if LANG[0] == 'ru' else 'ru'
            save_settings(s)
        elif k == 'enter':
            return videos[idx - 1]
        elif k == 'esc':
            return None


def menu_settings(video, info, s):
    """s - словарь настроек (изменяется). Возвращает True = старт, False = назад."""
    idx = 1   # 0 - "назад", курсор сразу на первой настройке
    while True:
        fps_val, step = frame_step(s, info)
        expected = (info['frames'] + step - 1) // step
        yes, no = T('да', 'yes'), T('нет', 'no')
        fps_txt = T('все', 'all') if fps_val == 'all' else fps_val
        items = [
            (T('<<< НАЗАД к выбору видео', '<<< BACK to video list'), ''),
            (T('Очистка (размытые/дубли/экспозиция)', 'Cleaning (blur/duplicates/exposure)'),
             T('ВКЛ', 'ON') if s['clean'] else T('ВЫКЛ', 'OFF')),
            (T('Кадров в секунду видео', 'Frames per second of video'),
             fps_txt + (T(f'  (каждый {step}-й кадр)', f'  (every {step}th frame)') if step > 1
                        else T('  (все кадры)', '  (all frames)'))),
            (T('Строгость очистки', 'Cleaning strictness'), T(*STRICT[s['strict']][0])),
            (T('Убирать дубликаты (камера стоит)', 'Remove duplicates (camera still)'), yes if s['dup'] else no),
            (T('Сохранить отбракованные в _rejected', 'Keep rejected frames in _rejected'), yes if s['keep_rej'] else no),
            (T('Формат', 'Format'), s['fmt'].upper()),
            (T('Номер в имени файла', 'Number in file name'), T(*NUMBERING[s['num']])),
            (T('Записывать EXIF (фокусное)', 'Write EXIF (focal length)'), yes if s['exif'] else no),
            (T('Фокусное для EXIF (экв. 35 мм)', 'EXIF focal length (35 mm equiv.)'), f"{s['f35']} {T('мм', 'mm')}"),
            (T('>>> НАЧАТЬ', '>>> START'), ''),
        ]
        disabled = (set() if s['clean'] else {3, 4, 5}) | (set() if s['exif'] else {9})
        out = [CLS, CYN + T('  НАСТРОЙКИ', '  SETTINGS') + RST, '',
               T('  Видео:  ', '  Video:  ') + video,
               f'  {info["w"]}x{info["h"]}, {info["fps"]:.2f} fps, {fmt_time(info["dur"])}, '
               f'~{info["frames"]} {T("кадров", "frames")}', '',
               T('  Стрелки вверх/вниз - пункт, влево/вправо - значение, Enter - начать, Esc - назад',
                 '  Up/down - item, left/right - change value, Enter - start, Esc - back'), '']
        for i, (name, val) in enumerate(items):
            txt = f'{name:<40}{val}' if val else name
            if i == idx:
                out.append(f'  {INV} {txt} {RST}')
            elif i in disabled:
                out.append(f'   {DIM}{txt}{RST}')
            else:
                out.append(f'   {txt}')
        out.append('')
        need, free = disk_estimate(s, info, expected)
        low = free is not None and need > free
        out.append((RED if low else DIM) + T(f'  Размер: ~{human_size(need)}', f'  Size: ~{human_size(need)}') +
                   (T(f', свободно на диске: {human_size(free)}', f', free on disk: {human_size(free)}')
                    if free is not None else '') +
                   (T('  - НЕ ХВАТИТ МЕСТА!', '  - NOT ENOUGH SPACE!') if low else '') + RST)
        if s['clean']:
            out.append(DIM + T(f'  Из каждых {step} кадров берётся самый резкий, затем отбрасываются размытые,',
                               f'  The sharpest of every {step} frames is taken, then blurry, over/under-exposed') + RST)
            out.append(DIM + T(f'  пере/недоэкспонированные и почти одинаковые кадры. До ~{expected} кадров.',
                               f'  and near-identical frames are dropped. Up to ~{expected} frames.') + RST)
        else:
            out.append(DIM + T(f'  Будет сохранено ~{expected} кадров без анализа.',
                               f'  ~{expected} frames will be saved without analysis.') + RST)
        stem = os.path.splitext(video)[0]
        first, second = [(1, 2), (0, 1), (0, step)][s['num']]
        out.append(DIM + T('  Имена: ', '  Names: ') + f"{stem}_{first:05d}.{s['fmt']}, {stem}_{second:05d}.{s['fmt']}..." +
                   (T('  (номера исходных кадров видео)', '  (original video frame numbers)') if s['num'] == 2 else '') +
                   RST)
        if s['exif']:
            out.append(DIM + T('  Эквивалент 35 мм пишется в EXIF (Meshroom и др. считают по нему фокусное).',
                           '  The 35 mm equivalent goes into EXIF (Meshroom etc. derive the focal length from it).') + RST)
            out.append(DIM + T('  Формула: f_мм * 43.27 / диагональ_сенсора_мм. Основная камера телефона обычно ~24-28.',
                           '  Formula: f_mm * 43.27 / sensor_diagonal_mm. A phone main camera is usually ~24-28.') + RST)
        else:
            out.append(DIM + T('  EXIF не пишется: фокусное программа фотограмметрии определит сама.',
                               '  No EXIF: the photogrammetry software will estimate the focal length itself.') + RST)
        print('\n'.join(out))
        k = wait_key()
        if k == 'up':
            idx = (idx - 1) % len(items)
        elif k == 'down':
            idx = (idx + 1) % len(items)
        elif k == 'esc':
            return False
        elif k == 'enter':
            save_settings(s)
            if idx == 0:
                return False
            if low:
                print(RED + T('\n  Места на диске не хватит на все кадры. Enter - всё равно начать, другая клавиша - назад.',
                              '\n  Not enough disk space for all frames. Enter - start anyway, any other key - back.') + RST)
                if wait_key() != 'enter':
                    continue
            return True
        elif k in ('left', 'right', ' '):
            d = -1 if k == 'left' else 1
            if idx == 1:
                s['clean'] = not s['clean']
            elif idx == 2:
                s[fps_key(s)] = (s[fps_key(s)] + d) % len(FPS_CHOICES)
            elif idx == 3 and s['clean']:
                s['strict'] = (s['strict'] + d) % len(STRICT)
            elif idx == 4 and s['clean']:
                s['dup'] = not s['dup']
            elif idx == 5 and s['clean']:
                s['keep_rej'] = not s['keep_rej']
            elif idx == 6:
                s['fmt'] = 'png' if s['fmt'] == 'jpg' else 'jpg'
            elif idx == 7:
                s['num'] = (s['num'] + d) % len(NUMBERING)
            elif idx == 8:
                s['exif'] = not s['exif']
            elif idx == 9 and s['exif']:
                i = min(range(len(FOCAL_CHOICES)), key=lambda j: abs(FOCAL_CHOICES[j] - s['f35']))
                s['f35'] = FOCAL_CHOICES[(i + d) % len(FOCAL_CHOICES)]


# ---------------------------------------------------------- обработка
def make_out_dir(name):
    base = os.path.join(HERE, name)
    path, i = base, 0
    while os.path.exists(path):
        i += 1
        path = f'{base}.{i:03d}'
    os.makedirs(path)
    return path


def run_ffmpeg_progress(cmd, total, fps, label):
    """Запускает ffmpeg с -progress и рисует прогресс-бар (по позиции в видео)."""
    start = time.time()
    done = 0
    # stderr пишем во временный файл: если ffmpeg выведет много текста,
    # канал (pipe) переполнится и процесс зависнет
    import tempfile
    with tempfile.TemporaryFile(mode='w+', encoding='utf-8', errors='replace') as errf:
        p = subprocess.Popen(cmd + ['-progress', 'pipe:1', '-nostats'], stdout=subprocess.PIPE,
                             stderr=errf, text=True, encoding='utf-8', errors='replace')
        try:
            for line in p.stdout:
                if line.startswith('out_time_us='):
                    try:
                        done = max(done, min(total, int(int(line.split('=')[1]) / 1e6 * fps)))
                        bar(done, total, start, label)
                    except ValueError:
                        pass
            p.wait()
        except KeyboardInterrupt:
            p.kill()
            raise
        errf.seek(0)
        err = errf.read()
    if p.returncode == 0:
        bar(total, total, start, label)
    print()
    if p.returncode != 0:
        lines = [l[:300] for l in err.strip().splitlines()][-10:]
        raise RuntimeError(T('ffmpeg завершился с ошибкой:', 'ffmpeg failed:') + '\n' + '\n'.join(lines))


def _even(x):
    return max(2, int(round(x / 2)) * 2)


def stream_clean(ffmpeg, path, info, out_dir, stem, s, step):
    """Один проход кластерами: ffmpeg отдаёт полные кадры, Python выбирает лучший
    в каждом окне; когда набирается кластер из CLUSTER кандидатов, по нему
    принимается решение и удачные кадры сразу пишутся на диск."""
    import threading, queue, tempfile
    from concurrent.futures import ThreadPoolExecutor
    import numpy as np
    import cv2

    W, H = _even(info['w']), _even(info['h'])
    FS, YS = W * H * 3 // 2, W * H
    if W >= H:
        aw, ah = ANALYSIS_LONG_SIDE, _even(ANALYSIS_LONG_SIDE * H / W)
    else:
        ah, aw = ANALYSIS_LONG_SIDE, _even(ANALYSIS_LONG_SIDE * W / H)
    _, k_loc, k_glob = STRICT[s['strict']]
    R = 7                      # соседей с каждой стороны для сравнения резкости
    ext = s['fmt']
    params = [cv2.IMWRITE_JPEG_QUALITY, 95] if ext == 'jpg' else [cv2.IMWRITE_PNG_COMPRESSION, 3]
    rej_dir = os.path.join(out_dir, '_rejected')
    if s['keep_rej']:
        os.makedirs(rej_dir)

    # --- ffmpeg: полные кадры в yuv420p (BT.601, как ждёт OpenCV)
    cmd = [ffmpeg, '-v', 'error', '-hwaccel', 'auto', '-i', path, '-map', '0:v:0',
           '-vf', f'scale={W}:{H}:out_color_matrix=bt601:out_range=tv,format=yuv420p',
           '-fps_mode', 'passthrough', '-f', 'rawvideo', '-']
    errf = tempfile.TemporaryFile(mode='w+', encoding='utf-8', errors='replace')
    p = subprocess.Popen(cmd, stdout=subprocess.PIPE, stderr=errf, bufsize=0)

    # --- поток чтения: заполняет буферы, пока основной поток анализирует
    free_q, full_q = queue.Queue(), queue.Queue()
    for _ in range(4):
        free_q.put(bytearray(FS))

    def reader():
        try:
            while True:
                buf = free_q.get()
                if buf is None:
                    break
                mv, got = memoryview(buf), 0
                while got < FS:
                    k = p.stdout.readinto(mv[got:])
                    if not k:
                        break
                    got += k
                if got < FS:
                    break
                full_q.put(buf)
        finally:
            full_q.put(None)
    threading.Thread(target=reader, daemon=True).start()

    # --- каждый кандидат сразу кодируется в JPEG/PNG в фоновых потоках;
    #     в памяти держим уже сжатые кадры (~2 МБ вместо ~12 МБ сырого 4K)
    pool = ThreadPoolExecutor(max_workers=3)
    slots = threading.Semaphore(12)   # не больше 12 сырых кадров в очереди кодирования

    def encode(data):
        try:
            bgr = cv2.cvtColor(data.reshape(H * 3 // 2, W), cv2.COLOR_YUV2BGR_I420)
            ok, enc = cv2.imencode('.' + ext, bgr, params)
            return enc if ok else None
        finally:
            slots.release()

    tiff = exif_for(s, stem, W, H)

    def write(c, fname):
        enc = c['enc'].result()
        if enc is not None:
            with open(fname, 'wb') as f:
                f.write(with_exif(enc.tobytes(), ext, tiff))

    # --- состояние отбора
    sharp_all, good_all = [], []     # по всем кандидатам (лучший кадр каждого окна)
    pending = []                     # кандидаты текущего кластера, ждущие решения
    st = {'kept': 0, 'last_thumb': None, 'cnt': {}, 'clusters': 0}

    def decide(c, glob_med):
        j = c['j']
        lo, hi = max(0, j - R), min(len(sharp_all), j + R + 1)
        loc = [x for x, g in zip(sharp_all[lo:hi], good_all[lo:hi]) if g]
        loc_med = float(np.median(loc)) if loc else glob_med
        reason = None
        if not c['good']:
            reason = 'exposure'
        elif c['sharp'] < k_loc * loc_med or c['sharp'] < k_glob * glob_med:
            reason = 'blur'
        elif s['dup'] and st['last_thumb'] is not None and                 float(np.abs(c['thumb'] - st['last_thumb']).mean()) < DUP_THRESHOLD:
            reason = 'dup'
        if reason is None:
            num = [st['kept'] + 1, st['kept'], c['idx']][s['num']]
            st['kept'] += 1
            st['last_thumb'] = c['thumb']
            write(c, os.path.join(out_dir, f'{stem}_{num:05d}.{ext}'))
        else:
            st['cnt'][reason] = st['cnt'].get(reason, 0) + 1
            if s['keep_rej']:
                write(c, os.path.join(rej_dir, f'{stem}_frame{c["idx"]:06d}_{reason}.{ext}'))

    def flush_cluster(final=False):
        """Решает судьбу кластера. Последние R кандидатов переносятся в следующий
        кластер: им для сравнения нужны соседи, которых ещё не было."""
        n_dec = len(pending) if final else len(pending) - R
        if n_dec <= 0:
            return
        sh = np.array(sharp_all)
        good = np.array(good_all)
        ref = sh[good] if good.any() else sh
        glob_med = float(np.median(ref))
        for c in pending[:n_dec]:
            decide(c, glob_med)
        del pending[:n_dec]
        st['clusters'] += 1

    def close_window(best):
        sh, br, idx, data, small = best
        good = DARK <= br <= BRIGHT
        sharp_all.append(sh)
        good_all.append(good)
        slots.acquire()
        pending.append({'j': len(sharp_all) - 1, 'idx': idx, 'sharp': sh, 'good': good,
                        'enc': pool.submit(encode, data),
                        'thumb': cv2.resize(small, (64, 36), interpolation=cv2.INTER_AREA).astype(np.float32)})
        if len(pending) >= CLUSTER + R:
            flush_cluster()

    total, n, best = info['frames'], 0, None
    start = time.time()
    try:
        while True:
            buf = full_q.get()
            if buf is None:
                break
            y = np.frombuffer(buf, np.uint8, YS).reshape(H, W)
            small = cv2.resize(y, (aw, ah), interpolation=cv2.INTER_AREA)
            sharp = float(cv2.Laplacian(small, cv2.CV_32F).var())
            bright = float(small.mean())
            # в окне: лучший кадр с нормальной экспозицией, иначе просто самый резкий
            if best is None or (DARK <= bright <= BRIGHT, sharp) > (DARK <= best[1] <= BRIGHT, best[0]):
                best = (sharp, bright, n, np.frombuffer(buf, np.uint8).copy(), small)
            free_q.put(buf)
            n += 1
            if n % step == 0:
                close_window(best)
                best = None
            if n % 10 == 0:
                bar(n, total, start, T('кластер', 'cluster') + f' {st["clusters"] + 1:>3}, ' +
                    T('сохранено', 'saved') + f' {st["kept"]:>5}')
        if best is not None:
            close_window(best)
        flush_cluster(final=True)
        pool.shutdown(wait=True)
        bar(n, n, start, T('кластер', 'cluster') + f' {st["clusters"]:>3}, ' +
            T('сохранено', 'saved') + f' {st["kept"]:>5}')
        print()
    except KeyboardInterrupt:
        p.kill()
        free_q.put(None)
        pool.shutdown(wait=True)
        raise
    finally:
        p.wait()
        errf.seek(0)
        err = errf.read()
        errf.close()
    if n == 0 or (p.returncode != 0 and n < total * 0.95):
        lines = [l[:300] for l in err.strip().splitlines()][-10:]
        raise RuntimeError(T('ffmpeg завершился с ошибкой:', 'ffmpeg failed:') + '\n' + '\n'.join(lines))
    return st['kept'], st['cnt']


def extract_all(ffmpeg, path, info, out_dir, stem, s, step):
    """Без очистки: ffmpeg сам пишет каждый step-й кадр."""
    ext = s['fmt']
    q = ['-q:v', '2'] if ext == 'jpg' else ['-compression_level', '3']
    vf = 'null' if step == 1 else f"select='not(mod(n\\,{step}))'"
    cmd = [ffmpeg, '-v', 'error', '-y', '-hwaccel', 'auto', '-i', path, '-map', '0:v:0',
           '-vf', vf, '-fps_mode', 'passthrough'] + q + \
          ['-start_number', '1' if s['num'] == 0 else '0', os.path.join(out_dir, f'{stem}_%05d.{ext}')]
    run_ffmpeg_progress(cmd, info['frames'], info['fps'], T('Экспорт', 'Export '))
    if s['num'] == 2 and step > 1:
        # файл i - это кадр видео i*step; переименование с конца, чтобы имена не пересекались
        nums = sorted((int(f[len(stem) + 1:-len(ext) - 1]) for f in os.listdir(out_dir)
                       if f.startswith(stem + '_') and f.endswith('.' + ext)), reverse=True)
        for i in nums:
            os.rename(os.path.join(out_dir, f'{stem}_{i:05d}.{ext}'),
                      os.path.join(out_dir, f'{stem}_{i * step:05d}.{ext}'))
    # ffmpeg не пишет EXIF - дописываем в готовые файлы
    tiff = exif_for(s, stem, info['w'], info['h'])
    if tiff is None:
        return
    files = sorted(f for f in os.listdir(out_dir) if f.endswith('.' + ext))
    start = time.time()
    for i, f in enumerate(files, 1):
        fp = os.path.join(out_dir, f)
        with open(fp, 'rb') as fh:
            data = fh.read()
        with open(fp, 'wb') as fh:
            fh.write(with_exif(data, ext, tiff))
        if i % 20 == 0 or i == len(files):
            bar(i, len(files), start, 'EXIF   ')
    print()


def process(ffmpeg, ffprobe, video, info, s):
    path = os.path.join(HERE, video)
    stem = os.path.splitext(video)[0]
    fps_val, step = frame_step(s, info)
    if s['clean'] and not ensure_libs():
        return
    out_dir = make_out_dir(stem)
    print(CLS + CYN + T('  Обработка: ', '  Processing: ') + video + RST)
    print(T('  Папка: ', '  Folder: ') + out_dir +
          DIM + T('  (кадры появляются по ходу работы)', '  (frames appear as they are processed)') + RST + '\n')
    t0 = time.time()
    if s['clean']:
        kept, cnt = stream_clean(ffmpeg, path, info, out_dir, stem, s, step)
        rej = sum(cnt.values())
        print(T('  Оставлено: ', '  Kept: ') + f'{GRN}{kept}{RST},  ' + T('отбраковано: ', 'rejected: ') +
              f'{YEL}{rej}{RST}' +
              (' (' + ', '.join(f'{T(*REASONS[k])}: {v}' for k, v in cnt.items()) + ')' if cnt else ''))
    else:
        extract_all(ffmpeg, path, info, out_dir, stem, s, step)
    n = len([f for f in os.listdir(out_dir) if f.endswith('.' + s['fmt'])])
    print(f'\n  {GRN}' + T('Готово!', 'Done!') + f'{RST} ' + T('Сохранено кадров: ', 'Frames saved: ') +
          f'{n}   ' + T('Время: ', 'Time: ') + fmt_time(time.time() - t0))
    print(T('  Папка: ', '  Folder: ') + out_dir + '\n')
    pause(T('Нажмите любую клавишу, чтобы вернуться к списку...', 'Press any key to return to the list...'))


# -------------------------------------------------------------------- main
def main():
    settings = load_settings({'lang': 'en', 'clean': True, 'fps': FPS_CHOICES.index('3'), 'strict': 1, 'dup': True,
                              'keep_rej': False, 'fmt': 'jpg', 'num': 0,
                              'fps_raw': FPS_CHOICES.index('all'), 'exif': True, 'f35': DEFAULT_F35})
    if settings['f35'] not in FOCAL_CHOICES:
        settings['f35'] = DEFAULT_F35
    settings['fps'] %= len(FPS_CHOICES)
    settings['fps_raw'] %= len(FPS_CHOICES)
    settings['strict'] %= len(STRICT)
    settings['num'] %= len(NUMBERING)
    if settings['lang'] not in ('ru', 'en'):
        settings['lang'] = 'en'
    LANG[0] = settings['lang']
    ffmpeg, ffprobe = find_tool('ffmpeg'), find_tool('ffprobe')
    if not ffmpeg or not ffprobe:
        print(RED + T('ffmpeg/ffprobe не найдены.', 'ffmpeg/ffprobe not found.') + RST)
        print(T('Установите: winget install Gyan.FFmpeg  (или положите ffmpeg.exe и ffprobe.exe рядом с батником)',
                'Install: winget install Gyan.FFmpeg  (or put ffmpeg.exe and ffprobe.exe next to this .bat)'))
        pause()
        return
    while True:
        videos = sorted(f for f in os.listdir(HERE)
                        if f.lower().endswith(VIDEO_EXT) and os.path.isfile(os.path.join(HERE, f)))
        if not videos:
            print(CLS + YEL + T(f'  В папке {HERE} нет видеофайлов.', f'  No video files in {HERE}.') + RST)
            pause()
            return
        video = menu_select_video(videos, settings)
        if video is None:
            return
        try:
            info = probe(ffprobe, os.path.join(HERE, video))
        except Exception as e:
            print(RED + T(f'\n  Ошибка чтения {video}: {e}', f'\n  Error reading {video}: {e}') + RST)
            pause()
            continue
        if not menu_settings(video, info, settings):
            continue
        try:
            process(ffmpeg, ffprobe, video, info, settings)
        except KeyboardInterrupt:
            print(YEL + T('\n\n  Прервано.', '\n\n  Interrupted.') + RST)
            pause()
        except Exception as e:
            print(RED + T(f'\n  Ошибка: {e}', f'\n  Error: {e}') + RST)
            if 'No space left' in str(e) or getattr(e, 'errno', None) == 28:
                print(YEL + T('\n  Закончилось место на диске. Удалите лишние папки с кадрами, выберите JPG\n'
                              '  вместо PNG или меньше кадров в секунду.',
                              '\n  The disk is full. Delete old frame folders, choose JPG instead of PNG\n'
                              '  or fewer frames per second.') + RST)
            pause()


if __name__ == '__main__':
    try:
        main()
    except KeyboardInterrupt:
        pass
    print(RST, end='')
