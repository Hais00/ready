#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-only
"""Production NativeSession barrier/diagnostic with fake host, no SDK/account/game."""
import argparse,hashlib,json,os,pathlib,subprocess,tempfile
ROOT=pathlib.Path(__file__).resolve().parents[1]
WORK=pathlib.Path('/Volumes/Dati APFS/Codex-ready-01a17e79')
def sha(path):return hashlib.sha256(path.read_bytes()).hexdigest()
def main():
 parser=argparse.ArgumentParser();parser.add_argument('--core-products',type=pathlib.Path);args=parser.parse_args()
 run=pathlib.Path(tempfile.mkdtemp(prefix='native-session-barrier-',dir=WORK/'tests'));run.chmod(0o700)
 source=ROOT/'Sources/M1Launcher/SteamNativeGameSession.swift';fixture=ROOT/'Synthetic/ReadyNativeSessionBarrierProbe.swift';transport=ROOT/'Sources/M1Launcher/SteamSessionLeaseTransport.swift';before=sha(source)
 manager=(ROOT/'Sources/M1Launcher/SessionManager.swift').read_text();protocol=manager[manager.index('struct SteamKeeperHandoff'):manager.index('/// Main-queue lifecycle')]
 generated=run/'ProductionNativeSessionProbe.swift';generated.write_text('import Foundation\nimport LauncherCore\n'+protocol+'\n'+source.read_text()+'\n'+fixture.read_text())
 core=run/'core';core.mkdir(mode=0o700)
 env={k:v for k,v in os.environ.items()if not k.startswith(('READY_','DYLD_','Steam','STEAM'))};env['TMPDIR']=str(WORK/'tmp')+'/'
 common=['xcrun','swiftc','-swift-version','5','-parse-as-library','-module-cache-path',str(WORK/'cache/swift-native-session-barrier')]
 if args.core_products:
  products=args.core_products.resolve();modules=products if(products/'LauncherCore.swiftmodule').exists()else products/'Modules';archive=products/'libLauncherCore.a';module=modules/'LauncherCore.swiftmodule';items=list(module.glob('*.swiftmodule'))if module.is_dir()else[module]
  if not archive.is_file()or not items or archive.stat().st_mtime_ns<max(p.stat().st_mtime_ns for p in items):raise RuntimeError('Refusing stale static Core')
  commands=[[*common,'-I',str(modules),str(generated),str(transport),str(ROOT/'Sources/M1Launcher/SteamNativeCacheRevision.swift'),str(archive),'-framework','Security','-o',str(run/'probe')]]
 else:
  commands=[[*common,'-emit-library','-static','-emit-module','-module-name','LauncherCore','-emit-module-path',str(core/'LauncherCore.swiftmodule'),*map(str,sorted((ROOT/'Sources/LauncherCore').glob('*.swift'))),'-o',str(core/'libLauncherCore.a')],
   [*common,'-I',str(core),str(generated),str(transport),str(ROOT/'Sources/M1Launcher/SteamNativeCacheRevision.swift'),str(core/'libLauncherCore.a'),'-framework','Security','-o',str(run/'probe')]]
 for index,command in enumerate(commands):
  result=subprocess.run(command,env=env,capture_output=True,text=True,timeout=120);(run/f'build-{index}.log').write_text(result.stdout+result.stderr)
  if result.returncode:raise RuntimeError('Native barrier fixture compilation failed: '+result.stderr[-6500:])
 report=run/'report.json';result=subprocess.run(['/usr/bin/sandbox-exec','-p','(version 1)(allow default)(deny network*)',str(run/'probe'),str(report)],env=env,capture_output=True,text=True,timeout=30)
 (run/'stdout.log').write_text(result.stdout);(run/'stderr.log').write_text(result.stderr)
 if result.returncode:raise RuntimeError('Native barrier fixture failed: '+result.stderr[-5000:]+' Retained '+str(run))
 data=json.loads(report.read_text());assert data['passed']and before==sha(source)
 data.update(sourceSHA256=before,fixtureSHA256=sha(fixture),protocolSHA256=hashlib.sha256(protocol.encode()).hexdigest(),retainedRoot=str(run));report.write_text(json.dumps(data,indent=2)+'\n');report.chmod(0o600)
 print(json.dumps({'passed':True,'count':data['count'],'report':str(report),'sourceSHA256':before},indent=2))
if __name__=='__main__':main()
