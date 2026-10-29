#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-only
"""Real cache/index, fake HTTPS URLProtocol and own generated PNGs; no app activation."""
import argparse,hashlib,json,os,pathlib,subprocess,tempfile
ROOT=pathlib.Path(__file__).resolve().parents[1];WORK=pathlib.Path('/Volumes/Dati APFS/Codex-ready-01a17e79')
def sha(p):return hashlib.sha256(p.read_bytes()).hexdigest()
def main():
 ap=argparse.ArgumentParser();ap.add_argument('--core-products',required=True,type=pathlib.Path);a=ap.parse_args();products=a.core_products.resolve();modules=products if(products/'LauncherCore.swiftmodule').exists()else products/'Modules';archive=products/'libLauncherCore.a';m=modules/'LauncherCore.swiftmodule';ms=list(m.glob('*.swiftmodule'))if m.is_dir()else[m]
 if not archive.is_file()or not ms or archive.stat().st_mtime_ns<max(p.stat().st_mtime_ns for p in ms):raise ValueError('Matching fresh Core required')
 run=pathlib.Path(tempfile.mkdtemp(prefix='artwork-index-',dir=WORK/'tests'));run.chmod(0o700);sources=[ROOT/'Sources/M1Launcher'/n for n in ['ArtworkCache.swift','ArtworkIndexStore.swift','GameArtwork.swift']]+[ROOT/'Synthetic/ReadyArtworkIndexProbe.swift'];hashes={str(p.relative_to(ROOT)):sha(p)for p in sources};env={**os.environ,'TMPDIR':str(WORK/'tmp')+'/'}
 cmd=['xcrun','swiftc','-swift-version','5','-parse-as-library','-module-cache-path',str(WORK/'cache/artwork-index-module-cache'),'-I',str(modules),*map(str,sources),str(archive),'-framework','AppKit','-o',str(run/'probe')];p=subprocess.run(cmd,env=env,capture_output=True,text=True,timeout=120);(run/'compile.log').write_text(p.stdout+p.stderr)
 if p.returncode:raise RuntimeError('Artwork compile failed: '+p.stderr[-2600:])
 p=subprocess.run([str(run/'probe'),str(run)],env=env,capture_output=True,text=True,timeout=40);(run/'stdout.json').write_text(p.stdout);(run/'stderr.log').write_text(p.stderr)
 if p.returncode:raise RuntimeError('Artwork fixture failed; own diagnostics '+str(run))
 report=json.loads(p.stdout);assert report['passed'];assert hashes=={str(p.relative_to(ROOT)):sha(p)for p in sources};report['sourceHashes']=hashes;raw=run/'report.json';raw.write_text(json.dumps(report,indent=2)+'\n');raw.chmod(0o600);out={**report,'retainedReport':str(raw),'retainedReportSHA256':sha(raw)};(ROOT/'Evidence/artwork-index-tests.json').write_text(json.dumps(out,indent=2)+'\n');print(json.dumps(out,indent=2))
if __name__=='__main__':main()
