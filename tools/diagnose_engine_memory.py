#!/usr/bin/env python3
"""Explicit live playback/memory probe; uses Tops session, outputs totals only."""
import asyncio
import json
import os
from pathlib import Path
import subprocess
import sys
import time

from profile_memory import measure
from test_live_playback import Engine, ROOT, CheckFailed, report, validate


async def snapshot(engine, label):
    row = [str(engine.process.pid), '0', '0', 'tops-engine']
    result = await asyncio.to_thread(measure, row)
    report(label, footprint_mib=result['footprint_mib'])


async def main():
    if sys.argv[1:] != ['--playback']:
        raise CheckFailed('Pass --playback to permit this live test')
    existing = subprocess.run(['pgrep', '-x', 'tops-engine'], capture_output=True)
    if existing.returncode != 1:
        raise CheckFailed('Close Tops before measuring its helper')
    env = os.environ | {'TOKIO_WORKER_THREADS': '2'}
    process = await asyncio.create_subprocess_exec(
        str(ROOT / 'engine/target/release/tops-engine'), '--data-dir',
        str(Path.home() / 'Library/Application Support/Tops/session'),
        env=env, stdin=asyncio.subprocess.PIPE, stdout=asyncio.subprocess.PIPE,
        stderr=asyncio.subprocess.DEVNULL, limit=2_000_000)
    engine = Engine(process)
    try:
        await engine.call('authenticate', timeout=45)
        await snapshot(engine, 'authenticated_before_trim')
        result = await engine.call('trimMemory')
        report('trimmed', released_mib=round(result['released_bytes'] / 1048576, 2))
        await snapshot(engine, 'authenticated_after_trim')
        manifest = json.loads((ROOT / 'config/operations.json').read_text())
        await asyncio.wait_for(validate(engine, manifest['operations']['searchDesktop']['hash']), 150)
        await snapshot(engine, 'playing')
        await engine.call('pause')
        await engine.until(lambda: engine.playback.get('is_playing') is False, 5, 'Pause unconfirmed')
        await snapshot(engine, 'paused_before_trim')
        result = await engine.call('trimMemory')
        report('trimmed', released_mib=round(result['released_bytes'] / 1048576, 2))
        await snapshot(engine, 'paused_after_trim')
    finally:
        await engine.close()


if __name__ == '__main__':
    try:
        asyncio.run(main())
    except CheckFailed as error:
        report('failed', reason=str(error))
        sys.exit(1)
    except BaseException:
        report('failed', reason='Diagnostic stopped; raw exceptions suppressed')
        sys.exit(1)
