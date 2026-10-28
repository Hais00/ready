#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-only
"""Only miniature marked project-config fixtures; no runtimes, Wine or user data."""
import contextlib, copy, hashlib, json, os, pathlib, stat, subprocess, sys, tempfile, unittest
from unittest.mock import patch
sys.path.insert(0,str(pathlib.Path(__file__).resolve().parent))
import runtime_activate_integrated as module

class Interrupted(Exception):pass
class SimulatedCrash(BaseException):pass

class IntegrationTests(unittest.TestCase):
    def setUp(self):
        self.temp=tempfile.TemporaryDirectory();self.root=pathlib.Path(self.temp.name).resolve();(self.root/'.ready-integrated-runtime-fixture').write_text('Owned fixture\n');self.runtime=self.root/'Runtime';self.runtime.mkdir();(self.root/'Evidence').mkdir();(self.root/'UserRuntimes').mkdir();(self.root/'UserRuntimes/untouched').write_text('user override');(self.root/'Prefixes').mkdir();(self.root/'Prefixes/untouched').write_text('user save')
        base={'runtimeID':'E6-source','wine':'E6-base','wineBinary':'E6-native','wineServer':'E6-server','vulkanLibrary':'x64-loader','kosmicNativeICD':'old-native','verifiedEngines':['wineD3D','vulkanKosmic','dxmtMetal'],'engineAPIs':{'wineD3D':['d3d9'],'vulkanKosmic':['vulkan'],'dxmtMetal':['d3d11']},'engineDLLs':{'dxmtMetal':'E6-DXMT-DLL'},'engineWineBinaries':{'dxmtMetal':'E6-DXMT-Wine'},'engineProviderIDs':{'dxmtMetal':'E6-DXMT-ID'},'engineBootstrap32Dirs':{},'overlayInputCapture':{'protocolVersion':2,'engineProviders':{'wineD3D':'base','dxmtMetal':'dxmt'},'manifestPath':str(self.runtime/'missing-capability'),'providers':{}},'appleOptional':{'enabled':False}}
        evaluation=copy.deepcopy(base);evaluation.update(runtimeID='old-eval',verifiedEngines=['d3dMetal'],evaluationOnlyEngines=['d3dMetal','unrelated'],evaluationCapabilityEvidence={'d3dMetal':{'shaderRasterizationVerified':True},'unrelated':{'mustNotLeak':True}},appleOptional={'exactAppleLicenseSHA256':'license-hash','enabled':False,'wineABIValidated':True})
        evaluation['engineWineBinaries']={'dxmtMetal':'OLD-DXMT','d3dMetal':'WineCX-Apple'};evaluation['engineProviderIDs']['d3dMetal']='WineCX-ID';evaluation['engineDLLs']['d3dMetal']='Apple-DLL';evaluation['engineBootstrap32Dirs']={'d3dMetal':'pure-WineCX32'};evaluation['engineAPIs']['d3dMetal']=['d3d11','d3d12']
        self.base=base;self.evaluation=evaluation
        module.atomic(self.runtime/'candidate-xinput-v2.json',module.encoded(base));module.atomic(self.runtime/'evaluation-runtime.json',module.encoded(evaluation),0o640);module.atomic(self.runtime/'runtime.json',b'{"runtimeID":"previous-source-generation","custom":"retained"}\n',0o640)
        native=self.runtime/'Providers'/module.NATIVE;native.mkdir(parents=True);module.atomic(native/'native-renderer-manifest.json',module.encoded({'identity':module.NATIVE}));module.atomic(self.root/'Evidence/runtime-native-renderer-validation.json',b'{}\n')
        self.t=module.Transaction(self.root,fixture=True);self.before={name:(self.runtime/name).read_bytes()for name in module.CONFIGS}
    def tearDown(self):
        self.assertEqual('user override',(self.root/'UserRuntimes/untouched').read_text());self.assertEqual('user save',(self.root/'Prefixes/untouched').read_text());self.temp.cleanup()
    def prepared(self):
        directory=self.t.prepare();return directory,self.t.journal(directory)
    def test_compose_preserves_all_E6_bindings_and_only_d3dMetal_evaluation(self):
        normal,evaluation=self.t.proposals()
        for key in ['wine','wineBinary','wineServer','vulkanLibrary','engineDLLs','engineWineBinaries','overlayInputCapture']:self.assertEqual(self.base[key],normal[key])
        self.assertEqual('E6-DXMT-Wine',evaluation['engineWineBinaries']['dxmtMetal']);self.assertEqual('WineCX-Apple',evaluation['engineWineBinaries']['d3dMetal']);self.assertEqual('pure-WineCX32',evaluation['engineBootstrap32Dirs']['d3dMetal']);self.assertEqual(normal['overlayInputCapture'],evaluation['overlayInputCapture']);self.assertNotIn('unrelated',evaluation['evaluationCapabilityEvidence']);self.assertEqual(['d3dMetal'],evaluation['evaluationOnlyEngines']);self.assertEqual('license-hash',evaluation['appleOptional']['exactAppleLicenseSHA256']);module.check_policy(normal,evaluation)
    def test_prepare_retains_previous_source_bytes_mode_and_unknown_fields(self):
        directory,journal=self.prepared()
        for name in module.CONFIGS:self.assertEqual(self.before[name],(self.runtime/name).read_bytes());self.assertEqual(0o640,stat.S_IMODE((self.runtime/name).stat().st_mode))
        self.assertEqual(self.before['runtime.json'],(directory/'before-runtime.json').read_bytes());self.assertTrue(journal['activationImplemented']);self.assertEqual(directory,self.t.prepare())
    def test_rollback_interruption_restores_exact_bytes_modes_on_retry(self):
        directory,journal=self.prepared()
        for record in journal['configs']:module.atomic(self.runtime/record['name'],module.read(directory/record['afterImage']),record['mode'])
        second_after=(self.runtime/'evaluation-runtime.json').read_bytes()
        def checkpoint(phase,count):
            if count==1:raise Interrupted()
        self.assertRaises(Interrupted,self.t.rollback,checkpoint=checkpoint);self.assertEqual('rolling-back',self.t.journal(directory)['state']);self.assertEqual(self.before['runtime.json'],(self.runtime/'runtime.json').read_bytes());self.assertEqual(second_after,(self.runtime/'evaluation-runtime.json').read_bytes());self.t.rollback()
        for name in module.CONFIGS:self.assertEqual(self.before[name],(self.runtime/name).read_bytes());self.assertEqual(0o640,stat.S_IMODE((self.runtime/name).stat().st_mode))
        self.assertTrue((directory/'after-runtime.json').is_file())
    def test_unknown_second_config_prevents_any_rollback_write(self):
        directory,journal=self.prepared();first=journal['configs'][0];module.atomic(self.runtime/first['name'],module.read(directory/first['afterImage']),first['mode']);module.atomic(self.runtime/'evaluation-runtime.json',b'{"custom":"new user bytes"}',0o640);snapshot={name:(self.runtime/name).read_bytes()for name in module.CONFIGS};self.assertRaises(ValueError,self.t.rollback)
        self.assertEqual(snapshot,{name:(self.runtime/name).read_bytes()for name in module.CONFIGS})
    def test_corrupt_snapshot_and_scope_fail_closed(self):
        directory,journal=self.prepared();module.atomic(directory/'before-runtime.json',b'corrupt snapshot');self.assertRaises(ValueError,self.t.rollback);self.assertEqual(self.before['runtime.json'],(self.runtime/'runtime.json').read_bytes())
        module.atomic(directory/'before-runtime.json',self.before['runtime.json']);journal['configs'][0]['name']='../UserRuntimes/untouched';module.atomic(directory/'journal.json',module.encoded(journal));self.assertRaises(ValueError,self.t.rollback)
    def test_changed_proposal_or_source_is_blocked_without_promotion(self):
        self.prepared();module.atomic(self.runtime/module.PROPOSALS[0],b'{"tampered":true}\n');result=self.t.check();self.assertFalse(result['readyForRootReview']);self.assertFalse(result['checks']['composition-and-before-images']['passed']);self.assertFalse(result['activationPerformed']);self.assertTrue(result['activationImplemented']);self.assertEqual(self.before['runtime.json'],(self.runtime/'runtime.json').read_bytes())
        changed=copy.deepcopy(self.base);changed['runtimeID']='another-source';module.atomic(self.runtime/'candidate-xinput-v2.json',module.encoded(changed));self.assertRaises(ValueError,self.t.prepare)
    def test_absent_previous_project_config_remains_absent_after_rollback(self):
        (self.runtime/'runtime.json').unlink();directory,journal=self.prepared();record=journal['configs'][0];module.atomic(self.runtime/record['name'],module.read(directory/record['afterImage']),record['mode']);self.t.rollback();self.assertFalse((self.runtime/'runtime.json').exists())
    def test_symlink_active_config_is_rejected(self):
        (self.runtime/'runtime.json').unlink();(self.runtime/'runtime.json').symlink_to(self.root/'UserRuntimes/untouched');self.assertRaises(ValueError,self.t.prepare)
    @contextlib.contextmanager
    def ready_fixture(self):
        self.prepared()
        with contextlib.ExitStack() as stack:
            for name in ['check_controller','check_native','check_e2e','check_core','check_ui']:
                stack.enter_context(patch.object(module,name,return_value={'fixtureProof':name}))
            result=self.t.check();self.assertTrue(result['readyForRootReview']);self.assertTrue(result['fixtureOnly'])
            directory=self.t.directory();journal=self.t.journal(directory)
            yield journal['lastCheck']['sha256']

    def test_activate_requires_explicit_review_hash(self):
        self.prepared();self.assertRaises(ValueError,self.t.activate)
        self.assertRaises(ValueError,self.t.activate,root_go='0'*64)
        self.assertEqual(self.before['runtime.json'],(self.runtime/'runtime.json').read_bytes())

    def test_fixture_ready_commit_idempotence_and_rollback(self):
        with self.ready_fixture() as go:
            result=self.t.activate(root_go=go);self.assertEqual('committed',result['state'])
            for record in self.t.journal(self.t.directory())['configs']:
                self.assertEqual(record['afterSHA256'],module.sha(self.runtime/record['name']))
                self.assertEqual(0o640,stat.S_IMODE((self.runtime/record['name']).stat().st_mode))
            self.assertTrue(self.t.activate(root_go=go)['alreadyCommitted']);self.t.rollback()
        for name in module.CONFIGS:self.assertEqual(self.before[name],(self.runtime/name).read_bytes())

    def test_identical_repeated_ready_receipts_allow_exact_hash_activation(self):
        with self.ready_fixture()as go:
            first=self.t.journal(self.t.directory())['lastCheck']['file']
            result=self.t.check();second=self.t.journal(self.t.directory())['lastCheck']
            self.assertNotEqual(first,second['file']);self.assertEqual(go,second['sha256'])
            self.assertEqual('committed',self.t.activate(root_go=go)['state'])

    def test_crash_after_first_activation_write_requires_rollback(self):
        with self.ready_fixture() as go:
            def checkpoint(phase,count):
                if phase=='activation-config-written'and count==1:raise SimulatedCrash()
            self.assertRaises(SimulatedCrash,self.t.activate,root_go=go,checkpoint=checkpoint)
            journal=self.t.journal(self.t.directory());self.assertEqual('activating',journal['state'])
            self.assertEqual(journal['configs'][0]['afterSHA256'],module.sha(self.runtime/'runtime.json'))
            self.assertEqual(self.before['evaluation-runtime.json'],(self.runtime/'evaluation-runtime.json').read_bytes())
            self.assertRaises(ValueError,self.t.activate,root_go=go);self.t.rollback()
        self.assertEqual(self.before['runtime.json'],(self.runtime/'runtime.json').read_bytes())

    def test_crash_after_both_writes_before_commit_restores_both(self):
        with self.ready_fixture() as go:
            def checkpoint(phase,count):
                if phase=='activation-before-commit':raise SimulatedCrash()
            self.assertRaises(SimulatedCrash,self.t.activate,root_go=go,checkpoint=checkpoint)
            self.assertEqual('activating',self.t.journal(self.t.directory())['state']);self.t.rollback()
        for name in module.CONFIGS:self.assertEqual(self.before[name],(self.runtime/name).read_bytes())

    def test_second_write_error_automatically_rolls_back(self):
        with self.ready_fixture() as go:
            original=module.atomic;failed=False
            def fail_once(path,data,mode=0o600):
                nonlocal failed
                if path==self.runtime/'evaluation-runtime.json'and not failed:
                    failed=True;raise OSError('scoped fixture write failure')
                return original(path,data,mode)
            with patch.object(module,'atomic',side_effect=fail_once):self.assertRaises(OSError,self.t.activate,root_go=go)
            self.assertTrue(failed);self.assertEqual('rolled-back',self.t.journal(self.t.directory())['state'])
        for name in module.CONFIGS:self.assertEqual(self.before[name],(self.runtime/name).read_bytes())

    def test_changed_ready_proof_blocks_before_write(self):
        with self.ready_fixture() as go:
            with patch.object(module,'check_core',return_value={'different':'receipt'}):self.assertRaises(ValueError,self.t.activate,root_go=go)
        self.assertEqual(self.before['runtime.json'],(self.runtime/'runtime.json').read_bytes())

    def test_external_receipt_requires_matching_nearest_marker_and_sha(self):
        with tempfile.TemporaryDirectory()as outside:
            external=pathlib.Path(outside).resolve();body=external/'report.json';body.write_text('{"fixture":true}')
            wrapper=self.root/'Evidence/retained-fixture.json'
            module.atomic(wrapper,module.encoded({'retainedReport':str(body),'retainedReportSHA256':module.sha(body)}))
            # TMPDIR may itself be under an authorized external workspace. An
            # invalid nearest marker must still reject rather than inheriting it.
            marker=external/'.ready-external-workspace';marker.write_text('invalid owned fixture marker\n')
            self.assertRaises(ValueError,module.evidence,self.root,wrapper.name)
            marker.write_text('ready project work for thread01a17e79\n');external.chmod(0o700)
            result,path,binding=module.evidence(self.root,wrapper.name);self.assertTrue(result['fixture']);self.assertEqual(body,path)
            self.assertEqual(module.sha(body),binding['retainedSHA256']);body.write_text('{"fixture":"changed"}')
            self.assertRaises(ValueError,module.evidence,self.root,wrapper.name)

    def test_artifact_paths_come_from_recorded_commands(self):
        build={'commands':[['clang','-o','/owned/external/ReadyControllerPolicyProbe'],['link','/out:/owned/external/controller-policy.exe']]}
        self.assertEqual('/owned/external/ReadyControllerPolicyProbe',module.command_output(build,'ReadyControllerPolicyProbe'))
        self.assertEqual('/owned/external/controller-policy.exe',module.command_output(build,'controller-policy.exe'))
        self.assertRaises(ValueError,module.command_output,build,'missing.exe')

    def test_concurrent_unknown_config_preserved_on_recovery(self):
        with self.ready_fixture() as go:
            unknown=b'{"unknown":"preserve new project data"}'
            def checkpoint(phase,count):
                if phase=='activation-config-written'and count==1:
                    module.atomic(self.runtime/'evaluation-runtime.json',unknown,0o640)
                    raise OSError('scoped concurrent change')
            self.assertRaises(OSError,self.t.activate,root_go=go,checkpoint=checkpoint)
            self.assertEqual('rollback-blocked',self.t.journal(self.t.directory())['state'])
            self.assertEqual(unknown,(self.runtime/'evaluation-runtime.json').read_bytes())
            self.assertRaises(ValueError,self.t.rollback)
            self.assertTrue((self.t.directory()/'before-runtime.json').is_file())


if __name__=='__main__':unittest.main()
