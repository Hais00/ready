#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-only
"""Offline subprocess/pipe fixtures only: no .NET, Valve, accounts or network."""
import dataclasses
import hashlib
import json
import os
from pathlib import Path
import sys
import tempfile
import threading
import time
import unittest
from unittest import mock

import steam_headless_auth_broker as broker
from steam_host_credential import pack_credentials

ROOT = Path(__file__).resolve().parents[1]
ACCOUNT = "fixture_account"
TOKEN = "opaque.fixture-only.not-a-jwt"
STEAM_ID = (1 << 56) | (1 << 52) | (1 << 32) | 12345

HELPER = r'''
import json, os, signal, sys, time
mode=MODE
account="fixture_"+"account"
token="opaque.fixture-only."+"not-a-jwt"
steam=(1<<56)|(1<<52)|(1<<32)|12345
assert len(sys.argv)==1
assert all(account not in v and token not in v for v in os.environ.values())
assert "STEAM_BROKER_FIXTURE_SECRET" not in os.environ
assert not any(k.startswith(("DYLD_","LD_","Steam","SB_")) for k in os.environ)
request=json.loads(sys.stdin.readline())
assert sys.stdin.read()==""
op=request["operation"]
def emit(value):
 print(json.dumps(value),flush=True)
def auth():
 emit({"type":"result","credentials":{"username":account,"refresh_token":token,"access_token":"unused.fixture"}})
if op=="auth_begin":
 if mode.startswith("auth-error-code-"):
  emit({"type":"error","code":mode[len("auth-error-code-"):],"message":token});sys.exit(1)
 if mode=="unknown-error-code":emit({"type":"error","code":token,"message":account});sys.exit(1)
 if mode=="hang":time.sleep(4)
 if mode=="ignore-term":
  signal.signal(signal.SIGTERM,signal.SIG_IGN);time.sleep(4)
 if mode=="stderr-limit":sys.stderr.write("X"*70000);sys.stderr.flush();time.sleep(4)
 if mode=="frame-limit":print("X"*66000,flush=True);time.sleep(4)
 if mode=="output-limit":
  for _ in range(120):emit({"type":"progress","message":"X"*10000})
  sys.exit()
 if mode=="event-limit":
  for _ in range(130):emit({"type":"progress"})
  sys.exit()
 if mode=="early-eof":emit({"type":"progress"});sys.exit()
 if mode=="truncated":sys.stdout.write('{"type":');sys.stdout.flush();sys.exit()
 if mode=="malformed":print("not-json",flush=True);sys.exit()
 if mode=="duplicate-key":print('{"type":"result","type":"error"}',flush=True);sys.exit()
 if mode=="nan":print('{"type":"progress","value":NaN}',flush=True);sys.exit()
 if mode=="error":emit({"type":"error","message":token});sys.exit(1)
 if mode=="missing-creds":emit({"type":"result"});sys.exit()
 if mode=="bad-creds":emit({"type":"result","credentials":{"username":account,"refresh_token":""}});sys.exit()
 if mode=="extra-auth-field":emit({"type":"result","credentials":{"username":account,"refresh_token":token},"ticket":token});sys.exit()
 if mode=="invalid-qr":emit({"type":"qr","url":"http://s.team/q/synthetic"});time.sleep(4)
 if mode=="userinfo-qr":emit({"type":"qr","url":"https://user:pass@s.team/q/synthetic"});time.sleep(4)
 emit({"type":"qr","url":"https://s.team/q/fixture-one"})
 if mode=="rotate":emit({"type":"qr","url":"https://s.team/q/fixture-two"})
 if mode=="error-result":emit({"type":"error","message":token})
 auth()
 if mode=="result-error":emit({"type":"error","message":token})
 if mode=="duplicate-result":auth()
 if mode=="late-qr":emit({"type":"qr","url":"https://s.team/q/late"})
 if mode=="nonzero":sys.exit(7)
 if mode=="result-hang":time.sleep(4)
elif op=="authorize_game":
 assert request["credentials"]=={"username":account,"refresh_token":token}
 assert request["options"]=={"gameID":"480"}
 if mode.startswith("authorize-error-code-"):
  emit({"type":"error","code":mode[len("authorize-error-code-"):],"message":token});sys.exit(1)
 if mode=="authorize-login-failed":
  emit({"type":"error","code":"steam_login_failed","stage":"logon","steamResult":"Expired","message":token});sys.exit(1)
 if mode=="authorize-ownership-denied":
  emit({"type":"error","code":"not_authorized","stage":"ownership_ticket","steamResult":"AccessDenied","message":token});sys.exit(1)
 if mode=="authorize-unsafe-diagnostic":
  emit({"type":"error","code":token,"stage":token,"steamResult":token,"message":token,"credentials":{"refresh_token":token}});sys.exit(1)
 if mode=="authorize-cleanup-failed":
  emit({"type":"error","code":"steam_error","stage":"ownership_pump","steamResult":"OK","exceptionKind":"InvalidOperationException",
        "ownershipResponseReceived":True,"ownershipAppMatched":True,"ownershipTicketNonEmpty":True,"ownershipSteamIDPresent":True,
        "ownershipDecisionAuthorized":True,"cleanupFailureStage":"ownership_pump","cleanupExceptionKind":"InvalidOperationException","message":token});sys.exit(1)
 if mode=="authorize-unsafe-postticket":
  emit({"type":"error","code":"steam_error","stage":"ownership_decision","steamResult":"OK","exceptionKind":token,
        "ownershipResponseReceived":token,"ownershipAppMatched":1,"ownershipTicketNonEmpty":[],"ownershipSteamIDPresent":{},
        "ownershipDecisionAuthorized":"true","cleanupFailureStage":token,"cleanupExceptionKind":token,"message":token});sys.exit(1)
 if mode=="authorize-eof":sys.exit()
 if mode=="authorize-error":emit({"type":"error","message":token});sys.exit(1)
 if mode=="authorize-qr":emit({"type":"qr","url":"https://s.team/q/unexpected"});sys.exit()
 if mode=="authorize-hang":emit({"type":"progress"});time.sleep(4)
 result={"type":"result","steamID":str(steam),"appID":480,"authorized":True,"ownershipTicketReceived":True,"ticketSHA256":"a"*64}
 if mode=="wrong-app":result["appID"]=481
 if mode=="wrong-steam":result["steamID"]=str(steam+1)
 if mode=="base-steam":result["steamID"]=str(steam&~0xffffffff)
 if mode=="missing-steam":result.pop("steamID")
 if mode=="not-authorized":result["authorized"]=False
 if mode=="integer-authorized":result["authorized"]=1
 if mode=="missing-ticket":result["ownershipTicketReceived"]=False
 if mode=="extra-ticket":result["ticket"]=token
 emit(result)
 if mode=="authorize-nonzero":sys.exit(3)
else:raise AssertionError("Unexpected operation")
'''


class BrokerChecks(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.temp = tempfile.TemporaryDirectory(prefix="ready-auth-broker-fixture-")
        cls.work = Path(cls.temp.name).resolve()
        cls.created = []

    @classmethod
    def tearDownClass(cls):
        cls.temp.cleanup()

    def command(self, mode):
        path = self.work / (mode + ".py")
        path.write_text("MODE=" + repr(mode) + "\n" + HELPER)
        return [str(Path(sys.executable).resolve()), str(path)]

    def run_broker(self, mode="valid", onQR=None, **kwargs):
        original = broker.subprocess.Popen
        children = []
        def owned(*args, **kw):
            process = original(*args, **kw)
            children.append(process)
            return process
        try:
            with mock.patch.object(broker.subprocess, "Popen", side_effect=owned), mock.patch.dict(
                    os.environ, {"STEAM_BROKER_FIXTURE_SECRET": TOKEN, "DYLD_FIXTURE": TOKEN}):
                return broker.authenticate_and_authorize(self.command(mode), 480, onQR or (lambda url: None), **kwargs)
        finally:
            for child in children:
                self.assertIsNotNone(child.poll(), "Owned helper remains alive")
                self.assertTrue(child.stdin.closed and child.stdout.closed and child.stderr.closed)
                self.assertNotIn(TOKEN, repr(child.args))
            self.created.extend(children)

    def rejects(self, mode, code, **kwargs):
        with self.assertRaises(broker.BrokerError) as caught:
            self.run_broker(mode, **kwargs)
        self.assertEqual(str(caught.exception), code)
        self.assertNotIn(TOKEN, repr(caught.exception))
        self.assertNotIn(ACCOUNT, repr(caught.exception))

    def test_authorization_handoff_private_and_exact(self):
        urls = []
        context = self.run_broker(onQR=urls.append, expectedSteamID=STEAM_ID)
        self.assertEqual(urls, ["https://s.team/q/fixture-one"])
        self.assertEqual(dataclasses.asdict(context.safe), {"appID":480,"steamID":STEAM_ID,"authorized":True,"ownershipTicketReceived":True})
        for value in (context, context.handoff):
            self.assertNotIn(TOKEN, repr(value)); self.assertNotIn(ACCOUNT, str(value))
        r, w = os.pipe()
        context.handoff.write_to(w)
        try:
            wire = os.read(r, 20000)
            self.assertEqual(os.read(r, 1), b"")
        finally:
            os.close(r)
        self.assertEqual(wire, pack_credentials({"username":ACCOUNT,"refresh_token":TOKEN,"steamID":STEAM_ID,"appID":480}))
        self.assertTrue(context.handoff.cleared)

    def test_qr_rotation(self):
        urls=[];context=self.run_broker("rotate",onQR=urls.append)
        self.assertEqual(urls,["https://s.team/q/fixture-one","https://s.team/q/fixture-two"])
        context.handoff.clear()

    def test_safe_phase_order(self):
        phases=[];context=self.run_broker(onPhase=phases.append)
        self.assertEqual(phases,["authenticating","authentication_complete","authorizing_game","authorized"])
        context.handoff.clear()

    def test_allowlisted_helper_codes_and_safe_diagnostics(self):
        for code in broker.HELPER_ERROR_CODES:
            with self.subTest(code=code),self.assertRaises(broker.BrokerError) as caught:
                self.run_broker("auth-error-code-"+code)
            self.assertEqual(caught.exception.diagnostic(),{"phase":"auth_begin","code":code,"helperExit":1,"helperStage":None,"steamResult":None,"secretFree":True})
        with self.assertRaises(broker.BrokerError) as caught:self.run_broker("unknown-error-code")
        self.assertEqual(caught.exception.code,"helper_error")
        self.assertNotIn(TOKEN,json.dumps(caught.exception.diagnostic()))
        self.assertNotIn(ACCOUNT,json.dumps(caught.exception.diagnostic()))

    def test_authorization_failure_marks_qr_complete_before_next_request(self):
        events=[]
        with self.assertRaises(broker.BrokerError) as caught:
            self.run_broker("authorize-error-code-not_authorized",onQR=lambda _:events.append("qr"),onPhase=events.append)
        self.assertEqual(events,["authenticating","qr","authentication_complete","authorizing_game"])
        self.assertEqual(caught.exception.diagnostic(),{"phase":"authorize_game","code":"not_authorized","helperExit":1,"helperStage":None,"steamResult":None,"secretFree":True})

    def test_safe_sdk_error_headers_preserved_and_unknown_text_discarded(self):
        cases=[("authorize-login-failed","steam_login_failed","logon","Expired"),
               ("authorize-ownership-denied","not_authorized","ownership_ticket","AccessDenied"),
               ("authorize-unsafe-diagnostic","helper_error",None,"Unknown")]
        for mode,code,stage,result in cases:
            with self.subTest(mode=mode),self.assertRaises(broker.BrokerError) as caught:self.run_broker(mode)
            safe=caught.exception.diagnostic()
            self.assertEqual(safe,{"phase":"authorize_game","code":code,"helperExit":1,
                                   "helperStage":stage,"steamResult":result,"secretFree":True})
            self.assertNotIn(TOKEN,json.dumps(safe));self.assertNotIn(ACCOUNT,json.dumps(safe))

    def test_postticket_diagnostics_are_strict_booleans_and_safe_enum_kinds(self):
        with self.assertRaises(broker.BrokerError) as caught:self.run_broker("authorize-cleanup-failed")
        safe=caught.exception.diagnostic()
        self.assertEqual(safe['exceptionKind'],'InvalidOperationException')
        self.assertEqual(safe['helperStage'],'ownership_pump')
        self.assertEqual(safe['cleanupFailureStage'],'ownership_pump')
        self.assertTrue(all(safe[k]is True for k in broker.OWNERSHIP_FACTS))
        self.assertNotIn(TOKEN,json.dumps(safe))
        with self.assertRaises(broker.BrokerError) as caught:self.run_broker("authorize-unsafe-postticket")
        safe=caught.exception.diagnostic()
        self.assertEqual(safe['exceptionKind'],'Unknown');self.assertEqual(safe['cleanupExceptionKind'],'Unknown')
        self.assertFalse(any(k in safe for k in broker.OWNERSHIP_FACTS))
        self.assertNotIn('cleanupFailureStage',safe);self.assertNotIn(TOKEN,json.dumps(safe))

    def test_session_retries_only_authorization_with_explicit_new_helper(self):
        urls=[];session=broker.beginQR(self.command('valid'),urls.append)
        try:
            self.assertNotIn(TOKEN,repr(session));self.assertNotIn(ACCOUNT,str(session))
            with self.assertRaises(broker.BrokerError) as caught:
                session.authorize_game(self.command('authorize-cleanup-failed'),480)
            self.assertEqual(caught.exception.helper_stage,'ownership_pump');self.assertFalse(session.closed)
            context=session.authorize_game(self.command('valid'),480,expectedSteamID=STEAM_ID)
            self.assertEqual(len(urls),1);self.assertEqual(context.safe.steamID,STEAM_ID);context.handoff.clear()
        finally:session.close()
        self.assertEqual(session._credentials,{})

    def test_session_idle_expiry_clears_without_another_api_call(self):
        session=broker.beginQR(self.command('valid'),lambda _:None,ttl=.1)
        time.sleep(.25)
        self.assertEqual(session._credentials,{})
        with self.assertRaisesRegex(broker.BrokerError,'session_expired'):
            session.authorize_game(self.command('valid'),480)
        session.close()

    def test_session_idle_cancel_clears_without_another_api_call(self):
        stop=threading.Event();session=broker.beginQR(self.command('valid'),lambda _:None,cancel=stop);stop.set()
        time.sleep(.15);self.assertEqual(session._credentials,{})
        with self.assertRaisesRegex(broker.BrokerError,'cancelled'):
            session.authorize_game(self.command('valid'),480)
        session.close()

    def test_session_close_and_busy_fail_before_spawning(self):
        session=broker.beginQR(self.command('valid'),lambda _:None)
        session._operation.acquire()
        try:
            with self.assertRaisesRegex(broker.BrokerError,'session_busy'):
                session.authorize_game(self.command('valid'),480)
        finally:session._operation.release();session.close()
        with mock.patch.object(broker.subprocess,'Popen') as spawn:
            with self.assertRaisesRegex(broker.BrokerError,'session_closed'):
                session.authorize_game(self.command('valid'),480)
            spawn.assert_not_called()

    def test_session_cancel_active_authorizer_has_no_late_handoff(self):
        stop=threading.Event();session=broker.beginQR(self.command('valid'),lambda _:None,cancel=stop)
        timer=threading.Timer(.15,stop.set);timer.start()
        try:
            with self.assertRaisesRegex(broker.BrokerError,'cancelled'):
                session.authorize_game(self.command('authorize-hang'),480)
            self.assertTrue(session.closed);self.assertEqual(session._credentials,{})
        finally:timer.cancel();timer.join();session.close()

    def test_cancel_after_authentication_complete_does_not_start_authorizer(self):
        stop=threading.Event();before=len(self.created)
        def phase(value):
            if value=="authentication_complete":stop.set()
        self.rejects("valid","cancelled",cancel=stop,onPhase=phase)
        self.assertEqual(len(self.created)-before,1)

    def test_phase_callback_exception_is_redacted(self):
        def phase(value):
            if value=="authentication_complete":raise RuntimeError(TOKEN)
        with self.assertRaises(broker.BrokerError) as caught:self.run_broker(onPhase=phase)
        self.assertEqual(caught.exception.code,"phase_callback_failed")
        self.assertEqual(caught.exception.phase,"auth_begin")
        self.assertEqual(caught.exception.helper_exit,0)
        self.assertNotIn(TOKEN,json.dumps(caught.exception.diagnostic()))

    def test_protocol_and_terminal_failures(self):
        cases={"early-eof":"missing_terminal","truncated":"truncated_frame","malformed":"malformed_frame",
               "duplicate-key":"malformed_frame","nan":"malformed_frame","error":"helper_error",
               "error-result":"event_after_terminal","result-error":"event_after_terminal",
               "duplicate-result":"event_after_terminal","late-qr":"event_after_terminal","nonzero":"helper_exit",
               "authorize-eof":"missing_terminal","authorize-error":"helper_error","authorize-qr":"unexpected_event",
               "authorize-nonzero":"helper_exit","invalid-qr":"invalid_qr","userinfo-qr":"invalid_qr"}
        for mode,code in cases.items():
            with self.subTest(mode=mode):self.rejects(mode,code)

    def test_fail_closed_authority(self):
        cases={"missing-creds":"invalid_credentials","bad-creds":"invalid_credentials",
               "extra-auth-field":"unexpected_result_fields","wrong-app":"identity_mismatch",
               "base-steam":"invalid_authorized_identity","missing-steam":"invalid_authorized_identity",
               "not-authorized":"not_authorized","integer-authorized":"not_authorized",
               "missing-ticket":"not_authorized","extra-ticket":"unexpected_result_fields"}
        for mode,code in cases.items():
            with self.subTest(mode=mode):self.rejects(mode,code)
        self.rejects("wrong-steam","identity_mismatch",expectedSteamID=STEAM_ID)

    def test_output_bounds(self):
        for mode,code in {"frame-limit":"frame_limit","stderr-limit":"stderr_limit",
                          "output-limit":"output_limit","event-limit":"event_limit"}.items():
            with self.subTest(mode=mode):self.rejects(mode,code)

    def test_deadline_covers_result_exit_and_both_requests(self):
        for mode in ["hang","result-hang","authorize-hang"]:
            with self.subTest(mode=mode):
                start=time.monotonic();self.rejects(mode,"timeout",timeout=.2)
                self.assertLess(time.monotonic()-start,2)

    def test_cancel_before_spawn(self):
        stop=threading.Event();stop.set()
        with mock.patch.object(broker.subprocess,"Popen") as spawn:
            with self.assertRaisesRegex(broker.BrokerError,"^cancelled$"):
                broker.authenticate_and_authorize(self.command("valid"),480,lambda _:None,cancel=stop)
            spawn.assert_not_called()

    def test_cancel_on_qr_no_late_authority(self):
        stop=threading.Event()
        self.rejects("valid","cancelled",cancel=stop,onQR=lambda _:stop.set())

    def test_cancel_ignored_term_kills_exact_owned_helper(self):
        stop=threading.Event();timer=threading.Timer(.15,stop.set);timer.start()
        try:self.rejects("ignore-term","cancelled",cancel=stop)
        finally:timer.cancel();timer.join()

    def test_qr_callback_failure_redacted(self):
        def callback(_):raise RuntimeError(TOKEN)
        self.rejects("valid","qr_callback_failed",onQR=callback)

    def test_invalid_request_does_not_spawn(self):
        command=self.command("valid")
        for app in [0,True,-1,1<<32,"480 ","1"*5000,None]:
            with self.subTest(app=app),mock.patch.object(broker.subprocess,"Popen") as spawn:
                with self.assertRaises(broker.BrokerError):broker.authenticate_and_authorize(command,app,lambda _:None)
                spawn.assert_not_called()
        with self.assertRaises(broker.BrokerError):broker.authenticate_and_authorize(["python",command[1]],480,lambda _:None)

    def test_handoff_rejects_disk_and_clears(self):
        context=self.run_broker();p=self.work/'untouched.txt';p.write_bytes(b'sentinel')
        with p.open('wb') as writer:
            # Opening wb is a fixture action; reset sentinel before the broker.
            writer.write(b'sentinel');writer.flush()
            with self.assertRaisesRegex(broker.BrokerError,'invalid_handoff_target'):
                context.handoff.write_to(writer)
        self.assertEqual(p.read_bytes(),b'sentinel');self.assertTrue(context.handoff.cleared)

    def test_handoff_cancel_closes_pipe_and_clears(self):
        context=self.run_broker();stop=threading.Event();stop.set();r,w=os.pipe()
        try:
            with self.assertRaisesRegex(broker.BrokerError,'cancelled'):context.handoff.write_to(w,cancel=stop)
            self.assertEqual(os.read(r,1),b'');self.assertTrue(context.handoff.cleared)
        finally:os.close(r)

    def test_cancel_after_authorization_remains_bound_to_handoff(self):
        stop=threading.Event();context=self.run_broker(cancel=stop);stop.set();r,w=os.pipe()
        try:
            with self.assertRaisesRegex(broker.BrokerError,'cancelled'):
                context.handoff.write_to(w)
            self.assertEqual(os.read(r,1),b'');self.assertTrue(context.handoff.cleared)
        finally:os.close(r)

    def test_no_runtime_credential_files(self):
        before=set(self.work.iterdir());context=self.run_broker();context.handoff.clear()
        after=set(self.work.iterdir())
        self.assertTrue(after-before<={self.work/'valid.py'})
        # Source-only synthetic fixture files are allowed; no request/result cache.
        self.assertFalse(any(p.suffix in ['.json','.log','.bin'] for p in after))


if __name__ == '__main__':
    suite=unittest.defaultTestLoader.loadTestsFromTestCase(BrokerChecks)
    result=unittest.TextTestRunner(verbosity=2).run(suite)
    report={'schemaVersion':1,'fixtureOnly':True,'passed':result.wasSuccessful(),'testMethods':result.testsRun,
            'realCredentialsRead':False,'actualAuthenticationAttempted':False,'valveExecuted':False,
            'nativeWorkerLaunched':False,'credentialFilesCreatedByBroker':False,
            'sources':{str(p.relative_to(ROOT)):hashlib.sha256(p.read_bytes()).hexdigest() for p in
                       [Path(__file__),Path(broker.__file__),ROOT/'Scripts/steam_host_credential.py']}}
    if result.wasSuccessful():
        (ROOT/'Evidence/steam-headless-auth-broker-fixtures.json').write_text(json.dumps(report,indent=2)+'\n')
    print(json.dumps(report,indent=2))
    raise SystemExit(not result.wasSuccessful())
