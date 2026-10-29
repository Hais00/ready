#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-only
"""Compile production auth methods verbatim with real offscreen page presenters.

No SwiftPM, real store client, browser, account, network or Keychain calls.
"""
import hashlib,json,os,pathlib,subprocess,tempfile
ROOT=pathlib.Path(__file__).resolve().parents[1]
WORK=pathlib.Path('/Volumes/Dati APFS/Codex-ready-01a17e79')
def sha(path):return hashlib.sha256(path.read_bytes()).hexdigest()
def main():
 run=pathlib.Path(tempfile.mkdtemp(prefix='store-authentication-pages-',dir=WORK/'tests'));run.chmod(0o700)
 main_source=(ROOT/'Sources/M1Launcher/main.swift').read_text()
 auth=main_source[main_source.index('  private func cancelStoreAuthentication('):main_source.index('  func syncStore(')]
 cancel=main_source[main_source.index('  func cancelAuthentication('):main_source.index('  func applicationShouldTerminate(')]
 fixture=ROOT/'Synthetic/ReadyStoreAuthenticationPagesProbe.swift';generated=run/'ProductionAuthProbe.swift'
 generated.write_text(fixture.read_text().replace('  // PRODUCTION_AUTH_METHODS',cancel+auth))
 sources=[ROOT/'Sources/M1Launcher/ReadyPagePresenter.swift',ROOT/'Sources/M1Launcher/ReadyDialogs.swift',generated]
 env={k:v for k,v in os.environ.items()if not k.startswith(('READY_','DYLD_','Steam','STEAM'))};env['TMPDIR']=str(WORK/'tmp')+'/'
 binary=run/'probe';result=subprocess.run(['xcrun','swiftc','-swift-version','5','-parse-as-library','-module-cache-path',str(WORK/'cache/swift-ready-auth-pages'),*map(str,sources),'-framework','AppKit','-framework','CoreImage','-o',str(binary)],env=env,capture_output=True,text=True,timeout=90)
 (run/'build.log').write_text(result.stdout+result.stderr)
 if result.returncode:raise RuntimeError('Auth page fixture compilation failed: '+result.stderr[-6000:])
 report=run/'report.json';result=subprocess.run(['/usr/bin/sandbox-exec','-p','(version 1)(allow default)(deny network*)',str(binary),str(report)],env=env,capture_output=True,text=True,timeout=45)
 (run/'stdout.log').write_text(result.stdout);(run/'stderr.log').write_text(result.stderr)
 if result.returncode or not report.exists():raise RuntimeError('Offscreen auth page fixture failed: '+result.stderr[-5000:]+' Retained '+str(run))
 data=json.loads(report.read_text());assert data['passed']
 current=(ROOT/'Sources/M1Launcher/main.swift').read_text();assert auth==current[current.index('  private func cancelStoreAuthentication('):current.index('  func syncStore(')]
 data.update(authRegionSHA256=hashlib.sha256(auth.encode()).hexdigest(),cancellationRegionSHA256=hashlib.sha256(cancel.encode()).hexdigest(),fixtureSHA256=sha(fixture),productionPresenters={str(p.relative_to(ROOT)):sha(p)for p in sources[:2]},retainedRoot=str(run))
 report.write_text(json.dumps(data,indent=2)+'\n');report.chmod(0o600)
 print(json.dumps({'passed':True,'count':data['count'],'report':str(report),'authRegionSHA256':data['authRegionSHA256']},indent=2))
if __name__=='__main__':main()
