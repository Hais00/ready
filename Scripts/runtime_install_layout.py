#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-only
"""Derive an install layout from immutable integrated runtime objects.

The transaction owner stores/copies objects. This module writes only new staged
views and metadata. Static verification never claims relocated GPU/API success.
"""
import ctypes,errno,hashlib,json,os,shutil,stat
from pathlib import Path
ROOT=Path(__file__).resolve().parents[1]
STAGE_MARKER='.ready-runtime-install-stage'
DESTINATIONS={'wine-base':'components/base/wine','wine-dxmt':'components/dxmt/wine','support68':'components/support68','native-arm64':'components/native-arm64','origin-meta':'origin'}
SCALARS=('wine','wineServer','wineBoot','kosmicICD','moltenICD','vulkanLibrary','builtin32Directory','wineBinary','kosmicNativeICD','immutableRuntimeSet','sourceDependencyPrefix','nativeVulkanLibrary','nativeRendererManifestPath','nativeRendererValidationPath')
MAPS=('engineDLLs','engineDLLs32','engineSearchPaths','engineWineBinaries','engineWineServers','engineBootstrap32Dirs','engineBuiltin32Dirs')
SUPPORT=('dependency-root','vulkan','kosmic-x64','molten','dxvk','dxvk-x86','vkd3d','vkd3d-x86')

def encoded(value):return json.dumps(value,sort_keys=True,separators=(',',':'),ensure_ascii=False).encode('utf-8')
def sha(path):
    with Path(path).open('rb') as f:return hashlib.file_digest(f,'sha256').hexdigest()
def fingerprint(value):return hashlib.sha256(encoded(value)).hexdigest()
def safe_relative(value):
    if not isinstance(value,str) or not value or value.startswith('/') or '\\' in value or '\0' in value or any(p in ('','.','..') for p in value.split('/')):raise ValueError('Invalid relative layout path')
    return Path(value)
def json_read(path):return json.loads(Path(path).read_text())
def write_new(path,data,mode=0o600):
    path=Path(path);path.parent.mkdir(parents=True,exist_ok=True,mode=0o700)
    fd=os.open(path,os.O_CREAT|os.O_EXCL|os.O_WRONLY|os.O_NOFOLLOW,mode)
    with os.fdopen(fd,'wb') as f:f.write(data);f.flush();os.fsync(f.fileno())
def write_json(path,value):write_new(path,(json.dumps(value,indent=2,sort_keys=True,ensure_ascii=False)+'\n').encode())
def record(path,root):
    relative=str(path.relative_to(root));info=path.lstat()
    if stat.S_ISLNK(info.st_mode):
        target=os.readlink(path)
        if os.path.isabs(target) or not path.resolve(strict=True).is_relative_to(root.resolve()):raise ValueError('Unconfined component alias: '+relative)
        return {'kind':'symlink','target':target}
    if not stat.S_ISREG(info.st_mode):raise ValueError('Special component file: '+relative)
    return {'kind':'file','sha256':sha(path),'mode':stat.S_IMODE(info.st_mode),'bytes':info.st_size}
def inventory(root,selection=None,ignore=()):
    root=Path(root);paths=[]
    if selection is None:paths=list(root.rglob('*'))
    else:
        for rel in selection:
            item=root/safe_relative(rel)
            if item.is_symlink() or item.is_file():paths.append(item)
            elif item.is_dir():paths.extend(item.rglob('*'))
            else:raise ValueError('Selected source missing: '+str(item))
    result={}
    for path in sorted(set(paths)):
        rel=str(path.relative_to(root))
        if rel in ignore:continue
        if path.is_symlink() or path.is_file():result[rel]=record(path,root)
    return result

def make_plan(config_path):
    config_path=Path(config_path).resolve(strict=True);cfg=json_read(config_path)
    if cfg.get('pathFormat'):raise ValueError('Initial integrated origin configuration must be absolute')
    if cfg.get('evaluationModeEnabled') is not False:raise ValueError('Open installation cannot enable evaluation')
    capture=cfg['overlayInputCapture'];cap_path=Path(capture['manifestPath']).resolve(strict=True);cap=json_read(cap_path)
    if capture.get('protocolVersion')!=2 or sha(cap_path)!=capture['manifestSHA256']:raise ValueError('Original controller capability changed')
    for key in ['protocolVersion','providerID','engineProviders','providers']:
        if capture[key]!=cap[key]:raise ValueError('Original controller descriptor differs')
    components=[]
    def component(role,source,selection=None):
        source=Path(source).resolve(strict=True);files=inventory(source,selection)
        value={'id':fingerprint(files),'role':role,'sourceRoot':str(source),'destination':DESTINATIONS[role],'files':files};components.append(value);return value
    for role,key in [('wine-base','base'),('wine-dxmt','dxmt')]:component(role,cap['providers'][key]['wineRoot'])
    support=Path(cfg['immutableRuntimeSet']).resolve(strict=True);component('support68',support,[name for name in SUPPORT if (support/name).exists()])
    native_manifest=Path(cfg['nativeRendererManifestPath']).resolve(strict=True);component('native-arm64',native_manifest.parent)
    # Explicit source metadata only. Never recursively inventory the project root.
    meta={config_path,cap_path,cap_path.parent/'manifest.json',support/'source-generation.json',Path(cfg['nativeRendererValidationPath']).resolve(strict=True)}
    for directory in [cap_path.parent/'evidence',cap_path.parent/'notices']:
        if directory.is_dir():meta.update(p for p in directory.rglob('*') if p.is_file() and not p.is_symlink())
    for key in ['kosmicICD','moltenICD']:meta.add(Path(cfg[key]).resolve(strict=True))
    common=Path(os.path.commonpath([str(p.parent) for p in meta])).resolve(strict=True)
    origins=component('origin-meta',common,sorted(str(p.relative_to(common)) for p in meta))
    origin_refs={str(p):str(Path('origin')/p.relative_to(common)) for p in sorted(meta)}
    source={'path':str(config_path),'sha256':sha(config_path),'document':cfg}
    identity={'sourceConfigSHA256':source['sha256'],'components':[{k:c[k] for k in ['id','role','destination']} for c in components],'recipeSHA256':sha(__file__),'layoutVersion':1}
    plan={'schema':1,'kind':'integrated-runtime-install-layout-plan','derivationID':fingerprint(identity),'sourceConfig':source,'components':components,'originRefs':origin_refs,'icdInputs':{key:{'path':cfg[key],'sha256':sha(cfg[key]),'document':json_read(cfg[key])} for key in ['kosmicICD','moltenICD']},'recipeSHA256':sha(__file__),'identityInputs':identity,'controllerOrigin':{'providerID':cap['providerID'],'manifestSHA256':sha(cap_path),'document':cap},'nativeOrigin':{'providerID':cfg['nativeRendererID'],'manifestSHA256':sha(native_manifest),'validationSHA256':cfg['nativeRendererValidationSHA256'],'validationCandidatePathHistorical':json_read(cfg['nativeRendererValidationPath']).get('candidate')},'binaryDistributionApproved':False,'placementValidationRequired':True,'staleWineRpathsPreserved':True,'minimumMacOS':'27.0'}
    if sha(config_path)!=source['sha256']:raise ValueError('Origin configuration changed while planning')
    return plan

def copy_file(source,target):
    target.parent.mkdir(parents=True,exist_ok=True,mode=0o700)
    if target.exists() or target.is_symlink():raise ValueError('View destination already exists')
    clone=getattr(ctypes.CDLL(None,use_errno=True),'clonefile',None)
    if clone is not None:
        clone.argtypes=[ctypes.c_char_p,ctypes.c_char_p,ctypes.c_uint];clone.restype=ctypes.c_int
        if clone(os.fsencode(source),os.fsencode(target),1)==0:return 'clone'  # CLONE_NOFOLLOW
    shutil.copy2(source,target,follow_symlinks=False);return 'copy'
def copy_view(source,target,files):
    if target.exists() or target.is_symlink():raise ValueError('Operational view must be new')
    target.mkdir(parents=True,mode=0o700);counts={'clone':0,'copy':0,'symlink':0}
    for rel,wanted in sorted(files.items()):
        relpath=safe_relative(rel);src=source/relpath;dst=target/relpath
        if record(src,source)!=wanted:raise ValueError('Raw object differs: '+rel)
        dst.parent.mkdir(parents=True,exist_ok=True,mode=0o700)
        if wanted['kind']=='symlink':dst.symlink_to(wanted['target']);counts['symlink']+=1
        else:counts[copy_file(src,dst)]+=1
    if inventory(target)!=files:raise ValueError('Operational copy differs from object')
    return counts

def launcher(role):
    return ('''#!/bin/sh
# SPDX-License-Identifier: GPL-3.0-only
# Derived installation launcher; original wrapper remains in origin/.
set -u
READY_WINE_ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd -P)
READY_INSTALL_ROOT=$(CDPATH= cd -- "$READY_WINE_ROOT/../../.." && pwd -P)
READY_SUPPORT="$READY_INSTALL_ROOT/components/support68"
READY_DEPS="$READY_SUPPORT/dependency-root"
export DYLD_LIBRARY_PATH="$READY_SUPPORT/vulkan:$READY_DEPS/lib"
export DYLD_FALLBACK_LIBRARY_PATH="$DYLD_LIBRARY_PATH"
export P11_MODULE_PATH="$READY_DEPS/lib/pkcs11"
export P11_PACKAGE_CONFIG_MODULES="$READY_DEPS/share/p11-kit/modules"
export P11_SYSTEM_CONFIG_MODULES="$READY_DEPS/etc/pkcs11/modules"
export WINESERVER="$READY_WINE_ROOT/bin/wineserver"
unset DYLD_INSERT_LIBRARIES DYLD_FRAMEWORK_PATH DYLD_FALLBACK_FRAMEWORK_PATH
if [ "${READY_DYLD_DIAGNOSTICS:-0}" = 1 ]; then export DYLD_PRINT_LIBRARIES=1; fi
if [ -n "${READY_NATIVE_AUDIT_LIBRARY:-}" ] && [ -f "$READY_NATIVE_AUDIT_LIBRARY" ]; then export DYLD_INSERT_LIBRARIES="$READY_NATIVE_AUDIT_LIBRARY"; fi
if [ -n "${READY_OVERLAY_LIBRARY:-}" ] && [ -f "$READY_OVERLAY_LIBRARY" ]; then export DYLD_INSERT_LIBRARIES="$READY_OVERLAY_LIBRARY"; fi
case "${1:-}" in --version|--help) exec "$READY_WINE_ROOT/bin/wine" "$@" ;; esac
if [ -z "${WINEPREFIX:-}" ]; then echo 'An explicit per-game/per-profile WINEPREFIX is required' >&2; exit 64; fi
trap '"$READY_WINE_ROOT/bin/wineserver" -k >/dev/null 2>&1 || true' TERM INT HUP
"$READY_WINE_ROOT/bin/wine" "$@" &
READY_CHILD=$!
READY_STATUS=0
wait "$READY_CHILD" || READY_STATUS=$?
"$READY_WINE_ROOT/bin/wineserver" -w
exit "$READY_STATUS"
''').encode()

def source_relative(value,plan):
    path=Path(value)
    if not path.is_absolute():raise ValueError('Origin operational path is not absolute')
    for component in sorted(plan['components'],key=lambda c:len(c['sourceRoot']),reverse=True):
        source=Path(component['sourceRoot'])
        if path.is_relative_to(source):
            rel=str(path.relative_to(source))
            if rel=='.':return component['destination']
            if rel in component['files'] or any(k.startswith(rel+'/') for k in component['files']):return str(Path(component['destination'])/rel)
    raise ValueError('Operational path leaves selected objects: '+value)

def materialize(stage_root,objects,plan):
    root=Path(stage_root);root.mkdir(parents=True,exist_ok=True,mode=0o700)
    for name in ['runtime.json','controller-capability.json','derivation-manifest.json']:
        if (root/name).exists() or (root/name).is_symlink():raise ValueError('Derived layout already exists')
    counts={}
    for component in plan['components']:
        source=Path(objects[component['id']]).resolve(strict=True)
        counts[component['role']]=copy_view(source,root/component['destination'],component['files'])
    replacements=[];providers={}
    for role,key in [('wine-base','base'),('wine-dxmt','dxmt')]:
        component=next(c for c in plan['components'] if c['role']==role);wine=root/component['destination'];old=wine/'bin/ready-wine'
        original=root/'origin/installation-wrappers'/(key+'-ready-wine.original');copy_file(old,original)
        before=sha(old);old.unlink();write_new(old,launcher(role),0o755)
        replacements.append({'role':role,'path':str(old.relative_to(root)),'sourceSHA256':before,'derivedSHA256':sha(old),'transformation':'new relative launcher; raw objects and machine-code files unchanged'})
        provider=dict(plan['controllerOrigin']['document']['providers'][key]);provider['wineRoot']=component['destination'];provider['wineLauncherSHA256']=sha(old)
        providers[key]=provider
    cfg=json.loads(json.dumps(plan['sourceConfig']['document']))
    for key in SCALARS:
        if cfg.get(key) is not None:cfg[key]=source_relative(cfg[key],plan)
    for key in MAPS:
        if cfg.get(key) is not None:cfg[key]={k:source_relative(v,plan) for k,v in cfg[key].items()}
    for key,name in [('kosmicICD','kosmic-x64'),('moltenICD','molten')]:
        origin=Path(plan['icdInputs'][key]['path']);doc=json.loads(json.dumps(plan['icdInputs'][key]['document']))
        # Source ICD bytes are retained in origin-meta. Only this adapter is new.
        library=doc['ICD']['library_path'];library=str((origin.parent/library).resolve()) if not Path(library).is_absolute() else library
        doc['ICD']['library_path']='../'+source_relative(library,plan);cfg[key]='icd/'+name+'.json';write_json(root/cfg[key],doc)
    provider_id='ready-installed-controller-'+plan['derivationID'][:20]
    cap={'pathFormat':'runtime-relative-v1','protocolVersion':2,'providerID':provider_id,'engineProviders':plan['controllerOrigin']['document']['engineProviders'],'providers':providers,'requiredEnvironment':{'M1L_XINPUT_CAPTURE':'1'},'origin':{'providerID':plan['controllerOrigin']['providerID'],'capabilitySHA256':plan['controllerOrigin']['manifestSHA256']},'physicalControllerVerified':False,'nonXInputAPIsCovered':False,'placementValidationRequired':True}
    write_json(root/'controller-capability.json',cap)
    cfg['overlayInputCapture']={k:cap[k] for k in ['protocolVersion','providerID','engineProviders','providers']};cfg['overlayInputCapture'].update(manifestPath='controller-capability.json',manifestSHA256=sha(root/'controller-capability.json'))
    cfg.update(pathFormat='runtime-relative-v1',runtimeID='ready-installed-runtime-'+plan['derivationID'],runtimeManifestSHA256=plan['derivationID'],binaryDistributionApproved=False,installationValidationRequired=True,evaluationModeEnabled=False,consumerAppleEnabled=False,proprietaryDistributionEnabled=False)
    cfg['engineProviderIDs']={**cfg.get('engineProviderIDs',{}),'dxmtMetal':provider_id+'-dxmt'}
    cfg['appleOptional']={**cfg.get('appleOptional',{}),'installedLocally':False,'enabled':False,'enabledForConsumerPlay':False,'publicRedistributionEnabled':False,'sourceOpen':False}
    write_json(root/'runtime.json',cfg)
    manifest={'schema':1,'kind':'derived-installed-runtime-layout','derivationID':plan['derivationID'],'planSHA256':fingerprint(plan),'recipeSHA256':plan['recipeSHA256'],'sourceConfigSHA256':plan['sourceConfig']['sha256'],'origins':{'controller':plan['controllerOrigin'],'native':plan['nativeOrigin']},'components':[{k:c[k] for k in ['id','role','destination']} for c in plan['components']],'replacements':replacements,'copyMethods':counts,'runtimeConfigSHA256':sha(root/'runtime.json'),'controllerCapabilitySHA256':sha(root/'controller-capability.json'),'minimumMacOS':plan['minimumMacOS'],'staleWineRpathsPreserved':True,'placementValidationRequired':True,'relocatedRuntimeVerified':False,'binaryDistributionApproved':False,'files':inventory(root,ignore=(STAGE_MARKER,'derivation-manifest.json'))}
    write_json(root/'derivation-manifest.json',manifest)
    return {'schema':1,'candidateConfigPath':'runtime.json','derivationManifestPath':'derivation-manifest.json','derivationManifestSHA256':sha(root/'derivation-manifest.json'),'fileInventory':inventory(root,ignore=(STAGE_MARKER,)),'staticValidation':validate(root,plan)}

def validate(stage_root,plan):
    root=Path(stage_root).resolve(strict=True);doc=json_read(root/'derivation-manifest.json')
    if doc['planSHA256']!=fingerprint(plan) or doc['derivationID']!=plan['derivationID']:raise ValueError('Derivation plan differs')
    if doc['relocatedRuntimeVerified'] is not False or doc['binaryDistributionApproved'] is not False:raise ValueError('Static layout cannot claim runtime/release approval')
    if inventory(root,ignore=(STAGE_MARKER,'derivation-manifest.json'))!=doc['files']:raise ValueError('Derived file inventory changed')
    replacements={r['path']:r for r in doc['replacements']}
    for component in plan['components']:
        target=root/component['destination'];actual=inventory(target)
        if component['role']=='origin-meta':
            for change in doc['replacements']:
                name='base' if change['role']=='wine-base' else 'dxmt';relative='installation-wrappers/'+name+'-ready-wine.original'
                if actual.get(relative,{}).get('sha256')!=change['sourceSHA256']:raise ValueError('Historical wrapper bytes changed')
                actual.pop(relative)
        if set(actual)!=set(component['files']):raise ValueError('View membership differs from selected object')
        for rel,original in component['files'].items():
            derived=actual[rel];path=str(Path(component['destination'])/rel)
            if path in replacements:
                change=replacements[path]
                if rel!='bin/ready-wine' or original.get('sha256')!=change['sourceSHA256'] or derived.get('sha256')!=change['derivedSHA256'] or (target/rel).read_bytes()!=launcher(component['role']):raise ValueError('Unapproved launcher derivation')
            elif derived!=original:raise ValueError('Raw payload byte/mode/alias changed: '+path)
    cfg=json_read(root/'runtime.json');cap=json_read(root/'controller-capability.json')
    if cfg['pathFormat']!='runtime-relative-v1' or cap['pathFormat']!='runtime-relative-v1' or cap['protocolVersion']!=2:raise ValueError('Relative document contract differs')
    for key in SCALARS:
        if cfg.get(key) is not None:
            item=root/safe_relative(cfg[key])
            if not item.exists() or not item.resolve().is_relative_to(root):raise ValueError('Operational scalar leaves installation: '+key)
    for key in MAPS:
        for value in cfg.get(key,{}).values():
            item=root/safe_relative(value)
            if not item.exists() or not item.resolve().is_relative_to(root):raise ValueError('Operational map leaves installation: '+key)
    descriptor=cfg['overlayInputCapture']
    if sha(root/descriptor['manifestPath'])!=descriptor['manifestSHA256']:raise ValueError('Derived capability hash differs')
    for key in ['protocolVersion','providerID','engineProviders','providers']:
        if cap[key]!=descriptor[key]:raise ValueError('Derived capability content differs')
    for provider in cap['providers'].values():
        wine=root/safe_relative(provider['wineRoot'])
        if sha(wine/'bin/wine')!=provider['wineBinarySHA256'] or sha(wine/'bin/ready-wine')!=provider['wineLauncherSHA256']:raise ValueError('Wine binding differs')
        if len(provider['payloadHashes'])!=11 or len(provider['unixAliases'])!=4:raise ValueError('Incomplete controller closure')
        for rel,h in provider['payloadHashes'].items():
            if sha(wine/'lib/wine'/safe_relative(rel))!=h:raise ValueError('Controller production module changed')
        for rel,target in provider['unixAliases'].items():
            path=wine/'lib/wine'/safe_relative(rel)
            if not path.is_symlink() or os.readlink(path)!=target or not path.resolve().is_relative_to(wine):raise ValueError('Controller alias differs')
    if sha(root/'runtime.json')!=doc['runtimeConfigSHA256'] or sha(root/'controller-capability.json')!=doc['controllerCapabilitySHA256']:raise ValueError('Adapter document bytes differ')
    return {'schema':1,'verificationKind':'derivation-static-v1','passed':True,'candidateConfigPath':'runtime.json','derivationManifestSHA256':sha(root/'derivation-manifest.json'),'candidateTreeFingerprint':fingerprint(inventory(root,ignore=(STAGE_MARKER,))),'placementValidationRequired':True,'relocatedRuntimeVerified':False,'binaryDistributionApproved':False}
