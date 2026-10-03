#!/usr/bin/env python3
"""Overlap independent build/package phases after generation/static validation."""
import argparse
import json
from pathlib import Path
import signal
import subprocess
import time

from xcode_progress_watchdog import stop

ROOT=Path(__file__).resolve().parent.parent


def run_phases(commands, results):
    children={}; logs={}; started=time.monotonic()
    try:
        for name, command in commands.items():
            logs[name]=(results/f'{name}.log').open('wb')
            children[name]=subprocess.Popen(command,cwd=ROOT,stdout=logs[name],stderr=subprocess.STDOUT,start_new_session=True)
        while any(child.poll() is None for child in children.values()): time.sleep(.1)
        statuses={name:child.returncode for name,child in children.items()}
        (results/'phases.json').write_text(json.dumps({'exit_codes':statuses,'elapsed_seconds':round(time.monotonic()-started,2)},indent=2)+'\n')
        return statuses
    finally:
        for child in children.values():
            if child.poll() is None: stop(child)
        for handle in logs.values(): handle.close()


def main():
    parser=argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--destination',required=True)
    parser.add_argument('--results',type=Path,required=True)
    args=parser.parse_args()
    commands={
        'build':['xcodebuild','-project','HermesFleetApp.xcodeproj','-scheme','HermesFleetApp','-destination',args.destination,'-derivedDataPath','build/DevCheck','-skipMacroValidation','build'],
        'packages':['bash','scripts/c1_packages.sh'],
    }
    def interrupted(_signal,_frame): raise KeyboardInterrupt
    signal.signal(signal.SIGTERM,interrupted)
    try: return int(any(code!=0 for code in run_phases(commands,args.results).values()))
    except KeyboardInterrupt: return 130


if __name__=='__main__': raise SystemExit(main())
