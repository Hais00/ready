#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-only
"""Static facts/code hashes for exact game SDK discovery; never executes the SDK.
No disassembled implementation bodies are copied into this report or repository.
"""
import hashlib,json,re,struct,subprocess,uuid
from pathlib import Path
ROOT=Path(__file__).resolve().parents[1];WORK=Path('/Volumes/Dati APFS/Codex-ready-01a17e79')
SDK=Path('/Volumes/Dati APFS/SteamLibrary/steamapps/common/Cyberpunk 2077/Cyberpunk2077.app/Contents/Frameworks/libsteam_api.dylib');EXPECTED='2cbe2533e09d1561051f417d7b8c784481a2efdc4fc9d1274704ee8a7ef50cb1'
def sha(p):return hashlib.sha256(Path(p).read_bytes()).hexdigest()
def main():
 data=SDK.read_bytes();assert hashlib.sha256(data).hexdigest()==EXPECTED;magic,count=struct.unpack_from('>II',data,0);assert magic==0xcafebabe;offset=size=None
 for i in range(count):
  cpu,sub,at,length,align=struct.unpack_from('>IIIII',data,8+20*i)
  if cpu==0x0100000c:offset,size=at,length
 assert offset is not None;slice=data[offset:offset+size];assert struct.unpack_from('<I',slice)[0]==0xfeedfacf
 # This image's __TEXT segment has vmaddr0/fileoff0. Verify rather than assume.
 pos=32;text=None
 for _ in range(struct.unpack_from('<I',slice,16)[0]):
  command,length=struct.unpack_from('<II',slice,pos)
  if command==0x19 and slice[pos+8:pos+24].rstrip(b'\0')==b'__TEXT':text=struct.unpack_from('<QQQQ',slice,pos+24)
  pos+=length
 assert text and text[0]==0 and text[2]==0
 assembly=subprocess.check_output(['/opt/homebrew/opt/llvm/bin/llvm-objdump','--macho','--arch=arm64','--no-show-raw-insn','-d',str(SDK)],text=True);lines=assembly.splitlines();instructions=[]
 for line in lines:
  m=re.match(r'\s*([0-9a-f]+):\s*(.*)',line)
  if m:instructions.append((int(m[1],16),m[2]))
 functions=[('SteamAPI_InitFlat',0x38a8,0x38b4),('SteamInternal_SteamAPI_Init',0x38b4,0x3960),('InstallPathResolver',0x3088,0x332c),('IPCtoolConnect',0x332c,0x33e4),('MetadataRequest14',0x33e4,0x34c4),('ClientLibraryLoaderPrefix',0x3504,0x37c0),('SteamAPI_IsSteamRunning',0x47fc,0x48fc),('MachConnectionInitialize',0x53dc,0x5528),('VersionQuery100001',0x5528,0x5594),('LegacyRestartPath',0x5594,0x5670),('MachSendReceive',0x5670,0x5714),('MachSend',0x5714,0x581c)]
 entries=[]
 for name,a,b in functions:
  code=slice[a:b];block=[(v,s) for v,s in instructions if a<=v<b];strings=[];stubs=[]
  for va,line in block:
   m=re.search(r'literal pool for: "(.*)"',line)
   if m:strings.append({'VA':hex(va),'literal':m[1]})
   m=re.search(r'symbol stub for: (\S+)',line)
   if m:stubs.append({'VA':hex(va),'symbol':m[1]})
  entries.append({'name':name,'startVA':hex(a),'endVA':hex(b),'byteRangeSHA256':hashlib.sha256(code).hexdigest(),'bytes':len(code),'literalReferences':strings,'importCallReferences':stubs})
 env=[]
 for i,(va,line) in enumerate(instructions):
  if 'symbol stub for: _getenv' in line:
   key=next((re.search(r'literal pool for: "(.*)"',x[1])[1] for x in reversed(instructions[max(0,i-4):i]) if 'literal pool for:' in x[1]),None);env.append({'VA':hex(va),'key':key})
 report={'schema':1,'scope':'Exact ARM64 static SDK discovery facts only; no SDK/client/account execution','sdkPath':str(SDK),'sdkSHA256':EXPECTED,'arm64SliceOffset':offset,'arm64SliceBytes':size,'arm64SliceSHA256':hashlib.sha256(slice).hexdigest(),'functions':entries,'environmentReads':env,'discovery':{'service':'com.valvesoftware.steam.ipctool','transport':'Mach bootstrap_look_up/mach_msg; not Steam3Master TCP','nativeEnvironmentOverrideFound':False,'messageHeaderID':104,'getVersion':{'applicationOperation':100001,'requestBytes':32,'requestArgument':104,'replyBytes':40,'replyVersionOffset':28,'minimumVersion':104},'metadata':{'applicationOperation':14,'requestBytes':32,'replyBytes':552,'PIDOffset':28,'pathOffset':32,'pathMaxIncludingNUL':512},'isRunningRequirements':['bootstrap lookup and protocol-version check succeed','metadata message succeeds','returned PID nonzero','kill(returnedPID,0)==0'],'installPathRequirements':['same metadata message returns live PID','path includes a directory separator','SDK replaces returned basename with steamclient.dylib beforedlopen(RTLD_NOW)'],'libraryInterfaces':['SteamClient017 compatibility factory','SteamClient021 requested factory','SteamUser023','SteamUtils010'],'notDiscoveryEnvironment':['SteamAppId','SteamGameId','SteamOverlayGameId','SteamClientLaunch','steam_master_ipc_name_override','Steam3Master'],'restartWarning':'Version below104 enters legacy stop/restart path; own metadata service must report truthful supported104 and must not forward unknown stop/auth/license operations'},'noSDKOrAccountExecuted':True,'originalFileUnchanged':sha(SDK)==EXPECTED}
 run=WORK/'retained/research-steam-native'/('sdk-discovery-static-'+uuid.uuid4().hex);run.mkdir(mode=0o700);(run/'report.json').write_text(json.dumps(report,indent=2)+'\n');(run/Path(__file__).name).write_bytes(Path(__file__).read_bytes());summary={'retainedReport':str(run/'report.json'),'SHA256':sha(run/'report.json'),'SDKExecuted':False,'originalSDKUnchanged':True,'discoveryTransport':'Mach IPCtool metadata, not Steam3Master TCP'};(ROOT/'Evidence/steam-native-game-api-discovery.json').write_text(json.dumps(summary,indent=2)+'\n');print(json.dumps(summary,indent=2))
if __name__=='__main__':main()
