"""Real app/worker tests: CSV stalls must not stall HTTP or CAN delivery."""
import subprocess
import sys
import unittest
from pathlib import Path


class RecordingRuntimeTests(unittest.TestCase):
    def test_lifespan_cancellation_waits_for_owned_recording_cleanup(self):
        script = r'''
import asyncio, sys, tempfile
from dataclasses import replace
from functools import partial
from pathlib import Path
import config
async def verify():
    with tempfile.TemporaryDirectory() as directory:
        config.settings=replace(config.settings,log_dir=Path(directory),ingest_token=None)
        import app as runtime
        command=[sys.executable,str(Path("tests/fixtures/csv_fault_worker.py").resolve()),"hang"]
        runtime.AsyncCsvRecorder=partial(runtime.AsyncCsvRecorder,worker_command=command)
        context=runtime.lifespan(runtime.app)
        await context.__aenter__()
        recorder=runtime.logger
        await asyncio.sleep(.15)
        closing=asyncio.create_task(context.__aexit__(None,None,None))
        await asyncio.sleep(.05)
        closing.cancel()
        try:
            try: await closing
            except asyncio.CancelledError: pass
            assert not recorder.snapshot()["worker_alive"], "Lifespan exited before recorder cleanup"
        finally:
            await recorder.close(timeout=.1)
asyncio.run(verify())
'''
        result = subprocess.run([sys.executable, "-B", "-c", script],
                                cwd=Path(__file__).resolve().parents[1], capture_output=True,
                                text=True, timeout=15)
        self.assertEqual(result.returncode, 0, result.stderr)

    def test_earlier_cleanup_cancellation_cannot_skip_worker_cleanup(self):
        script = r'''
import asyncio, tempfile
from dataclasses import replace
from pathlib import Path
from unittest.mock import patch
import config
class CancelClose:
    async def aclose(self): raise asyncio.CancelledError()
async def verify():
    with tempfile.TemporaryDirectory() as directory:
        config.settings=replace(config.settings,log_dir=Path(directory),ingest_token=None)
        import app as runtime
        with patch.object(runtime.httpx,"AsyncClient",return_value=CancelClose()):
            context=runtime.lifespan(runtime.app)
            await context.__aenter__()
            recorder=runtime.logger
            try:
                try: await context.__aexit__(None,None,None)
                except asyncio.CancelledError: pass
                assert not recorder.snapshot()["worker_alive"], "Recorder cleanup skipped after HTTP cancellation"
                assert runtime.recording_task is None
            finally:
                await recorder.close(timeout=.1)
                if runtime.recording_task:
                    runtime.recording_task.cancel()
                    await asyncio.gather(runtime.recording_task,return_exceptions=True)
asyncio.run(verify())
'''
        result = subprocess.run([sys.executable, "-B", "-c", script],
                                cwd=Path(__file__).resolve().parents[1], capture_output=True,
                                text=True, timeout=15)
        self.assertEqual(result.returncode, 0, result.stderr)

    def test_stalled_disk_preserves_live_can_and_recovers_all_accepted_samples(self):
        script = r'''
import csv, json, sys, tempfile, time
from dataclasses import replace
from functools import partial
from pathlib import Path
from fastapi.testclient import TestClient
import config

with tempfile.TemporaryDirectory() as directory:
    config.settings=replace(config.settings,log_dir=Path(directory),ingest_token=None)
    import app as runtime
    command=[sys.executable,str(Path("tests/fixtures/csv_fault_worker.py").resolve()),"gate"]
    runtime.AsyncCsvRecorder=partial(runtime.AsyncCsvRecorder,worker_command=command,lag_seconds=.05)
    with TestClient(runtime.app) as client:
        with client.websocket_connect("/ws") as ws:
            frames=[]
            controls=[]
            while len(frames)<4:
                message=ws.receive_json()
                if "sig" in message: frames.append(message)
                if message.get("type")=="recording_status": controls.append(message)
            started=time.monotonic()
            response=client.get("/api/ping")
            assert time.monotonic()-started < .3, "Disk stall blocked HTTP"
            assert response.status_code==503
            assert response.json()["error"]["code"]=="recording_delayed"
            assert response.json()["recording"]["written"]==0
            assert response.json()["recording"]["pending"]>=4
            assert frames[-1]["status"]["seq"]-frames[0]["status"]["seq"]==3
            assert .15 < frames[-1]["t"]-frames[0]["t"] < .7
            assert any(c["recording"]["state"]=="delayed" for c in controls)
            cutoff=frames[-1]["status"]["seq"]
            (Path(directory)/".release").touch()
            deadline=time.monotonic()+3
            while time.monotonic()<deadline:
                result=client.get("/api/ping")
                if result.status_code==200 and result.json()["recording"]["last_can_seq"]>=cutoff:
                    break
                time.sleep(.02)
            else: raise AssertionError("CSV backlog did not recover")
            path=runtime.logger.can_path
    assert runtime.app.state.recording_shutdown["worker_alive"] is False
    assert runtime.app.state.recording_shutdown["unconfirmed"]==0
    with path.open() as stream:
        seq=[int(row["seq"]) for row in csv.DictReader(stream)]
    assert seq==list(range(len(seq))) and seq[-1]>=cutoff
'''
        result = subprocess.run([sys.executable, "-B", "-c", script],
                                cwd=Path(__file__).resolve().parents[1], capture_output=True,
                                text=True, timeout=20)
        self.assertEqual(result.returncode, 0, result.stderr)

    def test_buffer_exhaustion_reports_rejection_and_reaps_hung_writer(self):
        script = r'''
import sys,tempfile,time
from dataclasses import replace
from functools import partial
from pathlib import Path
from fastapi.testclient import TestClient
import config
with tempfile.TemporaryDirectory() as directory:
    config.settings=replace(config.settings,log_dir=Path(directory),ingest_token=None)
    import app as runtime
    command=[sys.executable,str(Path("tests/fixtures/csv_fault_worker.py").resolve()),"hang"]
    runtime.AsyncCsvRecorder=partial(runtime.AsyncCsvRecorder,worker_command=command,capacity=2,lag_seconds=.05)
    with TestClient(runtime.app) as client:
        time.sleep(.35)
        response=client.get("/api/ping")
        assert response.status_code==503
        state=response.json()["recording"]
        assert state["state"]=="failed" and state["error"]=="queue_full"
        assert state["pending"]==2 and state["rejected"]==1
        assert runtime.stream_state["seq"]==2
    report=runtime.app.state.recording_shutdown
    assert report["worker_alive"] is False and report["unconfirmed"]==2
    assert report["forced"] is True and report["written"]==0
'''
        result = subprocess.run([sys.executable, "-B", "-c", script],
                                cwd=Path(__file__).resolve().parents[1], capture_output=True,
                                text=True, timeout=20)
        self.assertEqual(result.returncode, 0, result.stderr)


if __name__ == "__main__":
    unittest.main()
