#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-only
"""Build an ARM64 owned host; does not load Steam, credentials or a game."""
import argparse,hashlib,json,os,subprocess,tempfile
from pathlib import Path
ROOT=Path(__file__).resolve().parents[1]
SOURCES=['steam_native_host_session.c','steam_native_host_session.h','steam_native_host_probe.c','steam_host_credential.h','steam_native_discovery.h']
def sha(p):return hashlib.sha256(Path(p).read_bytes()).hexdigest()
def build(output):
    output=Path(output);output.parent.mkdir(parents=True,exist_ok=True)
    before={s:sha(ROOT/'Scripts'/s)for s in SOURCES}
    if output.exists()or output.is_symlink():raise ValueError('Output already exists; immutable candidates are never overwritten')
    command=['/usr/bin/clang','-arch','arm64','-std=c11','-O2','-Wall','-Wextra','-Wno-deprecated-declarations','-Wno-unused-function',str(ROOT/'Scripts/steam_native_host_session.c'),'-o',str(output),'-pthread']
    try:
        subprocess.run(command,check=True,capture_output=True,text=True)
        subprocess.run(['/usr/bin/codesign','--force','--sign','-',str(output)],check=True,capture_output=True)
        if before!={s:sha(ROOT/'Scripts'/s)for s in SOURCES}:raise ValueError('Source changed during build')
        source_dir=output.parent/(output.name+'-sources');source_dir.mkdir(mode=0o700)
        for s in SOURCES:(source_dir/s).write_bytes((ROOT/'Scripts'/s).read_bytes())
        receipt={'schema':1,'kind':'steam-native-host-session-build','fixtureOnly':False,'architecture':'arm64','sourceHashes':before,'binarySHA256':sha(output),'command':command,'genuineAccountOrSDKExecuted':False,'license':'GPL-3.0-only','externalClientDistributionApproved':False}
        path=output.with_suffix(output.suffix+'.json');path.write_text(json.dumps(receipt,indent=2)+'\n');path.chmod(0o600)
        return {'binary':str(output),'binarySHA256':receipt['binarySHA256'],'receipt':str(path),'receiptSHA256':sha(path)}
    except BaseException:
        # Preserve failed outputs for inspection; do not select/publish anything.
        raise
if __name__=='__main__':
    p=argparse.ArgumentParser(description=__doc__);p.add_argument('--output',type=Path,required=True);a=p.parse_args();print(json.dumps(build(a.output)))
