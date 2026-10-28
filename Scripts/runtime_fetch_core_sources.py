#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-only
"""Acquire exact Wine/DXMT source material, without building or changing providers.

Archives remain compressed. A retained source archive is not proof that an
upstream binary incorporated those bytes; the artifact gate always stays false.
"""
from __future__ import annotations
import argparse,datetime,hashlib,json,os,re,shutil,subprocess,tarfile,time,urllib.error,urllib.parse,urllib.request,zipfile,uuid
from pathlib import Path

ROOT=Path(__file__).resolve().parents[1]
LOCK=ROOT/'Scripts/runtime_core_sources.lock.json'
PACKETS=ROOT/'Runtime/CorrespondingSources'
RESERVE=512*1024*1024
AGENT='ready-corresponding-source-acquisition'

class ReserveLow(RuntimeError):pass

def now():return datetime.datetime.now(datetime.timezone.utc).isoformat()
def digest(path):
    h=hashlib.sha256()
    with Path(path).open('rb') as f:
        while data:=f.read(1024*1024):h.update(data)
    return h.hexdigest()
def atomic_json(path,value):
    path=Path(path);path.parent.mkdir(parents=True,exist_ok=True);temp=path.with_name(path.name+'.partial-json');temp.write_text(json.dumps(value,indent=2)+'\n');os.replace(temp,path)
def available():return shutil.disk_usage(ROOT).free
def require_space(amount=0):
    if available()<RESERVE+amount:raise ReserveLow('Preserving the required 512 MiB free-space reserve')
def request(url):
    encoded=urllib.parse.quote(url,safe=':/?=&%+@')
    return urllib.request.Request(encoded,headers={'User-Agent':AGENT})
def read_metadata(url):
    with urllib.request.urlopen(request(url),timeout=60) as response:
        data=response.read(8*1024*1024)
        if len(data)>=8*1024*1024:raise RuntimeError('Unexpectedly large source metadata')
        return data,response.geturl()
def github_commit(repository,ref):
    url='https://api.github.com/repos/'+repository+'/commits/'+urllib.parse.quote(ref,safe='')
    try:
        data,final=read_metadata(url);value=json.loads(data)
    except urllib.error.HTTPError as error:
        if error.code not in [403,429]:raise
        # Git's public ref advertisement is an independent primary source when
        # the unauthenticated metadata API is rate-limited.
        if re.fullmatch('[0-9a-f]{40}',ref):
            return ref,{'requestURL':url,'apiStatus':error.code,'resolvedCommit':ref,'resolution':'immutable source-recipe commit; existence additionally checked by archive download'}
        remote='https://github.com/'+repository+'.git'
        result=subprocess.run(['git','ls-remote',remote,'refs/tags/'+ref,'refs/tags/'+ref+'^{}','refs/heads/'+ref],text=True,capture_output=True,check=True,timeout=60,env={**os.environ,'GIT_TERMINAL_PROMPT':'0'})
        refs=dict(line.split('\t',1)[::-1] for line in result.stdout.splitlines())
        commit=refs.get('refs/tags/'+ref+'^{}') or refs.get('refs/tags/'+ref) or refs.get('refs/heads/'+ref)
        if not commit:raise RuntimeError('Public Git advertisement did not resolve '+repository+' '+ref)
        return commit,{'requestURL':url,'apiStatus':error.code,'gitRemote':remote,'advertisedRefs':refs,'resolvedCommit':commit,'resolution':'public Git ref advertisement, annotated tags peeled'}
    commit=value.get('sha','')
    if not re.fullmatch('[0-9a-f]{40}',commit):raise RuntimeError('Missing immutable commit for '+repository+' '+ref)
    return commit,{'requestURL':url,'finalURL':final,'responseSHA256':hashlib.sha256(data).hexdigest(),'response':value}
def code_component(identifier,repository,ref,commit,role):
    return {'id':identifier,'kind':'source-code','repository':repository,'requestedRef':ref,'resolvedCommit':commit,'url':f'https://codeload.github.com/{repository}/tar.gz/{commit}','filename':identifier+'.tar.gz','archiveSHA256':None,'role':role,'artifactCorrespondenceVerified':False,'licenseApproval':False}

def resolve():
    if LOCK.exists():
        result=json.loads(LOCK.read_text())
        if result.get('schema')!=1:raise RuntimeError('Unsupported core source lock')
        return result
    workflow=ROOT/'DXMTIntegration/Source/.github/workflows/ci.yml';text=workflow.read_text();dxmt=json.loads((ROOT/'DXMTIntegration/dxmt.lock.json').read_text());wine=json.loads((ROOT/'Vendor/wine.source.json').read_text())
    def env(name):
        match=re.search(r'^  '+name+r':\s*"?([^"\n]+)"?$',text,re.M)
        if not match:raise RuntimeError('DXMT workflow input missing: '+name)
        return match.group(1).strip()
    components=[{'id':'wine-11.20','kind':'source-code','url':wine['url'],'filename':'wine-11.20.tar.xz','archiveSHA256':wine['sha256'],'role':'active Wine upstream source plus its bundled source/fonts/data; local patches are separate','artifactCorrespondenceVerified':False,'licenseApproval':False}]
    unicode_path=ROOT/'Vendor/wine/tools/make_unicode';unicode=unicode_path.read_text();variables=dict(re.findall(r'my \$(\w+) = "([^"]+)";',unicode))
    pattern=r'(\w+)\s*=>\s*\{\s*url\s*=>\s*"([^"]+)"(?:,\s*name\s*=>\s*"([^"]+)")?,\s*sha\s*=>\s*"([^"]+)"'
    datasets=[]
    for identifier,url,preferred,sha in re.findall(pattern,unicode):
        for key,value in variables.items():url=url.replace('$'+key,value);preferred=preferred.replace('$'+key,value)
        filename=preferred or url.rsplit('/',1)[-1]
        datasets.append({'id':'wine-data-'+identifier,'kind':'preferred-generator-input','datasetID':identifier,'url':url,'filename':identifier+'-'+filename,'generatorCacheName':filename,'archiveSHA256':sha,'role':'preferred input to Wine make_unicode; data terms remain separately unreviewed','artifactCorrespondenceVerified':False,'licenseApproval':False})
    if len(datasets)!=15:raise RuntimeError('Wine make_unicode input table changed; expected exactly15 reviewed input records')
    components+=datasets;metadata={};resolved={}
    for name,repo,ref in [('llvm15','llvm/llvm-project',env('LLVM_VERSION')),('wine-ci','3Shain/wine',env('WINE_VERSION')),('llvm-mingw','mstorsjo/llvm-mingw',env('LLVM_MINGW_VERSION'))]:
        commit,record=github_commit(repo,ref);metadata[name]=record;resolved[name]=(repo,ref,commit)
    repo,ref,commit=resolved['llvm15'];components.append(code_component('llvm15-airconv',repo,ref,commit,'LLVM code linked statically into DXMT airconv/winemetal; entire LLVM project source retained compressed'))
    repo,ref,commit=resolved['wine-ci'];components.append(code_component('wine-ci-startup',repo,ref,commit,'Wine CI startup/import library source candidate; runtime Wine11.20 is a separate source input'))
    repo,ref,commit=resolved['llvm-mingw'];components.append(code_component('llvm-mingw-recipes',repo,ref,commit,'toolchain provider build recipes; recipe source is not automatically incorporated runtime code'))
    drivers={}
    for filename in ['build-llvm.sh','build-mingw-w64.sh','build-compiler-rt.sh','build-libcxx.sh','build-all.sh']:
        url=f'https://raw.githubusercontent.com/{repo}/{commit}/{filename}';data,final=read_metadata(url);drivers[filename]={'url':url,'finalURL':final,'sha256':hashlib.sha256(data).hexdigest(),'text':data.decode()}
    llvm_ref=re.search(r'\$\{LLVM_VERSION:=([^}]+)\}',drivers['build-llvm.sh']['text'])
    crt_ref=re.search(r'\$\{MINGW_W64_VERSION:=([^}]+)\}',drivers['build-mingw-w64.sh']['text'])
    if not llvm_ref or not crt_ref:raise RuntimeError('LLVM-MinGW defaults changed; do not guess source versions')
    for identifier,repo,ref,role in [
        ('llvm-mingw-runtime-sources','llvm/llvm-project',llvm_ref.group(1),'compiler-rt/libc++/libc++abi/libunwind runtime source candidates and compiler source in same archive; exact incorporated objects still need proof'),
        ('mingw-w64-crt','mingw-w64/mingw-w64',crt_ref.group(1),'MinGW-w64 headers/CRT runtime source candidate from pinned LLVM-MinGW build default')]:
        commit,record=github_commit(repo,ref);metadata[identifier]=record;components.append(code_component(identifier,repo,ref,commit,role))
    identity=hashlib.sha256(json.dumps(components,sort_keys=True,separators=(',',':')).encode()).hexdigest()[:20]
    lock={'schema':1,'createdUTC':now(),'packetID':'core-sources-'+identity,'dxmtSourceCommit':dxmt['sourceCommit'],'dxmtWorkflow':str(workflow.relative_to(ROOT)),'dxmtWorkflowSHA256':digest(workflow),'wineGenerator':str(unicode_path.relative_to(ROOT)),'wineGeneratorSHA256':digest(unicode_path),'reserveBytes':RESERVE,'components':components,'primaryMetadata':metadata,'llvmMinGWDriverSnapshots':drivers,'artifactCorrespondenceVerified':False,'licenseApproval':False,'sourceSelectionNote':'CI source refs and default recipe refs, not attestation that cached build inputs were used unchanged'}
    atomic_json(LOCK,lock);return lock

def candidate_notice(name):
    lower=Path(name).name.lower()
    return any(lower.startswith(key) for key in ['license','licence','copying','copyright','notice','readme','mustread','terms'])
def preserve_notices(archive,component,packet):
    root=packet/'notices'/component['id'];root.mkdir(parents=True,exist_ok=True);records=[];total=0
    def save(name,stream,size):
        nonlocal total
        parts=Path(name).parts
        if Path(name).is_absolute() or '..' in parts:return
        if size>4*1024*1024 or total+size>64*1024*1024:return
        require_space(size);data=stream.read(size+1)
        if len(data)!=size:raise RuntimeError('Archive notice length changed')
        target=root.joinpath(*parts);target.parent.mkdir(parents=True,exist_ok=True);target.write_bytes(data);total+=size
        records.append({'archiveMember':name,'path':str(target.relative_to(packet)),'sha256':digest(target),'bytes':size,'classification':'candidate notice, not a license approval'})
    if zipfile.is_zipfile(archive):
        with zipfile.ZipFile(archive) as z:
            for info in z.infolist():
                if not info.is_dir() and candidate_notice(info.filename):
                    with z.open(info) as stream:save(info.filename,stream,info.file_size)
    elif tarfile.is_tarfile(archive):
        # Streaming prevents a huge LLVM source tree from being extracted or indexed.
        with tarfile.open(archive,mode='r|*') as t:
            for member in t:
                if member.isfile() and candidate_notice(member.name):
                    stream=t.extractfile(member)
                    if stream:save(member.name,stream,member.size)
    elif archive.stat().st_size<=4*1024*1024:
        with archive.open('rb') as stream:save(component['filename']+'.raw-input.txt',stream,archive.stat().st_size)
    return records

def fetch_one(component,packet,lock):
    require_space();dest=packet/'archives'/component['filename'];dest.parent.mkdir(parents=True,exist_ok=True);expected=component['archiveSHA256'];started=now();final=component['url'];headers={}
    if dest.is_file():
        current=digest(dest)
        if expected and current!=expected:raise RuntimeError('Existing archive SHA mismatch: '+component['id'])
    else:
        temp=dest.with_name(dest.name+'.partial');h=hashlib.sha256();count=0;last=time.monotonic()
        try:
            with urllib.request.urlopen(request(component['url']),timeout=60) as response,temp.open('wb') as output:
                final=response.geturl();headers={k:response.headers[k] for k in ['Content-Length','ETag','Last-Modified'] if response.headers.get(k)}
                if headers.get('Content-Length','').isdigit():require_space(int(headers['Content-Length']))
                while data:=response.read(1024*1024):
                    require_space(len(data));output.write(data);h.update(data);count+=len(data)
                    if time.monotonic()-last>=25:print(component['id'],count,'bytes downloaded',flush=True);last=time.monotonic()
            current=h.hexdigest()
            if expected and current!=expected:raise RuntimeError('Downloaded source SHA mismatch: '+component['id'])
            os.replace(temp,dest)
        finally:
            temp.unlink(missing_ok=True)
    if not expected:
        component['archiveSHA256']=current;component['hashPinOrigin']='first verified HTTPS acquisition from immutable recorded Git commit; not binary correspondence proof';atomic_json(LOCK,lock)
    notices=preserve_notices(dest,component,packet)
    return {'component':component['id'],'status':'acquired','startedUTC':started,'completedUTC':now(),'sourceURL':component['url'],'finalURL':final,'responseHeaders':headers,'archivePath':str(dest.relative_to(packet)),'archiveBytes':dest.stat().st_size,'archiveSHA256':current,'archiveHashMatchesLock':current==component['archiveSHA256'],'sourceRole':component['role'],'notices':notices,'noticesExtractedCount':len(notices),'artifactCorrespondenceVerified':False,'licenseApproval':False,'largeSourceTreeExtracted':False}

def fetch(lock):
    packet=PACKETS/lock['packetID']
    if (packet/'finalized.json').exists():raise RuntimeError('Completed source packet is immutable; use --verify')
    marker=packet/'.source-acquisition.partial.json'
    if packet.exists() and not marker.is_file():raise RuntimeError('Retry requires a marked partial packet; use --finalize for the retained legacy acquisition')
    packet.mkdir(parents=True,exist_ok=True)
    if not marker.exists():atomic_json(marker,{'schema':1,'packetID':lock['packetID'],'createdUTC':now()})
    elif json.loads(marker.read_text()).get('packetID')!=lock['packetID']:raise RuntimeError('Partial packet marker identity differs')
    metadata=packet/'metadata';metadata.mkdir(exist_ok=True)
    for name,value in lock['primaryMetadata'].items():atomic_json(metadata/(name+'-commit.json'),value)
    drivers=metadata/'llvm-mingw-drivers';drivers.mkdir(exist_ok=True)
    for name,value in lock['llvmMinGWDriverSnapshots'].items():(drivers/name).write_text(value['text'])
    shutil.copy2(ROOT/lock['dxmtWorkflow'],metadata/'dxmt-ci.yml');shutil.copy2(ROOT/lock['wineGenerator'],metadata/'wine-make_unicode');shutil.copy2(__file__,metadata/'runtime_fetch_core_sources.py')
    receipt_path=packet/'acquisition.json';receipt=json.loads(receipt_path.read_text()) if receipt_path.exists() else {'schema':1,'packetID':lock['packetID'],'createdUTC':now(),'components':{},'artifactCorrespondenceVerified':False,'licenseApproval':False}
    for component in lock['components']:
        if available()<RESERVE:
            receipt['stoppedForReserve']=True;break
        completed=receipt['components'].get(component['id'],{})
        if completed.get('status')=='acquired':
            archive=packet/completed['archivePath']
            if not archive.is_file() or digest(archive)!=component['archiveSHA256']:raise RuntimeError('Completed partial input changed: '+component['id'])
            if any(not (packet/n['path']).is_file() or digest(packet/n['path'])!=n['sha256'] for n in completed.get('notices',[])):raise RuntimeError('Completed partial notice changed: '+component['id'])
            print('Retained verified completed input',component['id'],flush=True);continue
        print('Acquiring',component['id'],flush=True)
        try:
            receipt['components'][component['id']]=fetch_one(component,packet,lock)
            print(component['id'],'acquired',receipt['components'][component['id']]['archiveBytes'],'bytes',flush=True)
        except ReserveLow as error:
            receipt['components'][component['id']]={'status':'deferred-reserve','error':str(error)};receipt['stoppedForReserve']=True;atomic_json(receipt_path,receipt);break
        except Exception as error:
            receipt['components'][component['id']]={'status':'failed','error':type(error).__name__+': '+str(error)};print(component['id'],'failed:',str(error),flush=True)
        receipt['updatedUTC']=now();atomic_json(receipt_path,receipt)
    atomic_json(packet/'source-lock.json',lock)
    receipt.update(updatedUTC=now(),lockSHA256=digest(LOCK),sourceComponentsExpected=len(lock['components']),sourceComponentsAcquired=sum(v.get('status')=='acquired' for v in receipt['components'].values()),freeBytesAfter=available(),reserveBytes=RESERVE,allSourceMaterialAcquired=all(receipt['components'].get(c['id'],{}).get('status')=='acquired' for c in lock['components']))
    atomic_json(receipt_path,receipt)
    summary={'schema':1,'packet':str(packet),'lock':str(LOCK.relative_to(ROOT)),'lockSHA256':digest(LOCK),'acquisitionSHA256':digest(receipt_path),'componentsExpected':len(lock['components']),'componentsAcquired':receipt['sourceComponentsAcquired'],'allSourceMaterialAcquired':receipt['allSourceMaterialAcquired'],'stoppedForReserve':receipt.get('stoppedForReserve',False),'artifactCorrespondenceVerified':False,'licenseApproval':False,'runtimeModified':False,'rebuilt':False,'failedOrDeferred':{k:v for k,v in receipt['components'].items() if v.get('status')!='acquired'}}
    atomic_json(ROOT/'Evidence/runtime-core-source-acquisition.json',summary)
    (packet/'README.txt').write_text('Corresponding source acquisition packet. Archives stay compressed; extracted notices are candidates for review. Original Wine source/data SHA pins and immutable Git commit refs are in source-lock.json. No source is executed. No proprietary Apple framework/SDK is acquired. Source acquisition does NOT verify historical artifact static inputs or approve licenses/distribution. LLVM15 is potential incorporated airconv code; LLVM-MinGW recipes are build tooling; the separately acquired LLVM runtime and MinGW-w64 trees contain CRT/libc++/unwind source candidates. All artifact gates remain false.\n')
    print(json.dumps(summary,indent=2));return 0 if receipt['allSourceMaterialAcquired'] else 2

def require_unfinalized(packet):
    if (packet/'finalized.json').exists():raise RuntimeError('Completed source packet is immutable; use --verify')
def file_record(path,packet):return {'path':str(path.relative_to(packet)),'sha256':digest(path),'bytes':path.stat().st_size}
def catalogue(lock,packet):
    require_unfinalized(packet);require_space();metadata=packet/'metadata';metadata.mkdir(exist_ok=True)
    previous=metadata/'runtime_fetch_core_sources.py'
    if previous.exists() and digest(previous)!=digest(__file__):
        history=metadata/'recipe-history';history.mkdir(exist_ok=True);old=history/(digest(previous)+'.py')
        if not old.exists():shutil.copy2(previous,old)
    shutil.copy2(__file__,previous);shutil.copy2(ROOT/'LICENSE',metadata/'READY-GPL-3.0-LICENSE.txt')
    recipes=metadata/'local-recipes';recipes.mkdir(exist_ok=True)
    recipe_names=['runtime_build.py','runtime_patch_wine.py','runtime_wine_portability.patch','runtime_patch_dxmt_wine.py','runtime_wine_dxmt_window.patch','runtime_freeze.py','runtime_freeze_dxmt.py','runtime_freeze_source_stack.py']
    for name in recipe_names:shutil.copy2(ROOT/'Scripts'/name,recipes/name)
    # Retain the exact historical freezer as well as the current source recipe.
    historical=subprocess.check_output(['git','show','c224aff19345813601049af1e34be51c38056bf8:Scripts/runtime_freeze.py'])
    (recipes/'runtime_freeze-historical-c224aff.py').write_bytes(historical)
    shutil.copy2(ROOT/'DXMTIntegration/dxmt.lock.json',metadata/'dxmt.lock.json');shutil.copy2(ROOT/'DXMTIntegration/NOTICE',metadata/'DXMT-NOTICE.txt');shutil.copy2(ROOT/'Vendor/wine.source.json',metadata/'wine.source.json')
    dxmt=json.loads((ROOT/'DXMTIntegration/dxmt.lock.json').read_text());retained=[]
    for identifier,source,url,expected in [
        ('dxmt-source',ROOT/'Runtime/DXMTExperiment/Downloads/dxmt-source.tar.gz',dxmt['sourceArchiveURL'],dxmt['sourceArchiveSHA256']),
        ('dxmt-directx-headers',ROOT/'Runtime/DXMTExperiment/Downloads/directx-headers.tar.gz',dxmt['upstreamSubmodules'][1]['archiveURL'],dxmt['upstreamSubmodules'][1]['archiveSHA256'])]:
        if digest(source)!=expected:raise RuntimeError('Previously retained DXMT source mismatch: '+identifier)
        target=packet/'archives'/(identifier+'.tar.gz');require_space(source.stat().st_size)
        if target.exists() and digest(target)!=expected:raise RuntimeError('Packet retained source changed: '+identifier)
        if not target.exists():shutil.copy2(source,target)
        component={'id':identifier,'filename':target.name};notices=preserve_notices(target,component,packet)
        retained.append({'id':identifier,'sourceURL':url,'archivePath':str(target.relative_to(packet)),'archiveSHA256':expected,'archiveBytes':target.stat().st_size,'notices':notices,'artifactCorrespondenceVerified':False,'licenseApproval':False})
    acquisition=json.loads((packet/'acquisition.json').read_text());inline=[]
    for identifier,entry in acquisition['components'].items():
        if entry.get('status')!='acquired' or entry.get('noticesExtractedCount'):continue
        component=next(c for c in lock['components'] if c['id']==identifier);archive=packet/entry['archivePath'];root=packet/'notices'/identifier;root.mkdir(parents=True,exist_ok=True)
        # Some data notices live inside the data header, not a LICENSE file.
        def header(name,data):
            if b'\x00' in data[:100]:text=data.decode('utf-16',errors='replace')
            else:text=data.decode('utf-8',errors='replace')
            meaningful=bool(re.search(r'copyright|licen[cs]e|permission|public domain|terms of use',text,re.I))
            if not meaningful:return
            target=root/(hashlib.sha256(name.encode()).hexdigest()[:12]+'-inline-header.txt');encoded=text.encode();require_space(len(encoded));target.write_bytes(encoded)
            inline.append({'component':identifier,'archiveMember':name,'headerOnly':True,'sourcePrefixSHA256':hashlib.sha256(data).hexdigest(),'candidateNotice':file_record(target,packet),'licenseScopeConfirmed':False})
        if zipfile.is_zipfile(archive):
            with zipfile.ZipFile(archive) as z:
                for item in z.infolist():
                    if not item.is_dir():
                        with z.open(item) as stream:header(item.filename,stream.read(32768))
        elif tarfile.is_tarfile(archive):
            # Also capture original full MustRead/notice files missed by older recipes.
            extras=preserve_notices(archive,component,packet)
            for notice in extras:inline.append({'component':identifier,'fullCandidateNotice':notice,'licenseScopeConfirmed':False})
            with tarfile.open(archive,mode='r|*') as t:
                for item in t:
                    if item.isfile():header(item.name,t.extractfile(item).read(32768))
        else:
            with archive.open('rb') as stream:header(component['filename'],stream.read(32768))
    # Preserve workflow distinctions: dated release defaults versus nightly overrides.
    mingw=packet/'archives/llvm-mingw-recipes.tar.gz';workflow_dir=metadata/'llvm-mingw-workflows';workflow_dir.mkdir(exist_ok=True);workflow_records=[]
    with tarfile.open(mingw) as t:
        for item in t:
            if item.isfile() and '/.github/workflows/' in item.name:
                target=workflow_dir/Path(item.name).name;data=t.extractfile(item).read();require_space(len(data));target.write_bytes(data);workflow_records.append(file_record(target,packet))
    verification=ROOT/'Evidence/runtime-core-source-acquisition-verification.json'
    if verification.is_file():shutil.copy2(verification,metadata/verification.name)
    atomic_json(packet/'source-lock.json',lock)
    result={'schema':1,'packetID':lock['packetID'],'newlyAcquiredComponentCount':len(lock['components']),'previouslyRetainedDXMTSources':retained,'inlineNoticeCandidates':inline,'llvmMinGWWorkflows':workflow_records,'runtimeSourceSelection':'LLVM15 airconv candidate distinct from LLVM-MinGW23 CRT/libc++/unwind; build recipes are not automatically runtime code','llvmMinGWRefConfidence':'Pinned dated-tag script defaults. Nightly/manual workflow may override refs; actual artifact/cache correspondence is not established.','candidateNoticeScope':'Extracted notices and inline headers require per-component review; no new license approval','artifactCorrespondenceVerified':False,'licenseApproval':False,'recipeSHA256':digest(__file__),'recipeLicense':'GPL-3.0-only','recipeLicenseSHA256':digest(metadata/'READY-GPL-3.0-LICENSE.txt')}
    atomic_json(packet/'catalogue.json',result)
    (packet/'README.txt').write_text('Immutable corresponding-source acquisition packet after finalize. Source archives stay compressed. source-lock.json pins URLs, versions, commits and exact bytes. catalogue.json distinguishes embedded LLVM code candidates, CRT/libc++/unwind candidates and toolchain recipe sources. Notices are candidates for review, not a redistribution approval. All artifact correspondence gates remain false. The fetch recipe is GPL-3.0-only; its complete license is in metadata. Verify with runtime_fetch_core_sources.py --verify --packet PATH. No Apple proprietary framework or SDK is acquired.\n')
    return result

def inventory(packet):
    result={}
    for path in sorted(packet.rglob('*')):
        relative=str(path.relative_to(packet))
        if path.is_symlink():raise RuntimeError('Source packet cannot contain symlinks: '+relative)
        if path.is_file() and relative not in ['manifest.json','finalized.json','.source-acquisition.partial.json']:
            result[relative]={'sha256':digest(path),'bytes':path.stat().st_size}
    return result

def canonical(value):return json.dumps(value,sort_keys=True,separators=(',',':')).encode()
def validate_material(lock,packet):
    receipt=json.loads((packet/'acquisition.json').read_text())
    if not receipt.get('allSourceMaterialAcquired'):raise RuntimeError('Source acquisition is incomplete')
    for c in lock['components']:
        item=receipt['components'].get(c['id'],{});path=packet/item.get('archivePath','absent')
        if item.get('status')!='acquired' or not path.is_file() or digest(path)!=c['archiveSHA256']:raise RuntimeError('Source archive/lock mismatch: '+c['id'])
    if receipt.get('artifactCorrespondenceVerified') or receipt.get('licenseApproval'):raise RuntimeError('Acquisition cannot grant artifact or license approval')

def finalize(lock,packet):
    require_unfinalized(packet);validate_material(lock,packet);catalogue(lock,packet)
    manifest={'schema':1,'packetID':lock['packetID'],'sourceLockSHA256':digest(packet/'source-lock.json'),'recipeSHA256':digest(packet/'metadata/runtime_fetch_core_sources.py'),'recipeLicenseSHA256':digest(packet/'metadata/READY-GPL-3.0-LICENSE.txt'),'artifactCorrespondenceVerified':False,'licenseApproval':False,'files':inventory(packet)}
    fingerprint=hashlib.sha256(canonical(manifest)).hexdigest();atomic_json(packet/'manifest.json',manifest)
    final={'schema':1,'packetID':lock['packetID'],'finalizedUTC':now(),'fingerprint':fingerprint,'manifestSHA256':digest(packet/'manifest.json'),'sourceLockSHA256':manifest['sourceLockSHA256'],'recipeSHA256':manifest['recipeSHA256'],'recipeLicenseSHA256':manifest['recipeLicenseSHA256'],'immutable':True,'artifactCorrespondenceVerified':False,'licenseApproval':False}
    atomic_json(packet/'finalized.json',final);(packet/'.source-acquisition.partial.json').unlink(missing_ok=True)
    result=verify(packet)
    evidence=ROOT/'Evidence/runtime-core-source-acquisition.json';summary=json.loads(evidence.read_text());summary.update(finalized=True,fingerprint=fingerprint,manifestSHA256=final['manifestSHA256'],finalizedMetadataSHA256=digest(packet/'finalized.json'),catalogueSHA256=digest(packet/'catalogue.json'),recipeSHA256=manifest['recipeSHA256'],previouslyRetainedDXMTSourceArchives=2,immutableVerificationPassed=True);atomic_json(evidence,summary)
    return result

def verify(packet,check_current_inputs=True):
    final=json.loads((packet/'finalized.json').read_text());manifest=json.loads((packet/'manifest.json').read_text())
    if final.get('schema')!=1 or final.get('immutable')!=True:raise RuntimeError('Invalid completed source-packet metadata')
    if final.get('artifactCorrespondenceVerified') or final.get('licenseApproval') or manifest.get('artifactCorrespondenceVerified') or manifest.get('licenseApproval'):raise RuntimeError('Source acquisition cannot approve binary/license correspondence')
    if digest(packet/'manifest.json')!=final['manifestSHA256']:raise RuntimeError('Source manifest bytes changed')
    if hashlib.sha256(canonical(manifest)).hexdigest()!=final['fingerprint']:raise RuntimeError('Declared source fingerprint differs')
    for name,key in [('source-lock.json','sourceLockSHA256'),('metadata/runtime_fetch_core_sources.py','recipeSHA256'),('metadata/READY-GPL-3.0-LICENSE.txt','recipeLicenseSHA256')]:
        if digest(packet/name)!=final[key] or manifest[key]!=final[key]:raise RuntimeError('Source lock/recipe/license identity differs: '+name)
    if check_current_inputs and (digest(LOCK)!=final['sourceLockSHA256'] or digest(__file__)!=final['recipeSHA256']):raise RuntimeError('Current lock or verification recipe differs from finalized packet; use retained recipe/lock')
    if inventory(packet)!=manifest['files']:raise RuntimeError('Source packet content fingerprint differs')
    lock=json.loads((packet/'source-lock.json').read_text());validate_material(lock,packet)
    return {'packet':str(packet),'fingerprint':final['fingerprint'],'filesVerified':len(manifest['files']),'verified':True,'artifactCorrespondenceVerified':False,'licenseApproval':False}

def negative_checks(lock,packet):
    before=verify(packet);results={};testroot=PACKETS/('.source-negative-tests-'+uuid.uuid4().hex);testroot.mkdir();(testroot/'.owned-source-tests').write_text('Synthetic APFS copies only\n')
    try:
        for mutation in ['archive','lock','recipe','declared-fingerprint']:
            require_space();clone=testroot/mutation;subprocess.run(['/bin/cp','-cR',str(packet),str(clone)],check=True)
            if mutation=='declared-fingerprint':
                target=clone/'finalized.json';value=json.loads(target.read_text());value['fingerprint']='0'*64;atomic_json(target,value)
            else:
                name={'archive':'archives/wine-11.20.tar.xz','lock':'source-lock.json','recipe':'metadata/runtime_fetch_core_sources.py'}[mutation];target=clone/name
                with target.open('r+b') as f:old=f.read(1);f.seek(0);f.write(bytes([old[0]^1]))
            rejected=False
            try:verify(clone)
            except Exception:rejected=True
            if not rejected:raise RuntimeError('Altered source packet was accepted: '+mutation)
            results[mutation]=True;shutil.rmtree(clone)
        rejected=False
        try:fetch(lock)
        except RuntimeError:rejected=True
        if not rejected:raise RuntimeError('Fetch accepted completed packet overwrite')
        results['completed-fetch-refused']=True
        rejected=False
        try:finalize(lock,packet)
        except RuntimeError:rejected=True
        if not rejected:raise RuntimeError('Finalize overwrote completed source packet')
        results['completed-finalize-refused']=True
        # Retry must not write to an unrelated unmarked partial directory.
        fake=dict(lock);fake['packetID']='source-unmarked-test-'+uuid.uuid4().hex;partial=PACKETS/fake['packetID'];partial.mkdir()
        try:
            rejected=False
            try:fetch(fake)
            except RuntimeError:rejected=True
            if not rejected:raise RuntimeError('Unmarked partial source packet was accepted')
            results['unmarked-partial-refused']=True
        finally:shutil.rmtree(partial)
        after=verify(packet)
        if before!=after:raise RuntimeError('Negative test changed original source packet')
        report={'schema':1,'passed':True,'checks':results,'originalFingerprintUnchanged':True,'fingerprint':before['fingerprint'],'runtimeModified':False,'artifactCorrespondenceVerified':False,'licenseApproval':False};atomic_json(ROOT/'Evidence/runtime-core-source-negative-checks.json',report);return report
    finally:
        if (testroot/'.owned-source-tests').is_file():shutil.rmtree(testroot)

def main():
    p=argparse.ArgumentParser(description=__doc__);p.add_argument('--resolve-only',action='store_true');p.add_argument('--finalize',action='store_true');p.add_argument('--verify',action='store_true');p.add_argument('--negative-checks',action='store_true');p.add_argument('--packet',type=Path);args=p.parse_args();lock=resolve();packet=(args.packet or PACKETS/lock['packetID']).resolve()
    if args.resolve_only:print(json.dumps({'lock':str(LOCK),'components':len(lock['components']),'packetID':lock['packetID']},indent=2));return 0
    if args.verify:result=verify(packet)
    elif args.negative_checks:result=negative_checks(lock,packet)
    elif args.finalize:result=finalize(lock,packet)
    else:return fetch(lock)
    print(json.dumps(result,indent=2));return 0
if __name__=='__main__':raise SystemExit(main())
