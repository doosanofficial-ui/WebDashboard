"""Bounded, nonblocking request for early events of one newly created Simulator."""
import copy
import datetime
import json
import os
from pathlib import Path
import select
import signal
import subprocess
import threading
import time
import uuid


class OwnedSimulatorBootLog:
    def __init__(self, simulator, results, window=240, byte_limit=2 * 1024 * 1024):
        if not 0 < window <= 240 or not 0 < byte_limit <= 2 * 1024 * 1024:
            raise ValueError('Boot event collection cannot exceed 240 seconds or 2MiB')
        self.simulator = str(uuid.UUID(simulator)).upper()
        self.results = Path(results)
        self.stop = threading.Event()
        self.lock = threading.Lock()
        self.requested = time.monotonic()
        self.deadline = self.requested + window
        self.byte_limit = byte_limit
        self.state = {
            'simulator': self.simulator, 'requestedMonotonic': self.requested,
            'requestedUTC': datetime.datetime.now(datetime.timezone.utc).isoformat(),
            'windowSeconds': window, 'byteLimit': byte_limit, 'lineLimit': 65536,
            'launched': False, 'launchPending': False, 'inputBytes': 0, 'savedBytes': 0,
            'events': 0, 'discardedLines': 0, 'oversizedLines': 0, 'partialBytes': 0,
            'pipeClosed': True, 'leaderReaped': False, 'groupGoneFinal': None,
            'errors': [], 'scope': 'Early host events containing this created UUID only; request precedes boot, subscriber readiness is not guaranteed; 240s read window excludes process cleanup waits'
        }
        self.worker = threading.Thread(target=self._collect, name='owned-simulator-boot-log', daemon=True)
        self.worker.start()

    def _update(self, **values):
        with self.lock:
            self.state.update(values)

    def _error(self, operation, error):
        with self.lock:
            self.state['errors'].append({'operation': operation, 'type': type(error).__name__,
                                         'errno': getattr(error, 'errno', None)})

    def mark_boot_started(self):
        self._update(bootStartedMonotonic=time.monotonic())

    def request_stop(self):
        with self.lock:
            self.state.setdefault('stopRequestedMonotonic', time.monotonic())
        self.stop.set()

    def _group_exists(self, child):
        try:
            os.killpg(child.pid, 0)
            return True
        except ProcessLookupError:
            return False
        except OSError as error:
            self._error('group-probe', error)
            return None

    def _signal(self, child, value):
        try:
            os.killpg(child.pid, value)
            self._update(**{'groupTermSent' if value == signal.SIGTERM else 'groupKillSent': True})
        except ProcessLookupError:
            pass
        except OSError as error:
            self._error('group-signal', error)

    def _wait(self, child, operation):
        try:
            child.wait(timeout=10)
            self._update(leaderReaped=True, exitCode=child.returncode)
        except (OSError, subprocess.SubprocessError) as error:
            self._error(operation, error)

    def _close_child(self, child):
        # Always probe descendants; a reaped leader can leave its pipe/group alive.
        self._signal(child, signal.SIGTERM)
        self._wait(child, 'leader-wait')
        exists = self._group_exists(child)
        self._update(groupExistsAfterLeaderWait=exists)
        if exists is not False:
            self._signal(child, signal.SIGKILL)
        self._wait(child, 'final-reap')
        final = self._group_exists(child)
        self._update(groupGoneFinal=False if final is True else True if final is False else None)

    def _collect(self):
        child = None
        stream = None
        try:
            if self.stop.is_set() or time.monotonic() >= self.deadline:
                self._update(terminationReason='stopped-before-launch', groupGoneFinal=True)
                return
            command = ['/usr/bin/log', 'stream', '--style', 'ndjson', '--level', 'info',
                       '--timeout', '240', '--predicate', 'eventMessage CONTAINS[c] "' + self.simulator + '"']
            self._update(command=command, launchPending=True)
            child = subprocess.Popen(command, stdin=subprocess.DEVNULL, stdout=subprocess.PIPE,
                                     stderr=subprocess.DEVNULL, start_new_session=True)
            self._update(launchPending=False, launched=True, pid=child.pid, processGroup=child.pid,
                         spawnedMonotonic=time.monotonic(), pipeClosed=False)
            # Popen may return after a stop request. Never enter a fresh read window then.
            if self.stop.is_set() or time.monotonic() >= self.deadline:
                self._update(terminationReason='stopped-after-launch')
                return
            os.set_blocking(child.stdout.fileno(), False)
            stream = (self.results / 'simulator-boot-stream.ndjson').open('wb')
            pending = b''
            dropping_long_line = False
            total = saved = count = discarded = oversized = 0
            first_byte = None
            while not self.stop.is_set() and time.monotonic() < self.deadline and total < self.byte_limit:
                if not select.select([child.stdout], [], [], min(0.1, max(0, self.deadline - time.monotonic())))[0]:
                    continue
                try:
                    chunk = os.read(child.stdout.fileno(), min(65536, self.byte_limit - total))
                except BlockingIOError:
                    continue
                if not chunk:
                    self._update(terminationReason='eof')
                    break
                total += len(chunk)
                if first_byte is None:
                    first_byte = time.monotonic()
                pending += chunk
                while b'\n' in pending:
                    line, pending = pending.split(b'\n', 1)
                    if dropping_long_line:
                        dropping_long_line = False
                        continue
                    if len(line) > 65536:
                        oversized += 1
                        continue
                    try:
                        event = json.loads(line)
                    except (ValueError, UnicodeError):
                        discarded += 1
                        continue
                    message = event.get('eventMessage') if isinstance(event, dict) else None
                    if not isinstance(message, str) or self.simulator.lower() not in message.lower():
                        discarded += 1
                        continue
                    stream.write(line + b'\n')
                    stream.flush()
                    saved += len(line) + 1
                    count += 1
                if len(pending) > 65536:
                    pending = b''
                    if not dropping_long_line:
                        oversized += 1
                    dropping_long_line = True
                self._update(inputBytes=total, savedBytes=saved, events=count, discardedLines=discarded,
                             oversizedLines=oversized, firstByteMonotonic=first_byte)
            with self.lock:
                self.state.setdefault('terminationReason', 'stop-request' if self.stop.is_set() else
                                      'input-limit' if total >= self.byte_limit else 'deadline')
                self.state['partialBytes'] = len(pending)
        except Exception as error:
            self._error('collect', error)
            self._update(terminationReason='collector-error', launchPending=False)
        finally:
            if stream is not None:
                try:
                    stream.close()
                except OSError as error:
                    self._error('event-file-close', error)
            if child is not None:
                try:
                    child.stdout.close()
                    self._update(pipeClosed=True)
                except OSError as error:
                    self._error('pipe-close', error)
                # A TERM handler may write output: stop retaining an unread pipe before waiting.
                self._close_child(child)
            else:
                self._update(groupGoneFinal=True)
            self._update(finishedMonotonic=time.monotonic())

    def finalize(self, join_timeout=1):
        self.request_stop()
        self.worker.join(timeout=join_timeout)
        with self.lock:
            evidence = copy.deepcopy(self.state)
        evidence['workerStopped'] = not self.worker.is_alive()
        evidence['collectorCleaned'] = (evidence['workerStopped'] and not evidence['launchPending'] and
            evidence['pipeClosed'] and evidence['groupGoneFinal'] is True and
            (not evidence['launched'] or evidence['leaderReaped']))
        # Main is the receipt's sole writer. An unfinished worker cannot overwrite this snapshot.
        (self.results / 'simulator-boot-stream.json').write_text(json.dumps(evidence, indent=2), encoding='utf-8')
        return evidence
