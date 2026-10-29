#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-only
"""Real filesystem/own SIGKILL writer tests; no user cache or network."""
import argparse,hashlib,json,os,pathlib,subprocess,tempfile
ROOT=pathlib.Path(__file__).resolve().parents[1];WORK=pathlib.Path('/Volumes/Dati APFS/Codex-ready-01a17e79')
def sha(p):return hashlib.sha256(p.read_bytes()).hexdigest()
def main():
 ap=argparse.ArgumentParser();ap.add_argument('--core-products',type=pathlib.Path,required=True);a=ap.parse_args();core=a.core_products.resolve();archive=core/'libLauncherCore.a';module=core/'LauncherCore.swiftmodule';assert archive.is_file()and module.is_file()
 run=pathlib.Path(tempfile.mkdtemp(prefix='artwork-durability-',dir=WORK/'tests'));run.chmod(0o700);sources=[ROOT/'Sources/M1Launcher/ArtworkIndexStore.swift',ROOT/'Sources/M1Launcher/GameArtwork.swift',ROOT/'Synthetic/ReadyArtworkDurabilityProbe.swift',pathlib.Path(__file__)];hashes={str(p.relative_to(ROOT)):sha(p)for p in sources};env={**os.environ,'TMPDIR':str(WORK/'tmp')+'/'}
 cmd=['xcrun','swiftc','-swift-version','5','-parse-as-library','-module-cache-path',str(WORK/'cache/artwork-index-module-cache'),'-I',str(core),*map(str,sources[:3]),str(archive),'-framework','AppKit','-o',str(run/'probe')];p=subprocess.run(cmd,env=env,capture_output=True,text=True,timeout=120);(run/'compile.log').write_text(p.stdout+p.stderr)
 if p.returncode:raise RuntimeError('Durability fixture compile failed: '+p.stderr[-2400:])
 p=subprocess.run([str(run/'probe'),str(run)],env=env,capture_output=True,text=True,timeout=35);(run/'stdout.json').write_text(p.stdout);(run/'stderr.log').write_text(p.stderr)
 if p.returncode:raise RuntimeError('Durability fixture failed; own diagnostics '+str(run))
 report=json.loads(p.stdout);assert report['passed'];assert hashes=={str(p.relative_to(ROOT)):sha(p)for p in sources};report['sourceHashes']=hashes;raw=run/'report.json';raw.write_text(json.dumps(report,indent=2)+'\n');raw.chmod(0o600);pointer={**report,'retainedReport':str(raw),'retainedReportSHA256':sha(raw)};(ROOT/'Evidence/artwork-durability-tests.json').write_text(json.dumps(pointer,indent=2)+'\n');print(json.dumps(pointer,indent=2))
if __name__=='__main__':main()
