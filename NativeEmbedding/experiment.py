#!/usr/bin/env python3
"""Execute owned host/guest experiments. No other app is launched, sign-modified, or closed."""
import os,pathlib,subprocess,time,json,re,sys
OUT=pathlib.Path(sys.argv[1] if len(sys.argv)>1 else '/Volumes/Dati APFS/Codex-ready-01a17e79/tests/native-embedding-20261028')
ROOT=pathlib.Path('/Volumes/Dati APFS/Codex-ready-01a17e79').resolve()
if not OUT.resolve().is_relative_to(ROOT) or not (ROOT/'.ready-external-workspace').is_file():
    raise RuntimeError('Dedicated Dati workspace required')
mode=sys.argv[2] if len(sys.argv)>2 else 'cooperative'
HE=OUT/'NativeEmbeddingHost.app/Contents/MacOS/Lab';GE=OUT/'NativeEmbeddingGuest.app/Contents/MacOS/Lab'
service='local.ready.embedding.'+mode+'.'+str(os.getpid())
linger='45' if '--view' in sys.argv else '0'
hargs=[str(HE),'--host',service,'--frames','180','--linger',linger]
gargs=[str(GE),'--frames','180']
env=os.environ.copy()
if '--fullscreen-cycle' in sys.argv:hargs+=['--fullscreen-cycle']
if mode=='headless':hargs+=['--headless'];gargs+=['--forward',service]
elif mode=='cooperative':gargs+=['--forward',service,'--pace-ms','30']
elif mode=='injected':env.update(DYLD_INSERT_LIBRARIES=str(OUT/'EmbeddingShim.dylib'),NATIVE_EMBED_SERVICE=service)
elif mode=='local-reparent':hargs+=['--idle'];hargs[hargs.index('--linger')+1]='6';gargs+=['--reparent-local']
elif mode=='foreign-lookup':hargs+=['--idle'];hargs[hargs.index('--linger')+1]='6';env.update(DYLD_INSERT_LIBRARIES=str(OUT/'EmbeddingShim.dylib'))
else:raise ValueError(mode)
hlog=OUT/(mode+'.host.txt');glog=OUT/(mode+'.guest.txt')
hf=hlog.open('w');gf=glog.open('w');h=subprocess.Popen(hargs,stdout=hf,stderr=subprocess.STDOUT)
try:
 for _ in range(100):
  content=hlog.read_text()
  if 'HOST_READY' in content or mode in ('foreign-lookup','local-reparent') and 'WINDOW pid=' in content:break
  if h.poll() is not None:raise RuntimeError(content)
  time.sleep(.05)
 if mode=='foreign-lookup':gargs+=['--foreign-window-number',re.search(r'windowNumber=(\d+)',content).group(1)]
 g=subprocess.Popen(gargs,stdout=gf,stderr=subprocess.STDOUT,env=env)
 receipt={'mode':mode,'host_pid':h.pid,'guest_pid':g.pid,'host_argv':hargs,'guest_argv':gargs,'injection':mode=='injected'}
 (OUT/(mode+'.running.json')).write_text(json.dumps(receipt,indent=2));print(json.dumps(receipt),flush=True)
 receipt['guest_exit']=g.wait(timeout=40);receipt['host_exit']=h.wait(timeout=75)
except Exception as e:
 receipt={'mode':mode,'error':str(e)}
 if 'g' in locals() and g.poll() is None:g.terminate();g.wait(timeout=5)
 if h.poll() is None:h.terminate();h.wait(timeout=5)
(OUT/(mode+'.result.json')).write_text(json.dumps(receipt,indent=2));print(json.dumps(receipt,indent=2))
