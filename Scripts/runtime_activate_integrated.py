#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-only
"""Prepare/check/rollback integrated PROJECT config proposals. No activate command.

UserRuntimes, prefixes, providers and the immutable E5/68 inputs are never edited.
A passing check is a review receipt, not permission to promote project pointers.
"""
import argparse, contextlib, copy, fcntl, hashlib, json, os, pathlib, stat, subprocess, uuid
ROOT=pathlib.Path(__file__).resolve().parents[1]
CONFIGS=('runtime.json','evaluation-runtime.json')
PROPOSALS=('candidate-integrated-runtime.json','candidate-integrated-evaluation-runtime.json')
NATIVE='ready-native-renderer-9f6573d3f72d8ef99744'
CASES={'automatic-no-private':True,'game-input':False,'automatic-private':False,'force-private':True,'automatic-dxmt':True}


def sha(path):
    with path.open('rb')as f:return hashlib.file_digest(f,'sha256').hexdigest()

def encoded(value):return (json.dumps(value,indent=2,sort_keys=True)+'\n').encode()

def owned(path,directory=False):
    s=path.lstat()
    if s.st_uid!=os.geteuid() or not (stat.S_ISDIR(s.st_mode)if directory else stat.S_ISREG(s.st_mode)) or(not directory and s.st_nlink!=1):raise ValueError('Unsafe integrated transaction path: '+str(path))
    return s

def read(path):owned(path);return path.read_bytes()

def load(path):return json.loads(read(path))

def sync_dir(path):
    fd=os.open(path,os.O_RDONLY|os.O_CLOEXEC)
    try:os.fsync(fd)
    finally:os.close(fd)

def atomic(path,data,mode=0o600):
    if path.exists()or path.is_symlink():owned(path)
    temp=path.with_name('.'+path.name+'.'+uuid.uuid4().hex+'.pending')
    try:
        with temp.open('xb')as f:os.chmod(temp,mode);f.write(data);f.flush();os.fsync(f.fileno())
        os.replace(temp,path);sync_dir(path.parent)
    finally:temp.unlink(missing_ok=True)

def policy(config):
    config['evaluationModeEnabled']=False;config['consumerAppleEnabled']=False;config['proprietaryDistributionEnabled']=False
    apple=config.setdefault('appleOptional',{})
    for key in ['enabled','enabledForConsumerPlay','publicRedistributionEnabled','applicationBundleInclusionEnabled','productDefaultEnabled']:apple[key]=False
    apple['sourceOpen']=False

def compose(base,evaluation,native,inputs):
    if 'd3dMetal'in base.get('verifiedEngines',[])or'd3dMetal'in base.get('engineDLLs',{}):raise ValueError('E6 source must be the open, non-evaluation configuration')
    normal=copy.deepcopy(base)
    normal.update(native)
    normal['runtimeID']=base['runtimeID']+'+'+native['nativeRendererID']
    normal['integrationInputs']=copy.deepcopy(inputs)
    policy(normal)
    result=copy.deepcopy(normal)
    # Preserve only the pre-existing d3dMetal engine entries, never the old open bindings.
    for key,value in evaluation.items():
        if key.startswith('engine')and isinstance(value,dict)and 'd3dMetal'in value:result.setdefault(key,{})['d3dMetal']=copy.deepcopy(value['d3dMetal'])
    if 'd3dMetal'not in evaluation.get('evaluationOnlyEngines',[])or'd3dMetal'not in evaluation.get('verifiedEngines',[]):raise ValueError('Existing explicit Apple evaluation fragment is required')
    result['verifiedEngines']=normal['verifiedEngines']+['d3dMetal']
    result.setdefault('engineAPIs',{})['d3dMetal']=copy.deepcopy(evaluation['engineAPIs']['d3dMetal'])
    result['appleOptional']=copy.deepcopy(evaluation['appleOptional'])
    result['evaluationOnlyEngines']=['d3dMetal']
    result['evaluationCapabilityEvidence']={'d3dMetal':copy.deepcopy(evaluation['evaluationCapabilityEvidence']['d3dMetal'])}
    result['runtimeID']=normal['runtimeID']+'+'+evaluation['engineProviderIDs']['d3dMetal']
    policy(result)
    if 'd3dMetal'in result.get('overlayInputCapture',{}).get('engineProviders',{}):raise ValueError('WineCX cannot inherit E6 overlay input capture')
    return normal,result


class Transaction:
    def __init__(self,root=ROOT,*,fixture=False):
        self.root=pathlib.Path(root)
        if self.root.resolve()!=self.root.absolute():raise ValueError('Project root aliases rejected')
        if fixture:owned(self.root/'.ready-integrated-runtime-fixture')
        elif self.root!=ROOT:raise ValueError('Only this project can be prepared')
        self.runtime=self.root/'Runtime';owned(self.runtime,True)
        if self.runtime.resolve()!=self.runtime.absolute():raise ValueError('Runtime directory cannot be a symlink')
        self.transactions=self.runtime/'IntegratedTransactions'
        if not self.transactions.exists():self.transactions.mkdir(mode=0o700);sync_dir(self.runtime)
        owned(self.transactions,True)
        self.fixture=fixture
    @contextlib.contextmanager
    def lease(self):
        path=self.transactions/'operation.lock';fd=os.open(path,os.O_CREAT|os.O_RDWR|os.O_NOFOLLOW|os.O_CLOEXEC,0o600)
        try:
            s=os.fstat(fd)
            if not stat.S_ISREG(s.st_mode)or s.st_uid!=os.geteuid():raise ValueError('Unsafe integration lock')
            fcntl.flock(fd,fcntl.LOCK_EX|fcntl.LOCK_NB);yield
        finally:os.close(fd)
    def directory(self,identifier=None):
        if identifier is None:identifier=load(self.transactions/'current.json')['transaction']
        if str(uuid.UUID(identifier))!=identifier:raise ValueError('Invalid transaction identity')
        directory=self.transactions/identifier;owned(directory,True)
        if directory.resolve()!=directory.absolute():raise ValueError('Transaction symlink rejected')
        return directory
    def journal(self,directory):
        value=load(directory/'journal.json')
        if value.get('schema')!=1 or value.get('state')not in ['prepared','rolling-back','rolled-back']:raise ValueError('Invalid integration journal')
        if value.get('transaction')!=directory.name or [x.get('name')for x in value.get('configs',[])]!=list(CONFIGS):raise ValueError('Invalid journal scope')
        for i,record in enumerate(value['configs']):
            if record['beforeImage']!='before-'+CONFIGS[i]or record['afterImage']!='after-'+CONFIGS[i]:raise ValueError('Invalid snapshot path')
            if record['beforeExists']and sha(directory/record['beforeImage'])!=record['beforeSHA256']:raise ValueError('Before-image changed')
            if sha(directory/record['afterImage'])!=record['afterSHA256']:raise ValueError('After-image changed')
            if not isinstance(record['mode'],int)or record['mode']&~0o777:raise ValueError('Invalid config mode')
        return value
    def proposals(self):
        source=self.runtime/'candidate-xinput-v2.json';evaluation=self.runtime/'evaluation-runtime.json'
        native_root=self.runtime/'Providers'/NATIVE;manifest=native_root/'native-renderer-manifest.json';validation=self.root/'Evidence/runtime-native-renderer-validation.json'
        native={'kosmicNativeICD':str(native_root/'icd/kosmic-arm64.json'),'nativeVulkanLibrary':str(native_root/'lib/libvulkan.1.dylib'),'nativeRendererID':load(manifest)['identity'],'nativeRendererManifestPath':str(manifest),'nativeRendererManifestSHA256':sha(manifest),'nativeRendererValidationPath':str(validation),'nativeRendererValidationSHA256':sha(validation)}
        inputs={'sourceCandidate':'Runtime/candidate-xinput-v2.json','sourceCandidateSHA256':sha(source),'evaluationFragment':'Runtime/evaluation-runtime.json','evaluationFragmentSHA256':sha(evaluation)}
        return compose(load(source),load(evaluation),native,inputs)
    def prepare(self):
        with self.lease():
            values=self.proposals();afters=[encoded(x)for x in values]
            current=self.transactions/'current.json'
            if current.exists():
                directory=self.directory();previous=self.journal(directory)
                if previous['state']!='rolled-back':
                    if [r['afterSHA256']for r in previous['configs']]!=[hashlib.sha256(x).hexdigest()for x in afters]:raise ValueError('Pending transaction must be reviewed/rolled back before changing proposals')
                    for i,record in enumerate(previous['configs']):
                        live=self.runtime/record['name']
                        if sha(self.runtime/PROPOSALS[i])!=record['afterSHA256']:raise ValueError('Existing proposal changed; preserve it for review')
                        if record['beforeExists'] and (sha(live)!=record['beforeSHA256']or stat.S_IMODE(owned(live).st_mode)!=record['mode']):raise ValueError('Project configuration changed since prepare')
                        if not record['beforeExists'] and (live.exists()or live.is_symlink()):raise ValueError('Project configuration appeared since prepare')
                    return directory
            identifier=str(uuid.uuid4());directory=self.transactions/identifier;directory.mkdir(mode=0o700);sync_dir(self.transactions)
            records=[]
            for i,name in enumerate(CONFIGS):
                live=self.runtime/name;exists=live.exists()or live.is_symlink();data=read(live)if exists else b'';mode=stat.S_IMODE(owned(live).st_mode)if exists else 0o600
                before='before-'+name;after='after-'+name
                if exists:atomic(directory/before,data)
                atomic(directory/after,afters[i])
                records.append({'name':name,'beforeExists':exists,'beforeImage':before,'beforeSHA256':hashlib.sha256(data).hexdigest()if exists else None,'afterImage':after,'afterSHA256':hashlib.sha256(afters[i]).hexdigest(),'mode':mode})
            if records[1]['beforeSHA256']!=values[0]['integrationInputs']['evaluationFragmentSHA256']:raise ValueError('Evaluation fragment changed during prepare')
            journal={'schema':1,'transaction':identifier,'state':'prepared','configs':records,'activationImplemented':False,'userConfigurationsOrPrefixesTouched':False}
            atomic(directory/'journal.json',encoded(journal))
            for i,name in enumerate(PROPOSALS):atomic(self.runtime/name,afters[i])
            atomic(self.transactions/'current.json',encoded({'transaction':identifier}))
            return directory
    def check(self,identifier=None):
        with self.lease():
            directory=self.directory(identifier);journal=self.journal(directory)
            if journal['state']!='prepared':raise ValueError('Only a prepared transaction can be checked')
            normal,evaluation=[load(directory/r['afterImage'])for r in journal['configs']]
            checks={}
            def gate(name,function):
                try:checks[name]={'passed':True,'evidence':function()}
                except Exception as error:checks[name]={'passed':False,'reason':str(error)}
            def unchanged():
                expected=[encoded(x)for x in self.proposals()]
                if [hashlib.sha256(x).hexdigest()for x in expected]!=[r['afterSHA256']for r in journal['configs']]:raise ValueError('Composition/input changed after prepare')
                for i,r in enumerate(journal['configs']):
                    live=self.runtime/r['name'];present=live.exists()or live.is_symlink()
                    if present!=r['beforeExists']or(present and(sha(live)!=r['beforeSHA256']or stat.S_IMODE(owned(live).st_mode)!=r['mode'])):raise ValueError('Active project config changed since before-image')
                    if sha(self.runtime/PROPOSALS[i])!=r['afterSHA256']:raise ValueError('Proposal changed after prepare')
                return {'projectPointersStillBeforeImages':True,'sourceE6BindingsPreserved':True,'nativeIndependent':normal['vulkanLibrary']!=normal['nativeVulkanLibrary']}
            gate('composition-and-before-images',unchanged)
            gate('controller-capability',lambda:check_controller(self.root,normal))
            gate('native-independent-proof',lambda:check_native(self.root,normal))
            gate('production-five-case-E2E',lambda:check_e2e(self.root,normal))
            gate('Core30',lambda:check_core(self.root))
            gate('UI-signatures',lambda:check_ui(self.root))
            gate('evaluation-consumer-policy',lambda:check_policy(normal,evaluation))
            result={'schema':1,'checkerScriptSHA256':sha(pathlib.Path(__file__)),'transaction':directory.name,'candidateConfigHashes':{r['name']:r['afterSHA256']for r in journal['configs']},'readyForRootReview':all(x['passed']for x in checks.values()),'checks':checks,'activationPerformed':False,'activationImplemented':False,'userConfigurationsOrPrefixesTouched':False}
            receipt=directory/('check-'+uuid.uuid4().hex+'.json');atomic(receipt,encoded(result));journal['lastCheck']={'file':receipt.name,'sha256':sha(receipt)};atomic(directory/'journal.json',encoded(journal))
            return result
    def rollback(self,identifier=None,checkpoint=None):
        if checkpoint and not self.fixture:raise ValueError('Fault callback is fixture-only')
        with self.lease():
            directory=self.directory(identifier);journal=self.journal(directory)
            # Preflight both configs and all snapshots before the first write.
            for r in journal['configs']:
                live=self.runtime/r['name'];present=live.exists()or live.is_symlink()
                if present:
                    mode=stat.S_IMODE(owned(live).st_mode);digest=sha(live)
                    if digest not in [r['beforeSHA256'],r['afterSHA256']]or mode!=r['mode']:raise ValueError('Unknown project configuration preserved; rollback refused')
                elif r['beforeExists']:raise ValueError('Project configuration unexpectedly missing; preserved snapshots')
            journal['state']='rolling-back';atomic(directory/'journal.json',encoded(journal))
            for i,r in enumerate(journal['configs']):
                live=self.runtime/r['name']
                if r['beforeExists']:
                    if sha(live)!=r['beforeSHA256']:atomic(live,read(directory/r['beforeImage']),r['mode'])
                elif live.exists():live.unlink();sync_dir(self.runtime)
                if checkpoint:checkpoint('rollback-restored',i+1)
            journal['state']='rolled-back';atomic(directory/'journal.json',encoded(journal))
            return {'state':'rolled-back','transaction':directory.name,'snapshotsRetained':True,'userConfigurationsOrPrefixesTouched':False}


def check_policy(normal,evaluation):
    for config in [normal,evaluation]:
        if config.get('evaluationModeEnabled')is not False or config.get('consumerAppleEnabled')is not False or config.get('proprietaryDistributionEnabled')is not False:raise ValueError('Evaluation/consumer/proprietary mode must remain disabled')
        if any(config['appleOptional'].get(k)is not False for k in ['enabled','enabledForConsumerPlay','publicRedistributionEnabled','applicationBundleInclusionEnabled','productDefaultEnabled','sourceOpen']):raise ValueError('Apple policy widened')
    if normal.get('overlayInputCapture')!=evaluation.get('overlayInputCapture')or'd3dMetal'in evaluation['overlayInputCapture']['engineProviders']:raise ValueError('WineCX input capture must remain excluded')
    return {'evaluationModeEnabled':False,'consumerAppleEnabled':False,'proprietaryRedistributionEnabled':False,'WineCXCaptureApplied':False}

def check_controller(root,config):
    descriptor=config['overlayInputCapture'];path=pathlib.Path(descriptor['manifestPath']);cap=load(path)
    if sha(path)!=descriptor['manifestSHA256']or cap['protocolVersion']!=2:raise ValueError('E6 capability identity mismatch')
    for key in ['protocolVersion','providerID','engineProviders','providers']:
        if descriptor[key]!=cap[key]:raise ValueError('E6 binding changed: '+key)
    if cap['requiredEnvironment']!={'M1L_XINPUT_CAPTURE':'1'}or'd3dMetal'in cap['engineProviders']:raise ValueError('Invalid E6 opt-in scope')
    for provider in cap['providers'].values():
        wine=pathlib.Path(provider['wineRoot'])
        if sha(wine/'bin/wine')!=provider['wineBinarySHA256']or sha(wine/'bin/ready-wine')!=provider['wineLauncherSHA256']:raise ValueError('E6 Wine binary/launcher changed')
        for relative,expected in provider['payloadHashes'].items():
            if sha(wine/'lib/wine'/relative)!=expected:raise ValueError('E6 production payload changed')
        for relative,target in provider['unixAliases'].items():
            if os.readlink(wine/'lib/wine'/relative)!=target:raise ValueError('E6 alias changed')
    evidence=path.parent/'evidence';names={'apiMatrixSHA256':'runtime-xinput-capture.json','realOverlaySHA256':'runtime-xinput-real-overlay.json','buildSHA256':'runtime-xinput-build.json','nativeOptInSHA256':'runtime-xinput-e6-native-optin.json'}
    for key,name in names.items():
        if sha(evidence/name)!=cap['proofs'][key]:raise ValueError('E6 retained proof changed')
    build=load(evidence/names['buildSHA256'])
    if build['productionContainsTestBackend']is not False or not all(x['exportsEqual']for x in build['productionExportParity']):raise ValueError('E6 production export/test-backend gate failed')
    return {'manifestSHA256':sha(path),'providerID':cap['providerID'],'physicalControllerVerified':cap['physicalControllerVerified'],'requiredOptIn':cap['requiredEnvironment']}

def check_native(root,config):
    manifest=pathlib.Path(config['nativeRendererManifestPath']);m=load(manifest);provider=manifest.parent;proof=pathlib.Path(config['nativeRendererValidationPath']);p=load(proof)
    if sha(manifest)!=config['nativeRendererManifestSHA256']or sha(proof)!=config['nativeRendererValidationSHA256']or p['candidateManifestSHA256']!=sha(manifest)or p['candidateFingerprint']!=m['fingerprint']:raise ValueError('Independent native proof binding changed')
    if p['allPassed']is not True or p['candidateUnchanged']is not True or p['architecture']!='arm64'or p['advertisedFeaturesModified']is not False:raise ValueError('Native proof is not verified source ARM64')
    if p['candidate']!=str(provider)or len(p['tests'])<19 or not all(x['passed']and not x['unexpectedImages']for x in p['tests'].values())or len(p['sandboxControls'])!=5 or not all(x['passed']for x in p['sandboxControls'].values()):raise ValueError('Native sandbox matrix incomplete')
    if not any(x.get('readbackVerified')and x.get('transferBytes')==4096 for x in p['tests']['buffer']['observations']):raise ValueError('Native GPU transfer proof missing')
    if not any(x.get('nativeARM64')and x.get('shaderRasterizationVerified')and x.get('pixel')==[64,128,191,255]and x.get('presentedFrames',0)>=60 for x in p['tests']['shader-present']['observations']):raise ValueError('Native shader/readback/presentation proof missing')
    if len(m['nativeBinaries'])!=4 or any(x.get('format')!='Mach-O'or x.get('architectures')!=['arm64']for x in m['nativeBinaries'].values()):raise ValueError('Native provider is not the expected independent ARM64 closure')
    for relative,record in m['files'].items():
        target=provider/relative
        if 'sha256'in record:
            if sha(target)!=record['sha256']:raise ValueError('Native candidate file changed')
        elif os.readlink(target)!=record['symlink']:raise ValueError('Native alias changed')
    for source,digest in p['probeSources'].items():
        if sha(root/source)!=digest:raise ValueError('Native probe source changed')
    if config['kosmicNativeICD']!=str(provider/'icd/kosmic-arm64.json')or config['nativeVulkanLibrary']!=str(provider/'lib/libvulkan.1.dylib'):raise ValueError('Native path mismatch')
    return {'manifestSHA256':sha(manifest),'validationSHA256':sha(proof),'nativeCases':len(p['tests']),'sandboxControls':5,'runtime68X64BindingsChanged':False}

def check_e2e(root,config):
    path=root/'Evidence/controller-policy-e2e.json';p=load(path);build_path=root/'Evidence/controller-policy-e2e-build.json';b=load(build_path)
    if p.get('passed')is not True or p.get('productionControllerDLLsUsed')is not True or p.get('testControllerDeviceBackendUsed')is not False or p.get('testControllerBackendUsed')is not False or p.get('immutableInputsUnchanged')is not True:raise ValueError('Actual production controller E2E is required')
    if p['candidateSHA256']!=config['integrationInputs']['sourceCandidateSHA256']:raise ValueError('E2E tested another E6 source config')
    if len(p['cases'])!=5 or {x['case']for x in p['cases']}!=set(CASES):raise ValueError('All five production policy cases are required')
    for case in p['cases']:
        observation=case['windowsObservation'];expected=CASES[case['case']]
        if case['passed']is not True or case['keeperReleasedLease']is not True or case['privateDLLBefore']!=case['privateDLLAfter']or observation['captureFlag']!=('1'if expected else'0')or observation['testBackendExportPresent']is not False or observation['testDeviceBackendLoaded']is not False:raise ValueError('Production case/lease/private-DLL observation failed')
        if sha(root/case['retainedLog'])!=case['logSHA256']:raise ValueError('Production case log changed')
    if p['productionModuleHashesBefore']!=p['productionModuleHashesAfter']:raise ValueError('Production modules changed during E2E')
    for filename,digest in p['productionModuleHashesAfter'].items():
        if sha(pathlib.Path(filename))!=digest:raise ValueError('Tested production input changed')
    for filename,digest in b['sources'].items():
        if sha(root/filename)!=digest:raise ValueError('E2E source changed after its build')
    if sha(root/'Build/ReadyControllerPolicyProbe')!=b['harnessSHA256']or sha(root/'Build/libReadyOverlay.dylib')!=p['overlaySHA256']:raise ValueError('E2E harness/overlay changed')
    for filename,digest in b['coreModuleHashes'].items():
        if sha(pathlib.Path(filename))!=digest:raise ValueError('E2E Core module changed')
    archives=[pathlib.Path(x)for command in b['commands']for x in command if str(x).endswith('/libLauncherCore.a')]
    if not archives or sha(archives[-1])!=b['coreArchiveSHA256']:raise ValueError('E2E Core archive changed')
    return {'reportSHA256':sha(path),'buildReportSHA256':sha(build_path),'productionControllerDLLsUsed':True,'testDeviceBackendUsed':False,'physicalControllerVerified':p['physicalControllerVerified'],'cases':5}

def check_core(root):
    path=root/'Evidence/core-probe.json';value=load(path)
    if value.get('pass')is not True or len(value['checks'])<30 or not all(x['status']=='pass'for x in value['checks']):raise ValueError('Core30 passing report required')
    newest=max(p.stat().st_mtime_ns for p in (root/'Sources/LauncherCore').glob('*.swift'))
    if path.stat().st_mtime_ns<newest:raise ValueError('Core report predates current Core sources')
    return {'reportSHA256':sha(path),'checks':len(value['checks'])}

def check_ui(root):
    app=root/'Build/ready.app';support=app/'Contents/Resources/ReadySupport/Build';paths=[app,support/'ReadySessionHost',support/'libReadyOverlay.dylib']
    for path in paths:
        result=subprocess.run(['/usr/bin/codesign','--verify','--strict',str(path)],capture_output=True,text=True)
        if result.returncode:raise ValueError('UI/helper code signature verification failed: '+str(path))
    if sha(support/'libReadyOverlay.dylib')!=sha(root/'Build/libReadyOverlay.dylib'):raise ValueError('Bundled overlay differs from production E2E overlay')
    main=app/'Contents/MacOS/ready';sources=[*list((root/'Sources/M1Launcher').glob('*.swift')),*list((root/'Sources/LauncherCore').glob('*.swift'))]
    if main.stat().st_mtime_ns<max(p.stat().st_mtime_ns for p in sources):raise ValueError('UI bundle predates current launcher/Core sources')
    return {'appExecutableSHA256':sha(main),'sessionHostSHA256':sha(support/'ReadySessionHost'),'overlaySHA256':sha(support/'libReadyOverlay.dylib'),'signaturesVerified':True}

def main():
    p=argparse.ArgumentParser(description=__doc__);p.add_argument('operation',choices=['prepare','check','rollback']);p.add_argument('--transaction');a=p.parse_args();t=Transaction()
    if a.operation=='prepare':print(json.dumps({'prepared':str(t.prepare()),'activationImplemented':False},indent=2))
    elif a.operation=='rollback':print(json.dumps(t.rollback(a.transaction),indent=2))
    else:
        result=t.check(a.transaction);print(json.dumps(result,indent=2));sys_exit=0 if result['readyForRootReview']else 1
        raise SystemExit(sys_exit)
if __name__=='__main__':main()
