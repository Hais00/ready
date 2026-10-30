#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-only
"""Retain source-bound read-only size-planner transport/schema results."""
import hashlib,json,os,pathlib,tempfile,unittest,sys
ROOT=pathlib.Path(__file__).resolve().parents[1];WORK=pathlib.Path('/Volumes/Dati APFS/Codex-ready-01a17e79')
def sha(p):return hashlib.sha256(p.read_bytes()).hexdigest()
def main():
    run=pathlib.Path(tempfile.mkdtemp(prefix='store-size-plan-',dir=WORK/'tests'));run.chmod(0o700)
    sources=[ROOT/p for p in ['StoreBridge/bridge.py','StoreBridge/backend.py','StoreBridge/size_plan.py','StoreBridge/size_plan_worker.py','Tests/StoreBridgeTests/test_size_plan.py','Tests/StoreBridgeTests/test_size_plan_sdks.py','Scripts/test_store_size_plan.py']]
    hashes={str(p.relative_to(ROOT)):sha(p)for p in sources}
    # Protect normal application state even if a module resolves its root while
    # importing the production backend. All file fixtures remain on Dati APFS.
    os.environ['READY_DATA_ROOT']=str(run/'state');os.environ['TMPDIR']=str(WORK/'tmp')+'/'
    sys.path.insert(0,str(ROOT/'Tests/StoreBridgeTests'))
    suite=unittest.defaultTestLoader.discover(str(ROOT/'Tests/StoreBridgeTests'),pattern='test_size_plan*.py')
    with (run/'tests.log').open('w')as log:result=unittest.TextTestRunner(stream=log,verbosity=2).run(suite)
    sdk=ROOT/'Runtime/Tools/StoreBridge/venv/lib/python3.15/site-packages'
    sdk_sources=[sdk/p for p in ['legendary/cli.py','legendary/core.py','gogdl/dl/managers/manager.py','gogdl/dl/objects/v1.py','gogdl/dl/objects/v2.py','nile/api/library.py','nile/models/manifest.py','nile/downloading/manager.py']]
    report={'passed':result.wasSuccessful(),'testsRun':result.testsRun,'skipped':len(result.skipped),'sourceHashes':hashes,
      'sourceInputsUnchanged':all(sha(p)==hashes[str(p.relative_to(ROOT))]for p in sources),
      'sdkSourceHashes':{str(p.relative_to(sdk)):sha(p)for p in sdk_sources if p.is_file()},'installedSDKInMemoryChecks':6,
      'actualAccountNetworkOrGamePayloadUsed':False,'installDirectoryAccessed':False,'realStoreManifestPlanVerified':False,
      'scope':'fake helper transport + installed SDK in-memory metadata/signature-negative checks; no account or store network validation'}
    raw=run/'report.json';raw.write_text(json.dumps(report,indent=2)+'\n');raw.chmod(0o600)
    pointer={'passed':report['passed'],'testsRun':result.testsRun,'skipped':len(result.skipped),'retainedReport':str(raw),'retainedReportSHA256':sha(raw),'sourceHashes':hashes,'actualAccountNetworkOrGamePayloadUsed':False}
    (ROOT/'Evidence/store-size-plan-tests.json').write_text(json.dumps(pointer,indent=2)+'\n');print(json.dumps(pointer,indent=2))
    if not report['passed']or not report['sourceInputsUnchanged']:raise SystemExit(1)
if __name__=='__main__':main()
