#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-only
"""Probe WinHTTP TLS/certificate rejection and real GDI/DirectWrite glyph alpha.

Creates only its own marked scratch prefix. New dependencies are selected before
all old paths using the raw Wine binary; old wrappers would prepend old dylibs.
"""
import argparse
import hashlib
import http.server
import json
import os
from pathlib import Path
import shutil
import ssl
import subprocess
import threading
import time
import urllib.request
import uuid

ROOT=Path(__file__).resolve().parents[1]
PROBES=ROOT/'Runtime/Probes'

def compile_probe(pe32=False):
    work=PROBES/('.platform-build-'+uuid.uuid4().hex);work.mkdir()
    suffix='32' if pe32 else ''
    argument_bytes={'GetStdHandle':4,'WriteFile':20,'ExitProcess':4,'GetCommandLineW':0,'GetLastError':0,'LoadLibraryW':4,'GetProcAddress':8,'FreeLibrary':4,'CreateCompatibleDC':4,'CreateFontW':56,'SelectObject':8,'GetGlyphOutlineW':28,'DeleteObject':4,'DeleteDC':4,'WinHttpCrackUrl':16,'WinHttpOpen':20,'WinHttpSetTimeouts':20,'WinHttpConnect':16,'WinHttpOpenRequest':28,'WinHttpSendRequest':28,'WinHttpReceiveResponse':8,'WinHttpQueryHeaders':24,'WinHttpQueryDataAvailable':8,'WinHttpReadData':16,'WinHttpCloseHandle':4}
    libraries={
      'platform-kernel32':('KERNEL32.dll',['GetStdHandle','WriteFile','ExitProcess','GetCommandLineW','GetLastError','LoadLibraryW','GetProcAddress','FreeLibrary']),
      'platform-gdi32':('GDI32.dll',['CreateCompatibleDC','CreateFontW','SelectObject','GetGlyphOutlineW','DeleteObject','DeleteDC']),
      'platform-winhttp':('WINHTTP.dll',['WinHttpCrackUrl','WinHttpOpen','WinHttpSetTimeouts','WinHttpConnect','WinHttpOpenRequest','WinHttpSendRequest','WinHttpReceiveResponse','WinHttpQueryHeaders','WinHttpQueryDataAvailable','WinHttpReadData','WinHttpCloseHandle'])}
    for name,(dll,exports) in libraries.items():
        definition=work/(name+'.def');names=[name+'@'+str(argument_bytes[name]) if pe32 else name for name in exports];definition.write_text('LIBRARY '+dll+'\nEXPORTS\n'+'\n'.join(names)+'\n')
        subprocess.run(['/opt/homebrew/opt/llvm/bin/llvm-dlltool','-m','i386' if pe32 else 'i386:x86-64','--kill-at','-d',str(definition),'-l',str(work/(name+'.lib'))],check=True)
    subprocess.run(['/opt/homebrew/opt/llvm/bin/clang','--target=i686-windows' if pe32 else '--target=x86_64-windows','--no-default-config','-ffreestanding','-fno-builtin','-fshort-wchar','-O2','-I',str(ROOT/'Runtime/wine-11.20/include/wine/windows'),'-I',str(ROOT/'Vendor/wine/include/msvcrt'),'-c',str(ROOT/'Scripts/runtime_platform_probe.c'),'-o',str(work/'runtime_platform_probe.obj')],check=True)
    pending=work/('runtime_platform_probe'+suffix+'.exe')
    subprocess.run(['/opt/homebrew/opt/lld/bin/lld-link','/entry:mainCRTStartup','/subsystem:console','/machine:x86' if pe32 else '/machine:x64','/safeseh:no','/nodefaultlib',str(work/'runtime_platform_probe.obj'),*[str(work/(name+'.lib')) for name in libraries],'/out:'+str(pending)],check=True)
    os.replace(pending,PROBES/('runtime_platform_probe'+suffix+'.exe'));shutil.rmtree(work)

class Handler(http.server.BaseHTTPRequestHandler):
    def log_message(self,*args):pass
    def do_GET(self):
        body=b'Ready synthetic TLS certificate negative control\n'
        self.send_response(200);self.send_header('Content-Length',str(len(body)));self.end_headers();self.wfile.write(body)

def server(root):
    config=root/'localhost.cnf';key=root/'localhost.key';certificate=root/'localhost.pem'
    config.write_text('[req]\ndistinguished_name=dn\nx509_extensions=ext\nprompt=no\n[dn]\nCN=localhost\n[ext]\nsubjectAltName=DNS:localhost,IP:127.0.0.1\nbasicConstraints=critical,CA:FALSE\nkeyUsage=critical,digitalSignature,keyEncipherment\nextendedKeyUsage=serverAuth\n')
    subprocess.run(['/usr/bin/openssl','req','-x509','-newkey','rsa:2048','-nodes','-days','1','-config',str(config),'-keyout',str(key),'-out',str(certificate)],check=True,capture_output=True)
    key.chmod(0o600)
    instance=http.server.ThreadingHTTPServer(('127.0.0.1',0),Handler);context=ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER);context.load_cert_chain(certificate,key);instance.socket=context.wrap_socket(instance.socket,server_side=True)
    worker=threading.Thread(target=instance.serve_forever,daemon=True);worker.start();return instance

def main():
    p=argparse.ArgumentParser(description=__doc__);p.add_argument('--wine-root',required=True,type=Path);p.add_argument('--dependency-root',required=True,type=Path);p.add_argument('--tag',required=True);p.add_argument('--dwrite-module',type=Path);p.add_argument('--tests',nargs='+',choices=['tls','untrusted','gdi','dwrite'],default=['tls','untrusted','gdi','dwrite']);p.add_argument('--allow-known-old-dwrite-failure',action='store_true');p.add_argument('--keep',action='store_true');p.add_argument('--pe32',action='store_true');a=p.parse_args()
    if not a.tag.replace('-','').isalnum():raise ValueError('A simple evidence tag is required')
    compile_probe(a.pe32);wine=a.wine_root.resolve();dependencies=a.dependency_root.resolve()
    if not (wine/'bin/wine').is_file() or not (dependencies/'libgnutls.30.dylib').is_file() or not (dependencies/'libfreetype.6.dylib').is_file():raise ValueError('Complete raw Wine and dependency lib directory required')
    cfg=json.loads((ROOT/'Runtime/runtime.json').read_text());base=Path(cfg['immutableRuntimeSet']);parent=ROOT/'Runtime/DependencyTests';parent.mkdir(exist_ok=True);scratch=parent/(a.tag+'-'+uuid.uuid4().hex);scratch.mkdir();marker=scratch/'.ready-synthetic-dependency-test';marker.write_text('Only synthetic test data\n');prefix=scratch/'prefix'
    if a.dwrite_module:
        subprocess.run(['/bin/cp','-cR',str(wine),str(scratch/'wine')],check=True);wine=scratch/'wine';shutil.copy2(a.dwrite_module,wine/'lib/wine/x86_64-unix/dwrite.so')
    prefix.mkdir();wow=prefix/'drive_c/windows/syswow64';wow.mkdir(parents=True);subprocess.run(['/bin/cp','-cR',str(wine/'lib/wine/i386-windows')+'/.',str(wow)],check=True)
    env=dict(os.environ,WINEPREFIX=str(prefix),WINEDEBUG='-all',WINEDLLOVERRIDES='mscoree,mshtml=d',DYLD_LIBRARY_PATH=str(base/'vulkan')+':'+str(dependencies))
    for name in ['CX_APPLEGPTK_LIBD3DSHARED_PATH','DYLD_FRAMEWORK_PATH','DYLD_INSERT_LIBRARIES','READY_OVERLAY_LIBRARY','WINEDLLPATH']:env.pop(name,None)
    report={'wineRoot':str(a.wine_root.resolve()),'testedWineRoot':str(wine),'dependencyRoot':str(dependencies),'tag':a.tag,'pointerBits':32 if a.pe32 else 64,'scopeTests':a.tests,'tests':{},'allPassed':False,'certificateValidationBypassUsed':False,'sourceProbeSHA256':hashlib.sha256((ROOT/'Scripts/runtime_platform_probe.c').read_bytes()).hexdigest()}
    manifest_path=dependencies.parent/'manifest.json';manifest=json.loads(manifest_path.read_text()) if manifest_path.is_file() else None
    if manifest:
        report['testedBinaryHashes']={entry['path']:entry['sha256'] for entry in manifest['binaryFiles']}
        for relative,expected in report['testedBinaryHashes'].items():
            if hashlib.sha256((dependencies.parent/relative).read_bytes()).hexdigest()!=expected:raise RuntimeError('Candidate binary differs from manifest: '+relative)
        report['dependencyBinaryFingerprint']=manifest['binaryFingerprint']
        report['dependencyManifestSHA256']=hashlib.sha256(manifest_path.read_bytes()).hexdigest()
        for name,value in manifest.get('runtimeEnvironmentForRelocation',{}).items():
            if name not in ['P11_MODULE_PATH','P11_PACKAGE_CONFIG_MODULES','P11_SYSTEM_CONFIG_MODULES']:raise ValueError('Unsupported dependency environment key')
            env[name]=value.replace('${prefix}',str(dependencies.parent))
        report['dependencyRuntimeEnvironment']={name:env[name] for name in manifest.get('runtimeEnvironmentForRelocation',{})}
    http=None;output=ROOT/'Evidence'/('runtime-dependencies-'+a.tag+'.json')
    try:
        boot=subprocess.run([str(wine/'bin/wine'),'wineboot','-u'],env=env,capture_output=True,timeout=180);subprocess.run([str(wine/'bin/wineserver'),'-k'],env=env,capture_output=True,timeout=10);report['bootExitCode']=boot.returncode
        if boot.returncode:raise RuntimeError('Wine bootstrap failed')
        # Public data only: independent native HTTPS control confirms network health.
        if 'tls' in a.tests:
            with urllib.request.urlopen('https://example.com/',timeout=30) as response:body=response.read(1048576);report['nativeHTTPSControl']={'status':response.status,'exampleMarkerPresent':b'Example Domain' in body,'bytes':len(body)}
        url=''
        if 'untrusted' in a.tests:http=server(scratch);url='https://127.0.0.1:'+str(http.server_address[1])+'/'
        tests=[('tls',['--tls','--url=https://example.com/']),('untrusted',['--tls','--url='+url,'--expect-secure-failure']),('gdi',['--gdi']),('dwrite',['--dwrite'])]
        for name,args in tests:
            if name not in a.tests:continue
            e=dict(env,DYLD_PRINT_LIBRARIES='1',WINEDEBUG='+winhttp,+secur32' if name in ['tls','untrusted'] else '-all');log=ROOT/'Evidence'/('runtime-dependencies-'+a.tag+'-'+name+'.log');started=time.monotonic()
            try:
                with log.open('wb') as stream:r=subprocess.run([str(wine/'bin/wine'),str(PROBES/('runtime_platform_probe32.exe' if a.pe32 else 'runtime_platform_probe.exe')),*args],env=e,stdout=subprocess.PIPE,stderr=stream,timeout=90)
                stdout=r.stdout.decode(errors='replace');values=[]
                for line in stdout.splitlines():
                    try:values.append(json.loads(line))
                    except ValueError:pass
                observation=values[-1] if values else {};passed=r.returncode==0
                if name=='tls':passed &= observation.get('httpsVerified') is True and observation.get('exampleMarkerPresent') is True
                elif name=='untrusted':
                    certificate_rejected=any('cert verify failed: '+str(code) in log.read_text(errors='replace') for code in [12045,12175])
                    observation['certificateValidationRejectionConfirmed']=certificate_rejected
                    passed &= observation.get('secureFailureRejected') is True and certificate_rejected
                else:passed &= observation.get('glyphRasterVerified') is True
                report['tests'][name]={'exitCode':r.returncode,'observation':observation,'stdout':stdout,'passed':passed,'seconds':round(time.monotonic()-started,3),'log':str(log)}
                loaded=[]
                for line in log.read_text(errors='replace').splitlines():
                    if line.startswith('dyld[') and '> ' in line:
                        candidate=line.split('> ',1)[1].strip()
                        if candidate.endswith('.dylib'):loaded.append(candidate)
                report['tests'][name]['loadedDylibs']=sorted(set(loaded))
                if manifest:
                    unexpected=[path for path in loaded if not path.startswith(('/System/','/usr/lib/',str(dependencies.parent)+'/',str(base/'vulkan')+'/'))]
                    report['tests'][name]['unexpectedNonSystemDylibs']=sorted(set(unexpected))
                    passed &= not unexpected and not any('MacportsLegacy' in path for path in loaded)
                    report['tests'][name]['passed']=passed
                print(name,json.dumps({'passed':passed,'observation':observation,'seconds':report['tests'][name]['seconds']}),flush=True);output.write_text(json.dumps(report,indent=2)+'\n')
            finally:subprocess.run([str(wine/'bin/wineserver'),'-k'],env=env,capture_output=True,timeout=10)
        report['allPassed']=all(v['passed'] for v in report['tests'].values());report['baselineKnownDwriteFailure']=a.allow_known_old_dwrite_failure and 'dwrite' in report['tests'] and not report['tests']['dwrite']['passed']
        if not report['allPassed'] and not (report['baselineKnownDwriteFailure'] and all(value['passed'] for name,value in report['tests'].items() if name!='dwrite')):raise RuntimeError('Required platform dependency test failed')
    except Exception as error:report['error']=str(error);raise
    finally:
        if http:http.shutdown();http.server_close()
        subprocess.run([str(wine/'bin/wineserver'),'-k'],env=env,capture_output=True,timeout=10)
        if not a.keep and scratch.parent==parent and marker.is_file():shutil.rmtree(scratch)
        report['scratchRetained']=a.keep;output.write_text(json.dumps(report,indent=2)+'\n')
        if manifest:
            unchanged=all(hashlib.sha256((dependencies.parent/relative).read_bytes()).hexdigest()==expected for relative,expected in report['testedBinaryHashes'].items())
            report['candidateInputsUnchanged']=unchanged;output.write_text(json.dumps(report,indent=2)+'\n')
            if not unchanged:raise RuntimeError('Candidate input changed during platform tests')

if __name__=='__main__':main()
