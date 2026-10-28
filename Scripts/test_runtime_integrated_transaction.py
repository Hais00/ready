#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-only
"""Only miniature marked project-config fixtures; no runtimes, Wine or user data."""
import copy, hashlib, json, os, pathlib, stat, subprocess, sys, tempfile, unittest
sys.path.insert(0,str(pathlib.Path(__file__).resolve().parent))
import runtime_activate_integrated as module

class Interrupted(Exception):pass

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
        self.assertEqual(self.before['runtime.json'],(directory/'before-runtime.json').read_bytes());self.assertFalse(journal['activationImplemented']);self.assertEqual(directory,self.t.prepare())
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
        self.prepared();module.atomic(self.runtime/module.PROPOSALS[0],b'{"tampered":true}\n');result=self.t.check();self.assertFalse(result['readyForRootReview']);self.assertFalse(result['checks']['composition-and-before-images']['passed']);self.assertFalse(result['activationImplemented']);self.assertEqual(self.before['runtime.json'],(self.runtime/'runtime.json').read_bytes())
        changed=copy.deepcopy(self.base);changed['runtimeID']='another-source';module.atomic(self.runtime/'candidate-xinput-v2.json',module.encoded(changed));self.assertRaises(ValueError,self.t.prepare)
    def test_absent_previous_project_config_remains_absent_after_rollback(self):
        (self.runtime/'runtime.json').unlink();directory,journal=self.prepared();record=journal['configs'][0];module.atomic(self.runtime/record['name'],module.read(directory/record['afterImage']),record['mode']);self.t.rollback();self.assertFalse((self.runtime/'runtime.json').exists())
    def test_symlink_active_config_is_rejected(self):
        (self.runtime/'runtime.json').unlink();(self.runtime/'runtime.json').symlink_to(self.root/'UserRuntimes/untouched');self.assertRaises(ValueError,self.t.prepare)
    def test_activate_command_is_not_exposed(self):
        result=subprocess.run([sys.executable,module.__file__,'activate'],capture_output=True,text=True);self.assertEqual(2,result.returncode);self.assertIn('invalid choice',result.stderr)

if __name__=='__main__':unittest.main()
