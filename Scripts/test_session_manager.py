#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-only
import json,os,pathlib,subprocess,sys,tempfile
from swift_probe_support import prepare_core
ROOT=pathlib.Path(__file__).resolve().parents[1]
products,module_dir,archive=prepare_core()
subprocess.run(['sh',str(ROOT/'Scripts/build_session_host.sh')],check=True)
command=['swiftc','-swift-version','5','-parse-as-library','-I',str(module_dir),str(ROOT/'Sources/M1Launcher/SessionManager.swift'),str(ROOT/'Synthetic/ReadySessionManagerProbe.swift')]
command += [str(archive)]
command += ['-framework','AppKit','-o',str(ROOT/'Build/ReadySessionManagerProbe')]
subprocess.run(command,cwd=ROOT,check=True)
with tempfile.TemporaryDirectory(prefix='ready-manager-integration-') as temp:
    env={**os.environ,**{key:'ready-ambient-test-value' for key in (
        'WINEPREFIX','WINEDLLPATH','WINEDLLOVERRIDES','VK_DRIVER_FILES','VK_ICD_FILENAMES',
        'READY_UNUSED_AMBIENT','M1L_UNUSED_AMBIENT','DYLD_FRAMEWORK_PATH')}}
    run=subprocess.run([str(ROOT/'Build/ReadySessionManagerProbe'),temp,str(ROOT/'Build/ReadySessionHost'),sys.executable],cwd=ROOT,capture_output=True,text=True,timeout=45,env=env)
    (ROOT/'Evidence/session-host-manager.log').write_text(run.stdout+'\n'+run.stderr)
    assert run.returncode==0,run.stderr+'\n'+run.stdout
    report=json.loads(run.stdout);assert report['passed']
    (ROOT/'Evidence/session-host-manager.json').write_text(json.dumps(report,indent=2)+'\n')
    print(json.dumps(report,indent=2))
