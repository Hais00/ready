#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-only
"""Exercise candidate configs through their actual wrappers, without activation."""
import hashlib
import json
import os
from pathlib import Path
import shutil
import subprocess
import time
import uuid
import argparse
import re

import runtime_dependency_smoke as platform
ROOT=Path(__file__).resolve().parents[1]

def sha(path):
    with path.open('rb') as stream:return hashlib.file_digest(stream,'sha256').hexdigest()

def main():
    parser=argparse.ArgumentParser(description=__doc__);parser.add_argument('--resume-apple',action='store_true');args=parser.parse_args()
    audit=ROOT/'Runtime/Probes/libReadyDependencyAudit.dylib';pending=audit.with_suffix('.pending')
    subprocess.run(['/usr/bin/clang','-arch','x86_64','-O2','-dynamiclib',str(ROOT/'Scripts/runtime_native_audit.c'),'-o',str(pending)],check=True);os.replace(pending,audit)
    paths=[ROOT/'Runtime/candidate-runtime.json',ROOT/'Runtime/candidate-evaluation-runtime.json'];configs=[json.loads(path.read_text()) for path in paths];config,evaluation=configs;base=Path(config['immutableRuntimeSet']);deps=base/'dependency-root';selection=json.loads((deps/'selected-runtime-files.json').read_text());expected=selection['selectedBinaryHashes'];before={str(path):sha(path) for path in paths+[ROOT/'Runtime/runtime.json',ROOT/'Runtime/evaluation-runtime.json']}
    if evaluation.get('evaluationModeEnabled') or evaluation['appleOptional'].get('enabledForConsumerPlay'):raise RuntimeError('Candidate evaluation must be disabled by default')
    for name,value in expected.items():
        if sha(deps/name)!=value:raise RuntimeError('Selected dependency bytes changed')
    parent=ROOT/'Runtime/TestPrefixes';scratch=parent/('source-candidate-e2e-'+uuid.uuid4().hex);scratch.mkdir();marker=scratch/'.ready-source-candidate-e2e';marker.write_text('Only synthetic development tests\n')
    (scratch/'Runtimes').mkdir();(scratch/'Runtimes/runtime.json').write_bytes(paths[0].read_bytes());local_eval=dict(evaluation,evaluationModeEnabled=True);(scratch/'Runtimes/evaluation-runtime.json').write_text(json.dumps(local_eval,indent=2)+'\n')
    pure32=Path(evaluation['engineBootstrap32Dirs']['d3dMetal']);pure=pure32.parent.parent.parent
    hosts={'base':(Path(config['wine']),Path(config['builtin32Directory']),'d3d9,d3d11,dxgi=b',False),'dxmt':(Path(config['engineWineBinaries']['dxmtMetal']),Path(config['builtin32Directory']),config['engineOverrides']['dxmtMetal'],False),'pureCX':(pure/'bin/ready-wine',pure32,'mscoree,mshtml=d',False),'apple':(Path(evaluation['engineWineBinaries']['d3dMetal']),pure32,evaluation['engineOverrides']['d3dMetal'],True)}
    prefixes={};envs={};report={'candidateConfigSHA256':before[str(paths[0])],'candidateEvaluationConfigSHA256':before[str(paths[1])],'runtimeID':config['runtimeID'],'evaluationRuntimeID':evaluation['runtimeID'],'selectedDependencyHashes':expected,'tests':{},'passed':False,'consumerAppleEnabled':False};output=ROOT/'Evidence/runtime-source-candidate-e2e.json';server=platform.server(scratch)
    if args.resume_apple:
        previous=json.loads(output.read_text())
        if previous['candidateConfigSHA256']!=before[str(paths[0])] or previous['candidateEvaluationConfigSHA256']!=before[str(paths[1])] or previous['selectedDependencyHashes']!=expected:raise RuntimeError('Cannot resume proof for different bytes')
        done={key:value for key,value in previous['tests'].items() if not key.startswith('apple.')}
        if len(done)!=24 or not all(value['passed'] for value in done.values()):raise RuntimeError('All24 prior Open proofs required')
        report['tests']=done;report['resumedAppleOnly']=True
    def prepare(name):
        wrapper,source,overrides,is_eval=hosts[name];prefix=scratch/'Prefixes'/str(uuid.uuid4())/('synthetic-'+name);wow=prefix/'drive_c/windows/syswow64';wow.mkdir(parents=True);subprocess.run(['/bin/cp','-cR',str(source)+'/.',str(wow)],check=True)
        env={key:value for key,value in os.environ.items() if not key.startswith(('WINE','DYLD_','READY_','M1L_','CX_APPLEGPTK'))};env.update(WINEPREFIX=str(prefix),WINEDLLOVERRIDES=overrides+';mscoree,mshtml=d',WINEDEBUG='-all',READY_DYLD_DIAGNOSTICS='1',DXMT_LOG_PATH='none',DXMT_SHADER_CACHE_PATH=str(prefix/'dxmt-cache'))
        if is_eval:env['D3DM_MTL4']='1'
        log=ROOT/'Evidence'/('runtime-source-candidate-'+name+'-boot.log')
        with log.open('wb') as stream:boot=subprocess.run([str(wrapper),'wineboot','-u'],env=env,stdout=stream,stderr=stream,timeout=180)
        subprocess.run([str(wrapper.parent/'wineserver'),'-k'],env=env,capture_output=True,timeout=10)
        if boot.returncode:raise RuntimeError('Candidate wrapper bootstrap failed: '+name)
        prefixes[name]=prefix;envs[name]=env
    def run(name,host,exe,args,check,icd=None):
        wrapper=hosts[host][0];env=dict(envs[host]);env['WINEDEBUG']='+winhttp,+secur32' if '.tls' in name or '.untrusted' in name else '+loaddll'
        if icd:env.update(VK_DRIVER_FILES=icd,VK_ICD_FILENAMES=icd)
        log=ROOT/'Evidence'/('runtime-source-candidate-'+name+'.log');images=log.with_suffix('.images.jsonl');images.unlink(missing_ok=True)
        if host!='apple':env.update(READY_NATIVE_AUDIT_LIBRARY=str(audit),READY_NATIVE_AUDIT_LOG=str(images))
        start=time.monotonic()
        try:
            with log.open('wb') as stream:r=subprocess.run([str(wrapper),str(exe),*args],env=env,stdout=subprocess.PIPE,stderr=stream,timeout=120)
            stdout=r.stdout.decode(errors='replace');observations=[]
            for line in stdout.splitlines():
                try:observations.append(json.loads(line))
                except ValueError:pass
            trace=log.read_text(errors='replace');loaded=[];audit_records=[]
            interleaved=0
            if host!='apple':
                for line in images.read_text().splitlines():
                    value=json.loads(line);audit_records.append(value)
                    if value['path'].endswith('.dylib') and value['path']!=str(audit):loaded.append(value['path'])
            else:
                # Apple SDK is tested without injected add-image callbacks.
                # Split dyld headers first; a truncated fragment is recorded as
                # incomplete diagnostic data, never as a fabricated library.
                entries=list(re.finditer(r'dyld\[(\d+)\]: <[0-9A-Fa-f-]{36}> ',trace))
                for index,entry in enumerate(entries):
                    newline=trace.find('\n',entry.end());newline=len(trace) if newline<0 else newline;next_at=entries[index+1].start() if index+1<len(entries) else len(trace);end=min(newline,next_at);value=trace[entry.end():end].strip()
                    if next_at<newline:interleaved+=1
                    if value.startswith('/') and value.endswith('.dylib'):loaded.append(value);audit_records.append({'pid':int(entry.group(1)),'path':value})
            allowed=['/System/','/usr/lib/',str(base)+'/']
            if host=='apple':allowed.append(str(wrapper.parent.parent/'lib/external')+'/')
            unexpected=sorted(set(value for value in loaded if not value.startswith(tuple(allowed))))
            passed=r.returncode==0 and any(check(value) for value in observations) and bool(loaded) and not unexpected and not any('MacportsLegacy' in value for value in loaded)
            if '.untrusted' in name:passed &= any('cert verify failed: '+str(value) in trace for value in [12045,12175])
            report['tests'][name]={'passed':passed,'exitCode':r.returncode,'observations':observations,'seconds':round(time.monotonic()-start,3),'wrapper':str(wrapper),'log':str(log),'nativeImageAudit':str(images) if host!='apple' else None,'nativeAuditInjected':host!='apple','interleavedStandardDiagnosticRecords':interleaved,'auditRecords':len(audit_records),'auditLibrarySHA256':sha(audit) if host!='apple' else None,'loadedDylibs':sorted(set(loaded)),'unexpectedNonSystemDylibs':unexpected};output.write_text(json.dumps(report,indent=2)+'\n');print(name,json.dumps({'passed':passed,'observations':observations}),flush=True)
            if not passed:raise RuntimeError('Candidate E2E failed: '+name)
        finally:subprocess.run([str(wrapper.parent/'wineserver'),'-k'],env=env,capture_output=True,timeout=10)
    def retire(name):
        if name not in envs:return
        subprocess.run([str(hosts[name][0].parent/'wineserver'),'-k'],env=envs[name],capture_output=True,timeout=10)
        subprocess.run([str(hosts[name][0].parent/'wineserver'),'-w'],env=envs[name],capture_output=True,timeout=10)
        prefix=prefixes.pop(name);envs.pop(name)
        if not prefix.is_relative_to(scratch/'Prefixes'):raise RuntimeError('Scratch cleanup escaped test root')
        shutil.rmtree(prefix)
    try:
        for host in ([] if args.resume_apple else ['base','pureCX']):
            prepare(host)
            for bits in [64,32]:
                exe=ROOT/'Runtime/Probes'/('runtime_platform_probe'+('32' if bits==32 else '')+'.exe');stem=host+'.pe'+str(bits)
                run(stem+'.tls',host,exe,['--tls','--url=https://example.com/'],lambda v:v.get('httpsVerified') is True and v.get('exampleMarkerPresent') is True)
                run(stem+'.untrusted',host,exe,['--tls','--url=https://127.0.0.1:'+str(server.server_address[1])+'/','--expect-secure-failure'],lambda v:v.get('secureFailureRejected') is True)
                for mode in ['gdi','dwrite']:run(stem+'.'+mode,host,exe,['--'+mode],lambda v:v.get('glyphRasterVerified') is True)
        if not args.resume_apple:
            run('base.dx9','base',ROOT/'Runtime/Probes/runtime_windows_probe.exe',['dx9'],lambda v:v.get('gpuBufferReadbackVerified') is True)
            for name,key in [('kosmic','kosmicICD'),('molten','moltenICD')]:run('base.vulkan-'+name,'base',ROOT/'Runtime/Probes/runtime_vulkan_probe.exe',[],lambda v:v.get('readbackVerified') is True,config[key])
            retire('base');retire('pureCX')
            prepare('dxmt')
        for bits in ([] if args.resume_apple else [64,32]):
            suffix='32' if bits==32 else '';stem='dxmt.pe'+str(bits)
            run(stem+'.buffer','dxmt',ROOT/'Runtime/Probes'/('runtime_windows_probe'+suffix+'.exe'),['dx11'],lambda v:v.get('gpuBufferReadbackVerified') is True and int(v.get('featureLevel','0'),0)>=0xb000)
            if bits==64:run(stem+'.shader','dxmt',ROOT/'Runtime/DXMTExperiment/dxmt_shader_probe.exe',[],lambda v:v.get('shaderRasterizationVerified') is True)
            run(stem+'.present','dxmt',ROOT/'Runtime/Probes'/('runtime_d3d11_present'+suffix+'.exe'),[],lambda v:v.get('presentedFrames',0)>=60)
        retire('dxmt')
        prepare('apple')
        run('apple.eval-dx12','apple',ROOT/'Runtime/Probes/runtime_d3d12_probe.exe',[],lambda v:v.get('shaderRasterizationVerified') is True and v.get('renderTargetClearReadbackVerified') is True)
        run('apple.eval-present','apple',ROOT/'Runtime/Probes/runtime_d3d12_present.exe',[],lambda v:v.get('submittedShaderFrames',0)>=60 and v.get('presentedFrames',0)>=60)
        report['passed']=True
    except Exception as error:report['error']=str(error);raise
    finally:
        server.shutdown();server.server_close()
        for name,env in envs.items():subprocess.run([str(hosts[name][0].parent/'wineserver'),'-k'],env=env,capture_output=True,timeout=10)
        report['candidateAndLiveConfigsUnchanged']=all(sha(Path(name))==value for name,value in before.items());report['selectedDependencyBytesUnchanged']=all(sha(deps/name)==value for name,value in expected.items());report['scratchRetained']=False
        if scratch.parent==parent and marker.is_file():shutil.rmtree(scratch)
        output.write_text(json.dumps(report,indent=2)+'\n')
        if not report['candidateAndLiveConfigsUnchanged'] or not report['selectedDependencyBytesUnchanged']:raise RuntimeError('Configuration or selected bytes changed during E2E')

if __name__=='__main__':main()
