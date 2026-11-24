import argparse
from contextlib import contextmanager
import csv
from datetime import datetime, timezone
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
import ipaddress
import json
import math
import os
from pathlib import Path
import queue
import re
import shlex
import signal
import statistics
import subprocess
import sys
import tempfile
import threading
import time
from urllib.parse import urlsplit
from uuid import uuid4


ROOT = Path(__file__).resolve().parent.parent
BUNDLE = re.search(r'"bundleName"\s*:\s*"([\w.]+)"',
                   (ROOT / 'AppScope/app.json5').read_text()).group(1)
MARKERS = re.compile(
    r'^\s*(\d{10})\.(\d{3,9})\s+.*?/(ArkClashBench|ClashVpnAbility):\s+'
    r'(dashboard_interactive|vpn_connect_click|vpn_tun_confirmed|core started without VPN)\s*$'
)
METRICS = (
    'first_frame_ms', 'interactive_ms', 'launch_to_core_ms', 'click_to_core_ms', 'click_to_tun_ms',
    'tun_to_probe_ms', 'click_to_https_ms', 'dns_ms', 'tcp_ms', 'tls_ms', 'first_byte_ms',
)
FIELDS = ('scenario', 'round', 'status', 'http_status', *METRICS)
PROBE_FIELDS = ('dns_ms', 'tcp_ms', 'tls_ms', 'first_byte_ms')
PROBE_STATUSES = {'ok', 'other_exit', 'timeout', 'request_failed', 'unexpected_http_status',
                  'invalid_exit_response', 'missing_resource_timing', 'no_new_tls_connection'}


class BenchError(Exception):
    pass


def run(command, description, timeout=20, env=None):
    try:
        process = subprocess.run(command, capture_output=True, text=True, timeout=timeout, env=env, check=True)
    except subprocess.TimeoutExpired:
        raise BenchError(f'{description}_timeout') from None
    except (OSError, subprocess.CalledProcessError):
        raise BenchError(f'{description}_failed') from None
    return process.stdout.replace('\r', '')


class Device:
    def __init__(self):
        hdc = os.environ['HDC']
        target = os.environ.get('HDC_TARGET')
        targets = [line for line in run([hdc, 'list', 'targets'], 'hdc_list').splitlines()
                   if line and line != '[Empty]']
        if target not in targets and (target or len(targets) != 1):
            raise BenchError('请连接一台已授权的 HDC 设备，或用 HDC_TARGET 选择已连接的设备')
        self.command = [hdc, '-t', target or targets[0]]
        self.lock = '/data/local/tmp/arkclash-bench.lock'
        self.remote = f'/data/local/tmp/arkclash-bench-{uuid4().hex}'
        self.clock_path = f'{self.remote}/clock'
        self.layout_path = f'{self.remote}.json'

    def shell(self, command, description, timeout=20):
        output = run([*self.command, 'shell', f"( {command} ); printf '\\nBENCH_EXIT:%s\\n' \"$?\""],
                     description, timeout)
        body, _, status = output.rpartition('\nBENCH_EXIT:')
        if status.strip() != '0':
            raise BenchError(f'{description}_failed')
        return body

    def send(self, local, remote):
        run([*self.command, 'file', 'send', str(local), remote], 'hdc_upload', timeout=60)

    def stop(self):
        output = self.shell(f'aa force-stop {BUNDLE}', 'force_stop')
        if not re.search(r'force stop process successfully', output, re.IGNORECASE):
            raise BenchError('force_stop_unconfirmed')

    def launch(self):
        self.stop()
        output = self.shell(f'{self.clock_path} && aa start -W -a EntryAbility -b {BUNDLE}', 'launch')
        clock = re.search(r'^\s*(\d{13})\s*$', output, re.MULTILINE)
        mode = re.search(r'^\s*StartMode:\s*Cold\s*$', output, re.MULTILINE)
        frame = re.search(r'^\s*TotalTime:\s*(\d+)(?:\s*ms)?\s*$', output, re.MULTILINE)
        if not (clock and mode and frame):
            raise BenchError('cold_launch_unconfirmed')
        return int(clock[1]), int(frame[1])

    def markers(self, since):
        markers = {}
        output = self.shell('hilog -x -t app -T ArkClashBench,ClashVpnAbility -v epoch -v msec '
                            "-e '^(dashboard_interactive|vpn_connect_click|vpn_tun_confirmed|core started without VPN)$'",
                            'read_markers', timeout=4)
        for line in output.splitlines():
            match = MARKERS.fullmatch(line)
            if match:
                stamp = int(match[1]) * 1000 + int(match[2][:3])
                if stamp >= since:
                    markers[match[4]] = min(stamp, markers.get(match[4], stamp))
        return markers

    def wait_markers(self, since, *required):
        deadline = time.monotonic() + 15
        while time.monotonic() < deadline:
            markers = self.markers(since)
            if all(name in markers for name in required):
                return markers
            time.sleep(0.1)
        raise BenchError(f'{required[-1].replace(" ", "_")}_timeout')

    def button(self):
        try:
            output = self.shell(f'uitest dumpLayout -p {self.layout_path} >/dev/null && cat {self.layout_path}',
                                'dashboard_layout')
            try:
                return button_center(json.loads(output))
            except ValueError:
                raise BenchError('invalid_dashboard_layout') from None
        finally:
            self.shell(f'rm -f {self.layout_path}', 'remove_layout')

    def open_browser(self, url):
        output = self.shell(f'aa start -A ohos.want.action.viewData -U {shlex.quote(url)}', 'open_browser')
        if 'start ability successfully' not in output.lower():
            raise BenchError('browser_launch_unconfirmed')

    @contextmanager
    def reverse_port(self, port):
        rule = [f'tcp:{port}', f'tcp:{port}']
        output = run([*self.command, 'rport', *rule], 'create_browser_forward')
        if 'Forwardport result:OK' not in output:
            raise BenchError('create_browser_forward_failed')
        try:
            yield
        finally:
            output = run([*self.command, 'fport', 'rm', *rule], 'remove_browser_forward')
            if 'Remove forward ruler success' not in output:
                raise BenchError('remove_browser_forward_failed')


class ProbeHandler(BaseHTTPRequestHandler):
    def log_message(self, *_args):
        pass

    def respond(self, status, data=b'', content_type='text/plain; charset=utf-8'):
        self.send_response(status)
        self.send_header('Content-Type', content_type)
        self.send_header('Cache-Control', 'no-store')
        self.send_header('Content-Length', str(len(data)))
        self.send_header('Content-Security-Policy', "default-src 'none'; script-src 'self'; connect-src 'self' https:")
        self.end_headers()
        self.wfile.write(data)

    def do_GET(self):
        token, config, _samples = self.server.session
        if token is None:
            self.respond(404)
        elif self.path == f'/{token}/index':
            self.respond(200, '<meta charset="utf-8"><body>ArkClash 正在采样'
                         '<script type="module" src="probe.mjs"></script>'.encode(), 'text/html; charset=utf-8')
        elif self.path == f'/{token}/probe.mjs':
            self.respond(200, self.server.script, 'text/javascript; charset=utf-8')
        elif self.path == f'/{token}/config':
            self.respond(200, json.dumps(config).encode(), 'application/json')
        else:
            self.respond(404)

    def do_POST(self):
        token, _config, samples = self.server.session
        if samples is None or self.path != f'/{token}/sample':
            self.respond(404)
            return
        try:
            size = int(self.headers.get('Content-Length', 0))
            if not 0 < size <= 2048:
                raise ValueError
            row = json.loads(self.rfile.read(size))
            if not isinstance(row, dict) or row.get('status') not in PROBE_STATUSES:
                raise ValueError
            for field in ('started_ms', 'complete_ms', 'http_status', *PROBE_FIELDS):
                if field in PROBE_FIELDS and field not in row and row['status'] not in ('ok', 'other_exit'):
                    continue
                value = row.get(field)
                if type(value) not in (int, float) or not math.isfinite(value) or value < 0:
                    raise ValueError
            samples.put_nowait({key: row[key] for key in (
                'status', 'started_ms', 'complete_ms', 'http_status', *PROBE_FIELDS) if key in row})
        except (TypeError, ValueError, queue.Full):
            self.respond(400)
            return
        self.respond(204)


class BrowserProbe:
    def __init__(self, device, target, timeout):
        self.device = device
        self.url, self.exit_ip = target
        self.timeout = timeout

    @contextmanager
    def session(self):
        with ThreadingHTTPServer(('127.0.0.1', 0), ProbeHandler) as self.server:
            self.port = self.server.server_port
            self.server.session = (None, {}, None)
            self.server.script = (ROOT / 'scripts/bench-browser.mjs').read_bytes()
            thread = threading.Thread(target=self.server.serve_forever, daemon=True)
            with self.device.reverse_port(self.port):
                thread.start()
                try:
                    yield self
                finally:
                    self.server.shutdown()
                    thread.join()

    def measure(self, count):
        token = uuid4().hex
        samples = queue.Queue(maxsize=count)
        self.server.session = (token, {'url': self.url, 'exit_ip': self.exit_ip,
                                       'count': count, 'timeout': self.timeout}, samples)
        try:
            self.device.open_browser(f'http://127.0.0.1:{self.port}/{token}/index')
            for index in range(count):
                try:
                    yield samples.get(timeout=self.timeout + (20 if index == 0 else 5))
                except queue.Empty:
                    raise BenchError('browser_result_timeout') from None
        finally:
            self.server.session = (None, {}, None)


def button_center(tree):
    pending = [tree]
    centers = []
    while pending:
        node = pending.pop()
        pending.extend(node.get('children', []))
        attrs = node.get('attributes', {})
        if (attrs.get('type') == 'Button' and attrs.get('bundleName', BUNDLE) == BUNDLE and
                'arkclash_vpn_toggle' in (attrs.get('key'), attrs.get('id')) and
                str(attrs.get('enabled', '')).lower() == 'true'):
            bounds = re.fullmatch(r'\[(\d+),(\d+)\]\[(\d+),(\d+)\]', attrs.get('bounds', ''))
            if bounds:
                left, top, right, bottom = map(int, bounds.groups())
                if right > left and bottom > top:
                    centers.append(((left + right) // 2, (top + bottom) // 2))
    if len(centers) != 1:
        raise BenchError('请在首页显示已启用的 VPN 连接按钮，固定屏幕方向和仪表盘布局')
    return centers[0]


def build_clock(work):
    abi = os.environ.get('ABI', 'arm64-v8a')
    architectures = {'arm64-v8a': 'aarch64', 'x86_64': 'x86_64'}
    if abi not in architectures:
        raise BenchError('不支持的 ABI')
    clang = Path(os.environ['OHOS_SDK']) / 'native/llvm/bin' / f'{architectures[abi]}-unknown-linux-ohos-clang'
    binary = work / 'clock'
    run([str(clang), '-O2', '-Wall', '-Wextra', '-Werror', '-fPIE', '-pie',
         '-o', str(binary), 'scripts/bench-clock.c'], 'build_device_clock')
    return binary


def endpoint():
    url = os.environ.get('BENCH_URL', '')
    try:
        target = urlsplit(url)
        exit_ip = str(ipaddress.ip_address(os.environ.get('BENCH_EXIT_IP', '')))
        if (target.scheme != 'https' or not target.hostname or target.username is not None or
                target.port == 0 or target.query or target.fragment or any(ch.isspace() for ch in url)):
            raise ValueError
    except ValueError:
        raise BenchError('网络测量需要 BENCH_URL（无凭据的 HTTPS 端点）和 BENCH_EXIT_IP（预期代理出口 IP）') from None
    return url, exit_ip


def startup(device, row):
    started, first_frame = device.launch()
    row['first_frame_ms'] = first_frame
    markers = device.wait_markers(started, 'dashboard_interactive')
    row['interactive_ms'] = max(first_frame, markers['dashboard_interactive'] - started)


def connect(device, row, center, warm, probe):
    started, _ = device.launch()
    required = ['dashboard_interactive']
    if warm:
        required.append('core started without VPN')
    device.wait_markers(started, *required)
    device.shell(f'uitest uiInput click {center[0]} {center[1]}', 'click_vpn')
    markers = device.wait_markers(started, 'vpn_connect_click', 'core started without VPN', 'vpn_tun_confirmed')
    click, core, tun = (markers[name] for name in ('vpn_connect_click', 'core started without VPN', 'vpn_tun_confirmed'))
    row['launch_to_core_ms'] = core - started
    row['click_to_core_ms'] = max(0, core - click)
    if tun < max(click, core):
        raise BenchError('invalid_vpn_marker_order')
    row['click_to_tun_ms'] = tun - click
    if warm != (core < click) or core == click:
        raise BenchError('core_phase_unconfirmed')
    sample, = probe.measure(1)
    row['http_status'] = sample['http_status']
    row['tun_to_probe_ms'] = round(sample['started_ms'] - tun, 3)
    if row['tun_to_probe_ms'] < 0:
        raise BenchError('invalid_probe_marker_order')
    if sample['status'] != 'ok':
        raise BenchError(sample['status'])
    row['click_to_https_ms'] = round(sample['started_ms'] - click + sample['complete_ms'], 3)


def summarize(rows):
    report = {}
    for scenario in sorted({row['scenario'] for row in rows}):
        samples = [row for row in rows if row['scenario'] == scenario]
        success = [row for row in samples if row['status'] == 'ok']
        metrics = {}
        for key in METRICS:
            values = sorted(float(row[key]) for row in success if row.get(key) not in ('', None))
            if values:
                metrics[key] = {
                    'n': len(values), 'p50': round(statistics.median(values), 3),
                    'p95': values[math.ceil(0.95 * len(values)) - 1], 'max': values[-1],
                }
        report[scenario] = {'samples': len(samples), 'failed': len(samples) - len(success),
                            'timeouts': sum(row['status'].endswith('timeout') for row in samples), 'metrics': metrics}
    return report


def compare(paths):
    reports = []
    for path in paths:
        with (path / 'samples.csv').open(newline='') as stream:
            reports.append(summarize(list(csv.DictReader(stream))))
    base, candidate = reports
    print('场景 / 指标                          基线 p50 / p95     待比 p50 / p95     p95 差值 (ms)')
    for scenario in sorted(base.keys() & candidate.keys()):
        old, new = base[scenario], candidate[scenario]
        print(f"{scenario} 失败数 {old['failed']}/{old['samples']} → {new['failed']}/{new['samples']}")
        for metric, timing in old['metrics'].items():
            next_timing = new['metrics'].get(metric)
            if next_timing is not None:
                print(f"  {metric:<33} {timing['p50']:8.2f} / {timing['p95']:8.2f}"
                      f"  {next_timing['p50']:8.2f} / {next_timing['p95']:8.2f}"
                      f"  {next_timing['p95'] - timing['p95']:+8.2f}")


def collect(args, device, save):
    target = endpoint() if args.scenario != 'startup' else None

    with tempfile.TemporaryDirectory(prefix='arkclash-bench-') as temp:
        binary = build_clock(Path(temp))
        device.shell(f'umask 077 && mkdir {device.lock}', 'acquire_device_lock')
        try:
            device.shell(f'umask 077 && mkdir {device.remote}', 'create_device_workspace')
            device.send(binary, device.clock_path)
            device.shell(f'chmod 700 {device.clock_path} && {device.clock_path} >/dev/null', 'check_device_clock')
            save.metadata['model'] = device.shell('param get const.product.model', 'device_model').strip()
            save.metadata['system'] = device.shell('param get const.product.software.version', 'device_system').strip()
            try:
                # 先做一次不计入报告的启动，尽早发现授权弹窗、配置或日志采集问题。
                startup(device, {})
                if args.scenario in ('all', 'startup'):
                    for index in range(1, args.startup_runs + 1):
                        save.trial('startup', index, lambda row: startup(device, row))
                if target is not None:
                    with BrowserProbe(device, target, args.timeout).session() as probe:
                        collect_network_trials(args, device, probe, save)
            finally:
                device.stop()
        finally:
            try:
                device.shell(f'rm -f {device.layout_path} {device.clock_path} && rmdir {device.remote}',
                             'remove_device_workspace')
            finally:
                device.shell(f'rmdir {device.lock}', 'release_device_lock')


def collect_network_trials(args, device, probe, save):
    center = device.button()
    device.stop()
    before, = probe.measure(1)
    if before['status'] != 'other_exit':
        raise BenchError(f'断开时端点必须返回与预期不同的出口 IP（{before["status"]}）')
    connect(device, {}, center, True, probe)
    for index in range(1, args.connect_runs + 1):
        for warm in (False, True):
            scenario = 'warm_connect' if warm else 'cold_connect'
            save.trial(scenario, index, lambda row: connect(device, row, center, warm, probe))

    if save.rows[-1]['status'] != 'ok':
        connect(device, {}, center, True, probe)
    for index, row in enumerate(probe.measure(args.request_runs), 1):
        save.add({'scenario': 'new_connection', 'round': index, 'status': row['status'], 'http_status': row['http_status'],
                  **{key: row.get(key) for key in PROBE_FIELDS}})


class Samples:
    def __init__(self, args):
        self.directory = args.output or ROOT / 'dist/bench' / f'{args.label}-{uuid4().hex[:8]}'
        self.directory.mkdir(parents=True, exist_ok=False)
        self.rows = []
        with (self.directory / 'samples.csv').open('w', newline='') as stream:
            csv.DictWriter(stream, fieldnames=FIELDS).writeheader()
        self.metadata = {'label': args.label, 'profile_size': args.profile_size,
                         'abi': os.environ.get('ABI', 'arm64-v8a'),
                         'started_at': datetime.now(timezone.utc).isoformat()}

    def add(self, row):
        path = self.directory / 'samples.csv'
        with path.open('a', newline='') as stream:
            csv.DictWriter(stream, fieldnames=FIELDS).writerow(row)
        self.rows.append(row)

    def trial(self, scenario, index, measure):
        row = {'scenario': scenario, 'round': index, 'status': 'ok'}
        try:
            measure(row)
        except BenchError as error:
            row['status'] = str(error)
        self.add(row)
        print(f'{scenario} {index}: {row["status"]}', flush=True)

    def finish(self):
        report = {'metadata': self.metadata, 'scenarios': summarize(self.rows)}
        (self.directory / 'summary.json').write_text(json.dumps(report, ensure_ascii=False, indent=2) + '\n')
        print(f'测量目录 {self.directory}', flush=True)


def positive_int(value):
    integer = int(value)
    if integer < 1:
        raise argparse.ArgumentTypeError('请输入正整数')
    return integer


def main():
    parser = argparse.ArgumentParser(description='ArkClash Release HAP 真机性能测量')
    parser.add_argument('--scenario', choices=('startup', 'network', 'all'), default='all')
    parser.add_argument('--label', default='local', help='版本或试验标签，只使用字母、数字、点、下划线和连字符')
    parser.add_argument('--profile-size', type=positive_int, help='基准配置的节点数量')
    parser.add_argument('--output', type=Path, help='输出目录，须为新路径，默认在 dist/bench/ 下创建')
    parser.add_argument('--startup-runs', type=positive_int, default=30)
    parser.add_argument('--connect-runs', type=positive_int, default=30, help='冷、暖接入各自的轮数')
    parser.add_argument('--request-runs', type=positive_int, default=100)
    parser.add_argument('--timeout', type=positive_int, default=8, help='单次 HTTPS 请求的超时秒数')
    parser.add_argument('--compare', type=Path, nargs=2, metavar=('BASELINE', 'CANDIDATE'), help='比较两个本地报告目录')
    args = parser.parse_args()
    if not re.fullmatch(r'[a-zA-Z0-9][a-zA-Z0-9._-]*', args.label):
        parser.error('无效的 --label')
    if args.compare:
        compare(args.compare)
        return 0

    device = Device()
    save = Samples(args)
    try:
        collect(args, device, save)
    finally:
        save.finish()
    return int(any(row['status'] != 'ok' for row in save.rows))


if __name__ == '__main__':
    signal.signal(signal.SIGTERM, lambda _signum, _frame: signal.raise_signal(signal.SIGINT))
    try:
        sys.exit(main())
    except KeyboardInterrupt:
        sys.exit(130)
    except (BenchError, OSError, ValueError) as error:
        sys.exit(f'bench: {error}')
