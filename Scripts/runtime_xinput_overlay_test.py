#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-only
"""Real Windows XInput -> session bridge -> injected Metal overlay status test.

Only the controller device is deterministic test scaffolding. Overlay status is
written by the actual native overlay inside the same presenting Windows process.
"""
import argparse,hashlib,json,os,shutil,subprocess,time,uuid
from pathlib import Path
from runtime_xinput_test import ROOT,OUTPUT,Session,atomic,compile_tests,stage_wine,digest

def compile_present():
    cc='/opt/homebrew/opt/llvm/bin/clang';dt='/opt/homebrew/opt/llvm/bin/llvm-dlltool';link='/opt/homebrew/opt/lld/bin/lld-link'
    libraries={
        'overlay-kernel':('KERNEL32.dll',['CreateThread']),
        'present-kernel':('KERNEL32.dll',['GetModuleHandleW','LoadLibraryA','GetProcAddress','ExitProcess']),
        'present-user':('USER32.dll',['RegisterClassW','CreateWindowExW','DefWindowProcW','ShowWindow','UpdateWindow','PeekMessageW','TranslateMessage','DispatchMessageW','DestroyWindow','PostQuitMessage','GetClientRect']),
        'present-crt':('msvcrt.dll',['printf','calloc','free','strcmp'])}
    for name,(dll,exports) in libraries.items():
        spec=OUTPUT/(name+'.def');spec.write_text('LIBRARY '+dll+'\nEXPORTS\n'+'\n'.join(exports)+'\n');subprocess.run([dt,'-m','i386:x86-64','-d',str(spec),'-l',str(OUTPUT/(name+'.lib'))],check=True)
    common=[cc,'--target=x86_64-windows','--no-default-config','-ffreestanding','-fno-builtin','-fshort-wchar','-O2','-I'+str(ROOT/'Scripts')]
    obj=OUTPUT/'overlay-probe.obj';subprocess.run([*common,'-I'+str(ROOT/'Runtime/wine-11.20/include/wine/windows'),'-I'+str(ROOT/'Vendor/wine/include/msvcrt'),'-c',str(ROOT/'Scripts/runtime_xinput_overlay_probe.c'),'-o',str(obj)],check=True)
    exe=OUTPUT/'xinput-overlay-probe.exe';subprocess.run([link,'/timestamp:0','/nodefaultlib','/entry:mainCRTStartup','/subsystem:console','/machine:x64',str(obj),str(OUTPUT/'x86_64-kernel.lib'),str(OUTPUT/'overlay-kernel.lib'),'/out:'+str(exe)],check=True)
    obj=OUTPUT/'present-test.obj';subprocess.run([*common,'-I'+str(ROOT/'Runtime/vulkan-headers-1.4.366/include'),'-c',str(ROOT/'Scripts/runtime_xinput_present_test.c'),'-o',str(obj)],check=True)
    library=OUTPUT/'ready-present-test.dll';subprocess.run([link,'/timestamp:0','/nodefaultlib','/dll','/entry:DllMain','/machine:x64',str(obj),*[str(OUTPUT/(name+'.lib')) for name in ['present-kernel','present-user','present-crt']],'/out:'+str(library)],check=True)
    return exe,library

def wait_status(session,predicate,timeout=20):
    deadline=time.monotonic()+timeout
    while time.monotonic()<deadline:
        try:
            value=json.loads(session.status.read_text())
            if predicate(value):return value
        except (FileNotFoundError,json.JSONDecodeError):pass
        if session.process.poll() is not None:raise RuntimeError('Presenting Windows process exited')
        time.sleep(.025)
    raise TimeoutError('Actual Metal overlay did not reach expected state')

def main():
    parser=argparse.ArgumentParser(description=__doc__);parser.add_argument('--template',type=Path);args=parser.parse_args()
    if args.template:assert args.template.parent.parent.name.startswith('xinput-real-overlay-') and (args.template.parent.parent/'.ready-xinput-test').is_file()
    compile_tests();exe,present=compile_present();cfg=json.loads((ROOT/'Runtime/runtime.json').read_text());default_before=digest(ROOT/'Runtime/runtime.json');overlay=ROOT/'Build/libReadyOverlay.dylib';assert overlay.is_file()
    work=ROOT/'Runtime/TestPrefixes'/('xinput-real-overlay-'+uuid.uuid4().hex);work.mkdir();(work/'.ready-xinput-test').write_text('Synthetic device plus real injected Metal overlay\n');wine=stage_wine(work);session=None;result={'passed':False,'testDeviceProviderOnly':True,'physicalControllerVerified':False,'directToDisplayVerified':False}
    try:
        env={'DYLD_INSERT_LIBRARIES':str(overlay),'M1L_XINPUT_PRESENT_PROVIDER':'Z:'+str(present).replace('/','\\'),'VK_DRIVER_FILES':cfg['kosmicICD'],'VK_ICD_FILENAMES':cfg['kosmicICD']}
        session=Session(work/'session',wine,'x86_64','xinput1_4',template=args.template,extra_env=env,executable=exe)
        session.command('seed-a');idle=wait_status(session,lambda s:s.get('pid')==session.pid and s.get('frameCount',0)>0 and s.get('heartbeatActive') and not s.get('visible'))
        hidden=session.command('sample');result.update(idle=idle,hiddenInput=hidden);assert hidden['active']==1 and hidden['buttons']&0x1000 and not hidden['buttons']&0x10,hidden
        atomic(session.control,{'sequence':2,'visible':True,'selection':0});shown_status=wait_status(session,lambda s:s.get('controlSequence')==2 and s.get('visible') and s.get('overlayFrameCount',0)>0 and s.get('trackedTextureBytes',0)>0)
        shown=session.command('rumble');assert shown['active']==shown['visible']==1 and shown['buttons']==shown['leftTrigger']==shown['leftX']==shown['leftMotor']==shown['rightMotor']==0 and shown['rawButtons']&0x1000
        atomic(session.control,{'sequence':3,'visible':False,'selection':0});hidden_status=wait_status(session,lambda s:s.get('controlSequence')==3 and not s.get('visible') and s.get('trackedTextureBytes')==0)
        held=session.command('sample');assert held['buttons']==0
        session.command('seed-neutral');session.command('sample');session.command('seed-b');resumed=session.command('sample');assert resumed['buttons']==0x2000
        assert shown_status['inputCaptureEpoch']>idle['inputCaptureEpoch'] and idle['pid']==shown['nativePid']
        result.update(passed=True,nativeStatusWrittenByOverlay=True,unixPIDMatched=True,idle=idle,shownStatus=shown_status,hiddenStatus=hidden_status,hiddenInput=hidden,capturedInput=shown,heldAfterHide=held,resumedInput=resumed,defaultRuntimeModified=default_before!=digest(ROOT/'Runtime/runtime.json'),overlaySHA256=digest(overlay),probeSHA256=digest(exe),presenterSHA256=digest(present),testDeviceSHA256=digest(OUTPUT/'x86_64-ready-test-device.dll'),buildEvidenceSHA256=digest(ROOT/'Evidence/runtime-xinput-build.json'),sourceInputs={str(p.relative_to(ROOT)):digest(p) for p in [Path(__file__),ROOT/'Scripts/runtime_xinput_overlay_probe.c',ROOT/'Scripts/runtime_xinput_present_test.c',ROOT/'Scripts/runtime_xinput_probe.c',ROOT/'Scripts/runtime_xinput_test_device.c',ROOT/'Scripts/runtime_xinput_test.py',ROOT/'Scripts/runtime_vulkan_present.c']})
    finally:
        if session:
            session.close();log=ROOT/'Evidence/runtime-xinput-real-overlay.log';shutil.copy2(session.root/'wine.log',log);result['moduleLog']={'path':str(log.relative_to(ROOT)),'sha256':digest(log)}
        (ROOT/'Evidence/runtime-xinput-real-overlay.json').write_text(json.dumps(result,indent=2)+'\n')
        if result['passed']:shutil.rmtree(work)
    print(json.dumps(result,indent=2))
if __name__=='__main__':main()
