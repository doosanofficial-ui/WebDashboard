"""Synthetic export evidence only; no Simulator control or measurement reads."""
import json
import math
import os
from pathlib import Path
import stat
import subprocess
import threading
import time
import uuid

MARKER_NAME = 'admission.json'
TRACE_NAME = 'export-dismissal-audit.jsonl'
MAX_BYTES = 65536
ROW_FIELDS = {'runID', 'ownerID', 'requestID', 'callbackID', 'event', 'format', 'presented',
              'previousPresented', 'completionAccepted', 'uptime', 'epoch', 'sequence'}
EVENTS = {'begin', 'accept', 'presented', 'finish', 'cancel', 'completion', 'onChange', 'appear', 'disappear'}


def audit_directory(container):
    return container / 'Library/Application Support/ExportDismissalAudit'


def install_marker(container, commit):
    directory = audit_directory(container)
    directory.mkdir(mode=0o700, parents=True, exist_ok=True)
    value = {'scope': 'qualified-synthetic-fixture', 'runID': str(uuid.uuid4()), 'commit': commit}
    descriptor = os.open(directory / MARKER_NAME, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
    with os.fdopen(descriptor, 'w') as stream:
        json.dump(value, stream)


def bounded_regular(path, maximum):
    descriptor = os.open(path, os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK)
    with os.fdopen(descriptor, 'rb') as stream:
        info = os.fstat(stream.fileno())
        if not stat.S_ISREG(info.st_mode) or info.st_size > maximum:
            raise ValueError('unsupported diagnostic file')
        data = stream.read(maximum + 1)
        if len(data) > maximum: raise ValueError('oversized diagnostic file')
        return data


def strict_json(data):
    def unique(pairs):
        value = {}
        for key, item in pairs:
            if key in value: raise ValueError('duplicate diagnostic key')
            value[key] = item
        return value
    return json.loads(data, object_pairs_hook=unique)


def collect_trace(container, results, resolve_container=None):
    began = time.monotonic()
    receipt = {'scope': 'fixed synthetic trace only; optional and never changes UI verdict', 'status': 'unavailable'}
    try:
        receipt['collectionStage'] = 'container-resolution'
        if resolve_container is not None: container = resolve_container()
        directory = audit_directory(container)
        receipt['collectionStage'] = 'admission-read'
        if directory.is_symlink(): raise ValueError('linked diagnostic directory')
        marker = strict_json(bounded_regular(directory / MARKER_NAME, 1024))
        if marker['scope'] != 'qualified-synthetic-fixture': raise ValueError('wrong admission')
        run_id = uuid.UUID(marker['runID'])
        receipt['collectionStage'] = 'trace-read'
        data = bounded_regular(directory / TRACE_NAME, MAX_BYTES)
        receipt['collectionStage'] = 'trace-validation'
        rows = [strict_json(line) for line in data.splitlines()]
        if not rows or len(rows) > 128: raise ValueError('invalid trace count')
        for index, row in enumerate(rows, 1):
            if not isinstance(row, dict) or not set(row) <= ROW_FIELDS: raise ValueError('unexpected diagnostic fields')
            if uuid.UUID(row['runID']) != run_id or type(row['sequence']) is not int or row['sequence'] != index: raise ValueError('run/order mismatch')
            uuid.UUID(row['ownerID'])
            for key in ['requestID', 'callbackID']:
                if row.get(key) is not None: uuid.UUID(row[key])
            if row['event'] not in EVENTS or row.get('format') not in [None, 'json', 'csv']: raise ValueError('invalid diagnostic enum')
            if type(row['presented']) is not bool: raise ValueError('invalid presented state')
            for key in ['previousPresented', 'completionAccepted']:
                if row.get(key) is not None and type(row[key]) is not bool: raise ValueError('invalid diagnostic state')
            for key in ['uptime', 'epoch']:
                if type(row[key]) not in [int, float] or not math.isfinite(row[key]): raise ValueError('invalid clock')
        receipt['collectionStage'] = 'trace-copy'
        (results / TRACE_NAME).write_bytes(data)
        receipt.update(status='collected', runID=str(run_id), rowCount=len(rows),
                       atRowCapacity=len(rows) == 128, actualTouchDeliveryRecorded=False)
    except Exception as error:
        receipt['observationErrorType'] = type(error).__name__
    finally:
        receipt['elapsedSeconds'] = time.monotonic() - began
        try: (results / 'export-audit-collection.json').write_text(json.dumps(receipt, indent=2))
        except Exception: pass


def collect_owned_trace(simulator, results):
    # A test-time app update can move its data container. Resolve only this
    # runner-created Simulator after the original verdict, inside the 5s worker.
    def resolve():
        device = uuid.UUID(simulator)
        command = ['xcrun', 'simctl', 'get_app_container', str(device).upper(),
                   'local.webdashboard.Telemetry', 'data']
        value = subprocess.run(command, stdout=subprocess.PIPE, stderr=subprocess.DEVNULL,
                               text=True, check=True, timeout=2).stdout.strip()
        container = Path(value)
        if not container.is_absolute() or len(container.parents) < 6:
            raise ValueError('unsupported owned container')
        uuid.UUID(container.name)
        if ([parent.name for parent in list(container.parents)[:4]] != ['Application', 'Data', 'Containers', 'data']
                or uuid.UUID(container.parents[4].name) != device or container.parents[5].name != 'Devices'):
            raise ValueError('foreign container')
        return container
    collect_trace(None, results, resolve_container=resolve)


class RunnerHeartbeat:
    """No subprocess, AX or disk operations while UI testing is in progress."""
    def __init__(self, receipt, interval=5):
        self.receipt, self.interval = receipt, interval
        self.samples = []
        self.stop = threading.Event()
        self.worker = None

    def sample(self):
        row = {'monotonic': time.monotonic(), 'epoch': time.time()}
        try: row['loadAverage'] = list(os.getloadavg())
        except Exception as error: row['observationErrorType'] = type(error).__name__
        self.samples.append(row)

    def observe(self):
        while not self.stop.wait(self.interval):
            if len(self.samples) >= 256: return
            self.sample()

    def __enter__(self):
        try:
            self.sample()
            self.worker = threading.Thread(target=self.observe, daemon=True, name='runner-memory-heartbeat')
            self.worker.start()
        except Exception: pass
        return self

    def __exit__(self, *exception):
        self.stop.set()
        try:
            if self.worker: self.worker.join(timeout=0.1)
            value = {'intervalSeconds': self.interval, 'workerStopped': not self.worker or not self.worker.is_alive(),
                     'scope': 'host scheduler/load samples, not CPU utilization or AX/native responsiveness',
                     'samples': list(self.samples)}
            self.receipt.write_text(json.dumps(value, indent=2))
        except Exception: pass
        return False


if __name__ == '__main__':
    import sys
    if len(sys.argv) != 3: raise SystemExit('Expected runner-owned Simulator UUID and result directory')
    collect_owned_trace(sys.argv[1], Path(sys.argv[2]))
