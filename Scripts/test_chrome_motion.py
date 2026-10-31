#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-only
"""Production UI shader + cached texture motion; owned offscreen color regions."""
import pathlib,hashlib,json,os,subprocess,tempfile
ROOT=pathlib.Path(__file__).resolve().parents[1];WORK=pathlib.Path('/Volumes/Dati APFS/Codex-ready-01a17e79')
def sha(p):return hashlib.sha256(p.read_bytes()).hexdigest()
def main():
 run=pathlib.Path(tempfile.mkdtemp(prefix='chrome-motion-',dir=WORK/'tests'));run.chmod(0o700)
 files=[ROOT/'Sources/M1Launcher/CanvasDrawing.swift',ROOT/'Sources/M1Launcher/CanvasShellRenderer.swift',ROOT/'Synthetic/ReadyChromeMotionProbe.swift'];before={str(p.relative_to(ROOT)):sha(p)for p in files}
 env={**os.environ,'TMPDIR':str(WORK/'tmp')+'/','CLANG_MODULE_CACHE_PATH':str(WORK/'cache/chrome-motion')}
 p=subprocess.run(['xcrun','swiftc','-swift-version','5','-parse-as-library',*map(str,files),'-framework','AppKit','-framework','Metal','-framework','QuartzCore','-o',str(run/'probe')],env=env,capture_output=True,text=True,timeout=90);(run/'build.log').write_text(p.stdout+p.stderr)
 if p.returncode:raise RuntimeError(str(run)+'\n'+p.stderr[-3500:])
 p=subprocess.run([str(run/'probe')],env=env,capture_output=True,text=True,timeout=20);(run/'output.log').write_text(p.stdout+p.stderr)
 if p.returncode:raise RuntimeError(str(run)+'\n'+p.stdout[-2500:]+p.stderr[-1000:])
 r=json.loads(p.stdout);assert r['passed']and before=={str(p.relative_to(ROOT)):sha(p)for p in files};r['sourceSHA256']=before
 out=run/'report.json';out.write_text(json.dumps(r,indent=2)+'\n');print(json.dumps({'passed':True,'checks':r['count'],'report':str(out),'reportSHA256':sha(out)}))
if __name__=='__main__':main()
