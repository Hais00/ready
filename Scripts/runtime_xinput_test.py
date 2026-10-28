#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-only
"""Deterministic real PE XInput tests; RAW device and overlay status are test-only."""
import argparse
import json
import hashlib
import os
from pathlib import Path
import select
import shutil
import subprocess
import time
import uuid

ROOT=Path(__file__).resolve().parents[1]
OUTPUT=ROOT/'Runtime/XInputDiagnostic'

def compile_tests():
    sdk=ROOT/'Runtime/wine-11.20/include/wine/windows';crt=ROOT/'Vendor/wine/include/msvcrt';cc='/opt/homebrew/opt/llvm/bin/clang';dt='/opt/homebrew/opt/llvm/bin/llvm-dlltool';link='/opt/homebrew/opt/lld/bin/lld-link'
    for arch,machine,target in [('x86_64','x64','x86_64-windows'),('i386','x86','i686-windows')]:
        definition=OUTPUT/(arch+'-kernel.def');names={'AcquireSRWLockExclusive':4,'ReleaseSRWLockExclusive':4,'AcquireSRWLockShared':4,'ReleaseSRWLockShared':4,'GetEnvironmentVariableW':12,'LoadLibraryW':4,'GetProcAddress':8,'GetStdHandle':4,'WriteFile':20,'ReadFile':20,'ExitProcess':4};definition.write_text('LIBRARY KERNEL32.dll\nEXPORTS\n'+'\n'.join(n+'@'+str(b) if machine=='x86' else n for n,b in names.items())+'\n');lib=OUTPUT/(arch+'-kernel.lib');subprocess.run([dt,'-m','i386' if machine=='x86' else 'i386:x86-64','--kill-at','-d',str(definition),'-l',str(lib)],check=True)
        flags=[cc,'--target='+target,'--no-default-config','-ffreestanding','-fno-builtin','-fshort-wchar','-O2','-I'+str(sdk),'-I'+str(crt),'-I'+str(ROOT/'Scripts')]
        for name in ['test_device','probe']:
            obj=OUTPUT/(arch+'-'+name+'.obj');subprocess.run([*flags,'-c',str(ROOT/'Scripts'/('runtime_xinput_'+name+'.c')),'-o',str(obj)],check=True);args=[link,'/timestamp:0','/nodefaultlib','/machine:'+machine,'/safeseh:no',str(obj),str(lib)]
            if name=='test_device':
                exports={'ReadyTestSeed':12,'ReadyTestGetState':8,'ReadyTestSetState':8,'ReadyTestStats':8};definition=OUTPUT/(arch+'-device.def');definition.write_text('EXPORTS\n'+'\n'.join(n+'=_'+n+'@'+str(b) if machine=='x86' else n for n,b in exports.items())+'\n');args+=['/dll','/entry:DllMain','/def:'+str(definition),'/out:'+str(OUTPUT/(arch+'-ready-test-device.dll'))]
            else:args+=['/entry:mainCRTStartup','/subsystem:console','/out:'+str(OUTPUT/(arch+'-xinput-probe.exe'))]
            subprocess.run(args,check=True)

def atomic(path,data,mode=0o600):
    temporary=path.with_name(path.name+'.'+uuid.uuid4().hex);temporary.write_text(json.dumps(data));temporary.chmod(mode);os.replace(temporary,path)

class Session:
    def __init__(self,root,wine,arch,version,template=None,extra_env=None,executable=None):
        self.root=root;self.wine=wine;self.control=root/'control.json';self.status=root/'overlay-status.json';self.sequence=1;self.visible=False;self.epoch=0;self.pid=0;self.prefix=root/'prefix';root.mkdir(parents=True,exist_ok=True)
        if template:subprocess.run(['/bin/cp','-cR',str(template),str(self.prefix)],check=True)
        else:wow=self.prefix/'drive_c/windows/syswow64';wow.mkdir(parents=True);subprocess.run(['/bin/cp','-cR',str(wine/'lib/wine/i386-windows')+'/.',str(wow)],check=True)
        env={k:v for k,v in os.environ.items() if not k.startswith(('WINE','DYLD_','READY_','M1L_'))};cfg=json.loads((ROOT/'Runtime/runtime.json').read_text());base=Path(cfg['immutableRuntimeSet']);env.update(WINEPREFIX=str(self.prefix),WINEDEBUG='+loaddll',DYLD_PRINT_LIBRARIES='1',DYLD_LIBRARY_PATH=str(base/'vulkan')+':'+str(base/'dependencies'),WINEDLLOVERRIDES='mscoree,mshtml=d;xinput1_1,xinput1_2,xinput1_3,xinput1_4,xinput9_1_0=b');self.env=env
        self.log=(root/'wine.log').open('wb')
        if not template:
            boot=subprocess.run([str(wine/'bin/wine'),'wineboot','-u'],env=env,stdout=self.log,stderr=self.log,timeout=180);subprocess.run([str(wine/'bin/wineserver'),'-k'],env=env,capture_output=True,timeout=10)
            if boot.returncode:raise RuntimeError('Synthetic Wine bootstrap failed')
        atomic(self.control,{'sequence':self.sequence,'visible':False,'selection':0});env.update(extra_env or {});env.update(M1L_CONTROL_FILE=str(self.control),M1L_OVERLAY_STATUS=str(self.status),M1L_XINPUT_TEST_VERSION=version+'.dll',M1L_XINPUT_TEST_PROVIDER='Z:'+str(OUTPUT/(arch+'-ready-test-device.dll')).replace('/','\\'))
        self.process=subprocess.Popen([str(wine/'bin/wine'),str(executable or OUTPUT/(arch+'-xinput-probe.exe'))],env=env,stdin=subprocess.PIPE,stdout=subprocess.PIPE,stderr=self.log,text=True,bufsize=1);self.info=self.read();self.pid=self.info.get('nativePid',0)
        if not self.pid:
            self.close();raise RuntimeError('Test Unix bridge did not report the native process ID: '+str(self.info))
    def read(self):
        if not select.select([self.process.stdout],[],[],15)[0]:raise TimeoutError('Windows XInput probe response timeout')
        line=self.process.stdout.readline()
        if not line:raise RuntimeError('Windows probe exited before its API observation')
        result=json.loads(line)
        if 'error' in result:raise RuntimeError(str(result))
        return result
    def command(self,text):self.process.stdin.write(text+'\n');self.process.stdin.flush();return self.read()
    def update(self,visible,supported=True,pid=None,age=0,command_visible=None):
        self.sequence+=1
        if visible and not self.visible:self.epoch+=1
        self.visible=visible;atomic(self.control,{'sequence':self.sequence,'visible':visible if command_visible is None else command_visible,'selection':0});atomic(self.status,{'schema':1,'pid':self.pid if pid is None else pid,'visible':visible,'controlSequence':self.sequence,'frameCount':20,'injectionSupported':supported,'metal3Hooked':supported,'metal4Hooked':False,'heartbeatActive':True,'heartbeatSequence':50,'inputCaptureEpoch':self.epoch})
        if age:stamp=time.time()-age;os.utime(self.status,(stamp,stamp))
        time.sleep(.035)
    def close(self):
        if hasattr(self,'process'):
            if self.process.poll() is None:
                try:self.process.stdin.write('exit\n');self.process.stdin.flush();self.process.wait(timeout=10)
                except Exception:pass
        subprocess.run([str(self.wine/'bin/wineserver'),'-k'],env=self.env,capture_output=True,timeout=10);self.log.close()

def stage_wine(root):
    cfg=json.loads((ROOT/'Runtime/runtime.json').read_text());source=Path(cfg['immutableRuntimeSet'])/'wine';wine=root/'wine';subprocess.run(['/bin/cp','-cR',str(source),str(wine)],check=True)
    for arch in ['x86_64','i386']:
        for source in (OUTPUT/'test'/(arch+'-windows')).glob('*.dll'):shutil.copy2(source,wine/'lib/wine'/(arch+'-windows')/source.name)
    directory=wine/'lib/wine/x86_64-unix'
    for source in (OUTPUT/'test/x86_64-unix').iterdir():
        target=directory/source.name;target.unlink(missing_ok=True)
        if source.is_symlink():target.symlink_to(os.readlink(source))
        else:shutil.copy2(source,target)
    return wine

def digest(path):return hashlib.sha256(Path(path).read_bytes()).hexdigest()

def main():
    parser=argparse.ArgumentParser(description=__doc__);parser.add_argument('--template',type=Path);args=parser.parse_args()
    if args.template:assert args.template.parent.parent.name.startswith('xinput-real-overlay-') and (args.template.parent.parent/'.ready-xinput-test').is_file()
    default_paths=[ROOT/'Runtime/runtime.json',ROOT/'Runtime/evaluation-runtime.json'];before={str(p):digest(p) for p in default_paths}
    compile_tests();parent=ROOT/'Runtime/TestPrefixes';root=parent/('xinput-capture-'+uuid.uuid4().hex);root.mkdir();(root/'.ready-xinput-test').write_text('Only deterministic synthetic controller tests\n');wine=stage_wine(root);sessions=[];report={'testDeviceProviderOnly':True,'physicalControllerVerified':False,'defaultRuntimeModified':False,'defaultConfigHashesBefore':before,'buildEvidenceSHA256':digest(ROOT/'Evidence/runtime-xinput-build.json'),'sourceInputs':{str(p.relative_to(ROOT)):digest(p) for p in [Path(__file__),ROOT/'Scripts/runtime_xinput_probe.c',ROOT/'Scripts/runtime_xinput_test_device.c']},'testBinaryHashes':{str(p.relative_to(ROOT)):digest(p) for p in OUTPUT.glob('*') if p.is_file() and p.suffix in ['.exe','.dll']},'cases':[],'passed':False}
    try:
        template=args.template
        versions=['xinput1_1','xinput1_2','xinput1_3','xinput1_4','xinput9_1_0']
        for arch in ['x86_64','i386']:
            for version in versions:
                session=Session(root/arch/version,wine,arch,version,template);sessions.append(session)
                session.command('seed-a');raw=session.command('sample');has_key=raw['keystrokeResult']!=50
                assert raw['buttons']&0x1010==0x1010 and raw['active']==0
                session.update(False);hidden=session.command('sample');assert hidden['active']==1 and hidden['buttons']&0x1000 and not hidden['buttons']&0x10
                session.update(True);shown=session.command('rumble');assert shown['buttons']==shown['leftTrigger']==shown['leftX']==0 and shown['extendedButtons']==0 and shown['keystrokeResult'] in [4306,50] and shown['leftMotor']==shown['rightMotor']==0 and shown['rawButtons']&0x1000
                assert shown['packet']!=hidden['packet']
                session.update(False);held=session.command('sample');assert held['buttons']==0 and held['keystrokeResult'] in [4306,50]
                session.command('seed-neutral');released=session.command('sample');assert released['buttons']==0 and released['keystrokeResult'] in [4306,50]
                session.command('seed-b');fresh=session.command('sample');assert fresh['buttons']==0x2000 and fresh['keystrokeResult']==(0 if has_key else 50)
                # Local GC visibility may differ from the latest acknowledged parent command.
                session.command('seed-a');session.update(True,command_visible=False);local=session.command('sample');assert local['buttons']==0 and local['visible']==1
                session.update(False);session.command('seed-neutral');session.command('sample')
                # A complete open/close without any game API poll still disarms held resume input.
                session.command('seed-a');session.update(True);session.update(False);unpolled=session.command('sample');assert unpolled['buttons']==0 and unpolled['keystrokeResult'] in [4306,50]
                session.command('seed-neutral');session.command('sample');session.command('seed-b');assert session.command('sample')['buttons']==0x2000
                if has_key:
                    session.command('seed-neutral');session.command('key-only');session.command('seed-a');session.update(True);assert session.command('key-only')['keystrokeResult']==4306
                    session.update(False);assert session.command('key-only')['keystrokeResult']==4306
                    session.command('seed-neutral');assert session.command('key-only')['keystrokeResult']==4306
                    session.command('seed-b');assert session.command('key-only')['keystrokeResult']==0
                session.command('seed-a');session.update(False,supported=False);unsupported=session.command('rumble');assert unsupported['active']==0 and unsupported['buttons']&0x10 and unsupported['leftMotor']==77
                session.update(True,age=10);stale=session.command('sample');assert stale['active']==0 and stale['buttons']&0x10
                session.update(True,pid=session.pid+10000);foreign=session.command('sample');assert foreign['active']==0 and foreign['buttons']&0x10
                negatives={}
                if version=='xinput1_4':
                    for invalid in ['missing','public-mode','symlink','malformed','duplicate-key','oversized','no-heartbeat','invalid-heartbeat','zero-frames','missing-control']:
                        session.update(False)
                        if invalid=='missing':session.status.unlink()
                        elif invalid=='public-mode':session.status.chmod(0o644)
                        elif invalid=='symlink':
                            saved=session.root/'saved-status.json';shutil.copy2(session.status,saved);session.status.unlink();session.status.symlink_to(saved)
                        elif invalid=='malformed':session.status.write_text('{broken')
                        elif invalid=='duplicate-key':session.status.write_text(session.status.read_text()[:-1]+',"heartbeatActive":true}')
                        elif invalid=='oversized':session.status.write_text(' '*16385)
                        elif invalid=='no-heartbeat':
                            status=json.loads(session.status.read_text());status['heartbeatActive']=False;atomic(session.status,status)
                        elif invalid=='invalid-heartbeat':
                            status=json.loads(session.status.read_text());status['heartbeatActive']=2;atomic(session.status,status)
                        elif invalid=='zero-frames':
                            status=json.loads(session.status.read_text());status['frameCount']=0;atomic(session.status,status)
                        elif invalid=='missing-control':session.control.unlink()
                        value=session.command('sample');assert value['active']==0 and value['buttons']&0x10,(invalid,value);negatives[invalid]=True
                        if session.status.is_symlink():session.status.unlink()
                    session.update(False);atomic(session.control,{'sequence':session.sequence+1,'visible':True});newer_show=session.command('sample');assert newer_show['active']==1 and newer_show['visible']==1 and newer_show['buttons']==0
                    session.update(True);atomic(session.control,{'sequence':session.sequence+1,'visible':False});newer_hide=session.command('sample');assert newer_hide['active']==1 and newer_hide['visible']==0 and newer_hide['buttons']==0
                    negatives['newer-command-show']=True;negatives['newer-command-hide']=True
                report['cases'].append({'architecture':arch,'version':version,'keystrokeExportPresent':has_key,'raw':raw,'hidden':hidden,'visible':shown,'heldAfterHide':held,'released':released,'newInput':fresh,'localGCVisibility':local,'unpolledOpenClose':unpolled,'unsupported':unsupported,'stale':stale,'wrongNativePid':foreign,'negativeProtocolCases':negatives,'passed':True})
                session.close();sessions.remove(session)
                evidence_log=ROOT/'Evidence'/('runtime-xinput-'+arch+'-'+version+'.log');shutil.copy2(session.root/'wine.log',evidence_log)
                native_loaded=str(wine/'lib/wine/x86_64-unix/xinput') in evidence_log.read_text(errors='replace')
                if not native_loaded:raise RuntimeError('Native XInput bridge provenance missing in dyld trace')
                report['cases'][-1]['moduleProvenance']={'log':str(evidence_log.relative_to(ROOT)),'sha256':digest(evidence_log),'nativeModuleTrace':True,'productionSeparatedFromTestBackend':True}
                if template is None:
                    template=root/'initialized-template';subprocess.run(['/bin/cp','-cR',str(session.prefix),str(template)],check=True)
                shutil.rmtree(session.prefix)
                print(arch,version,'PASS',flush=True)
        first=Session(root/'isolation-a',wine,'x86_64','xinput1_4',template);sessions.append(first)
        second=Session(root/'isolation-b',wine,'x86_64','xinput1_4',template);sessions.append(second)
        for value in [first,second]:value.command('seed-a')
        first.update(True);second.update(False);a=first.command('sample');b=second.command('sample');assert a['buttons']==0 and b['buttons']&0x1000
        second.update(True);assert first.command('sample')['buttons']==0 and second.command('sample')['buttons']==0
        first.update(False);first.command('seed-neutral');first.command('sample');first.command('seed-b');assert first.command('sample')['buttons']==0x2000 and second.command('sample')['buttons']==0
        report['twoSessionIsolation']={'separateControlNamespaces':True,'differentNativePids':first.pid!=second.pid,'first':a,'second':b,'passed':True}
        report['defaultConfigHashesAfter']={str(p):digest(p) for p in default_paths};assert before==report['defaultConfigHashesAfter']
        report['passed']=True;print(json.dumps(report,indent=2))
    finally:
        for session in sessions:session.close()
        (ROOT/'Evidence/runtime-xinput-capture.json').write_text(json.dumps(report,indent=2)+'\n')
        # Retain failed fixtures for diagnosis; successful fixtures contain no user data.
        if report['passed'] and (root/'.ready-xinput-test').is_file():shutil.rmtree(root)

if __name__=='__main__':main()
