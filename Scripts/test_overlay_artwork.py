#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-only
"""Real cache + canvas reopen; generated card images, no account or user game."""
import hashlib,json,os,pathlib,subprocess,tempfile
from swift_probe_support import prepare_core
from test_ready_canvas_sections import SOURCES as CANVAS_SOURCES
ROOT=pathlib.Path(__file__).resolve().parents[1];WORK=pathlib.Path('/Volumes/Dati APFS/Codex-ready-01a17e79')
def sha(p):return hashlib.sha256(p.read_bytes()).hexdigest()
def main():
 run=pathlib.Path(tempfile.mkdtemp(prefix='overlay-artwork-',dir=WORK/'tests'));run.chmod(0o700)
 names=[x for x in CANVAS_SOURCES if not x.startswith('Synthetic/')]+['Synthetic/ReadyOverlayArtworkProbe.swift'];before={n:sha(ROOT/n)for n in names}
 os.environ.update(TMPDIR=str(WORK/'tmp')+'/',CLANG_MODULE_CACHE_PATH=str(WORK/'cache/overlay-artwork'))
 products,modules,archive=prepare_core()
 command=['xcrun','swiftc','-swift-version','5','-parse-as-library','-module-cache-path',str(WORK/'cache/overlay-artwork'),'-I',str(modules),*[str(ROOT/n)for n in names],str(archive),'-framework','AppKit','-framework','Metal','-framework','QuartzCore','-o',str(run/'probe')]
 p=subprocess.run(command,cwd=ROOT,capture_output=True,text=True,timeout=120);(run/'build.log').write_text(p.stdout+p.stderr)
 if p.returncode:raise RuntimeError(str(run)+'\n'+p.stderr[-3000:])
 p=subprocess.run([str(run/'probe'),str(run)],cwd=ROOT,capture_output=True,text=True,timeout=40);(run/'output.log').write_text(p.stdout+p.stderr)
 if p.returncode:raise RuntimeError(str(run)+'\n'+p.stdout[-3000:]+p.stderr[-1000:])
 report=json.loads(p.stdout);assert report['passed']and before=={n:sha(ROOT/n)for n in names};report['sourceSHA256']=before
 output=run/'report.json';output.write_text(json.dumps(report,indent=2)+'\n');print(json.dumps({'passed':True,'checks':report['count'],'report':str(output),'reportSHA256':sha(output)}))
if __name__=='__main__':main()
