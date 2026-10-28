#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-only
"""Static, hash-bound Windows Valve interface/RTTI evidence. Never executes DLLs."""
import hashlib,json,re,struct,subprocess
from pathlib import Path
from steam_windows_factory_research import RESEARCH,sha
TOOL='/opt/homebrew/opt/llvm/bin/llvm-objdump'
class PE:
    def __init__(self,path):
        self.path=path;self.d=path.read_bytes();p=struct.unpack_from('<I',self.d,60)[0];self.bits=64 if struct.unpack_from('<H',self.d,p+4)[0]==0x8664 else 32;self.step=self.bits//8;self.o=p+24;sz=struct.unpack_from('<H',self.d,p+20)[0];self.base=struct.unpack_from('<Q' if self.bits==64 else '<I',self.d,self.o+(24 if self.bits==64 else 28))[0];self.sections=[]
        for i in range(struct.unpack_from('<H',self.d,p+6)[0]):
            z=self.o+sz+i*40;vs,v,s,a=struct.unpack_from('<IIII',self.d,z+8);self.sections.append((self.d[z:z+8].rstrip(b'\0').decode(),v,a,s))
    def rva(self,a):
        for _,v,b,s in self.sections:
            if b<=a<b+s:return v+a-b
    def raw(self,v):
        for _,a,b,s in self.sections:
            if a<=v<a+s:return b+v-a
    def unpack(self,fmt,a):return struct.unpack_from(fmt,self.d,a)
    def refs(self,data):
        offset=0
        while True:
            offset=self.d.find(data,offset)
            if offset<0:break
            yield offset;offset+=1
    def vtables(self,name):
        text=b'.?AV'+name.encode()+b'@@\0';at=self.d.find(text)
        if at<0:return []
        td=self.rva(at-2*self.step);typ=td if self.bits==64 else self.base+td;result=[]
        for ref in self.refs(struct.pack('<I',typ)):
            col=ref-12
            if col<0:continue
            signature,offset,cd=self.unpack('<III',col)
            if signature!=(1 if self.bits==64 else 0) or offset!=0:continue
            cr=self.rva(col)
            if cr is None:continue
            pointer=struct.pack('<Q' if self.bits==64 else '<I',self.base+cr)
            for vref in self.refs(pointer):
                first=vref+self.step;va=self.base+self.rva(first) if self.rva(first) is not None else 0
                methods=[]
                for i in range(1024):
                    f=self.unpack('<Q' if self.bits==64 else '<I',first+i*self.step)[0];raw=self.raw(f-self.base)
                    if raw is None or not any(n=='.text' and v<=f-self.base<v+s for n,v,a,s in self.sections):break
                    methods.append({'index':i,'VA':hex(f),'RVA':hex(f-self.base),'codePrefixBytes':64,'codePrefixSHA256':hashlib.sha256(self.d[raw:raw+64]).hexdigest()})
                if len(methods)>10:
                    for method in methods:
                        start=self.raw(int(method['RVA'],16));limit=min(768,len(self.d)-start);refs=[]
                        if self.bits==64:
                            directory=self.o+112+3*8;er,es=self.unpack('<II',directory);eo=self.raw(er)
                            if eo is not None:
                                for entry in range(eo,eo+es,12):
                                    begin,end,_=self.unpack('<III',entry)
                                    if begin<=int(method['RVA'],16)<end:limit=min(end-int(method['RVA'],16),4096);break
                            for match in re.finditer(rb'[\x48\x4c]\x8d[\x05\x0d\x15\x1d\x25\x2d\x35\x3d]....',self.d[start:start+limit],re.S):
                                target=int(method['RVA'],16)+match.start()+7+struct.unpack_from('<i',match.group(),3)[0];a=self.raw(target)
                                if a is not None:
                                    text=self.d[a:a+100].split(b'\0',1)[0]
                                    if 2<len(text)<90 and all(32<=b<127 for b in text):refs.append({'VA':hex(self.base+target),'text':text.decode()})
                        else:
                            candidates=[int(m['VA'],16) for m in methods if int(m['VA'],16)>int(method['VA'],16)]
                            if candidates:limit=min(limit,min(candidates)-int(method['VA'],16))
                            for offset in range(max(0,limit-3)):
                                target=struct.unpack_from('<I',self.d,start+offset)[0];a=self.raw(target-self.base)
                                if a is not None:
                                    text=self.d[a:a+100].split(b'\0',1)[0]
                                    if 2<len(text)<90 and all(32<=b<127 for b in text):refs.append({'VA':hex(target),'text':text.decode()})
                        method['staticStringReferences']=refs
                    result.append({'name':name,'typeDescriptorRVA':hex(td),'completeObjectLocatorRVA':hex(cr),'vtableVA':hex(va),'methods':methods})
        return result
    def snippet(self,address,size=240):return subprocess.check_output([TOOL,'-d','--no-show-raw-insn','--start-address='+hex(address),'--stop-address='+hex(address+size),str(self.path)],text=True)
def main():
    result={'schema':1,'scope':'Static exact Windows DLL ABI evidence; no credential/authentication execution','images':[]}
    for bits,path in [(64,RESEARCH/'valve-client64/steamclient64.dll'),(32,RESEARCH/'valve-client32/steamclient.dll')]:
        pe=PE(path);item={'bits':bits,'path':str(path),'sha256':sha(path),'interfaces':[]}
        for name in ['IClientUserMap','IClientEngineMap','IClientAppsMap']:
            item['interfaces'].extend(pe.vtables(name))
        result['images'].append(item)
    out=RESEARCH/'windows-login-interface-tables.json';out.write_text(json.dumps(result,indent=2)+'\n');print(json.dumps({'path':str(out),'interfaces':[{ 'bits':x['bits'],'tables':[(t['name'],t['vtableVA'],len(t['methods'])) for t in x['interfaces']]} for x in result['images']]},indent=2))

def write_auth_map(tables):
    definitions={1:('LogOn','int32(this,uint64SteamID); result code, not bool'),4:('BLoggedOn','bool8(this)'),10:('GetSteamID','hidden8byte result buffer; this,outBuffer -> same buffer pointer'),54:('SetLoginInformation','void(this,account,password,bool8remember)'),56:('SetLoginToken','void(this,token,account); token first'),181:('BIsSubscribedApp','bool8(this,uint32appID); internal UserMap, not public Apps')}
    result={'schema':1,'scope':'Static exact-image Windows modern auth and callback ABI; never executed','generatorSHA256':sha(Path(__file__)),'authenticationAttempted':False,'genuineAuthenticatedHostVerified':False,'images':[],'declarationSource':str(Path(__file__).parent/'steam_windows_login_abi.h'),'declarationSHA256':sha(Path(__file__).parent/'steam_windows_login_abi.h'),'tableEvidenceSHA256':sha(RESEARCH/'windows-login-interface-tables.json')}
    for image in tables['images']:
        pe=PE(Path(image['path']));table=next(t for t in image['interfaces'] if t['name']=='IClientUserMap');methods=[];snippets=[]
        for index,(name,prototype) in definitions.items():
            method=dict(table['methods'][index]);method.update(name=name,prototype=prototype);methods.append(method);snippets.append('INDEX '+str(index)+' '+name+'\n'+pe.snippet(int(method['VA'],16),650))
        er,_=pe.unpack('<II',pe.o+(112 if pe.bits==64 else 96));fields=pe.unpack('<IIHHIIIIIII',pe.raw(er));_,_,_,_,_,base,nfunc,nname,funcs,names,ords=fields;exports={}
        for j in range(nname):
            nr=pe.unpack('<I',pe.raw(names)+j*4)[0];a=pe.raw(nr);name=pe.d[a:pe.d.index(0,a)].decode(errors='replace')
            if name not in ['Steam_BGetCallback','Steam_FreeLastCallback','Steam_LogOn','Steam_BLoggedOn']:continue
            ordinal=pe.unpack('<H',pe.raw(ords)+j*2)[0];rv=pe.unpack('<I',pe.raw(funcs)+ordinal*4)[0];a=pe.raw(rv);exports[name]={'RVA':hex(rv),'VA':hex(pe.base+rv),'codePrefixBytes':64,'codePrefixSHA256':hashlib.sha256(pe.d[a:a+64]).hexdigest()};snippets.append('EXPORT '+name+'\n'+pe.snippet(pe.base+rv,190))
        path=RESEARCH/('windows-modern-login-'+str(pe.bits)+'.txt');path.write_text('\n'.join(snippets));result['images'].append({'bits':pe.bits,'DLLSHA256':image['sha256'],'userMapVtableVA':table['vtableVA'],'methods':methods,'exports':exports,'callbackLayout':{'userOffset':0,'idOffset':4,'payloadOffset':8,'payloadBytesOffset':16 if pe.bits==64 else 12,'sizeof':24 if pe.bits==64 else 16},'callbackCallingConvention':'cdecl32; Windowsx64 on64','callbackLifetime':'Fetch, inspect/copy bounded payload, free on SAME thread before next fetch; no retained payload pointers','snippet':str(path),'snippetSHA256':sha(path)})
    result['publicAppsStaticEvidence']={'path':str(RESEARCH/'windows-public-apps-static.json'),'sha256':sha(RESEARCH/'windows-public-apps-static.json'),'SteamClientVersion':'SteamClient023','AppsVersions':['STEAMAPPS_INTERFACE_VERSION009','STEAMAPPS_INTERFACE_VERSION008'],'clientGetAppsIndex':15,'appsIsSubscribedAppIndex':6,'clientShutdownIfAllPipesClosedIndex':22,'executed':False}
    result['caveats']=['Static ABI is not modern token format or server acceptance proof','Public Apps adapter009 slot6 performs additional checks beyond internal User181; public API execution not verified','Short32string scans can overlap neighbors; selected method indices require body and argument cleanup confirmation','32host sharedmem run exited1 after successful release events; no normal teardown proof','No credential or auth calls made; no real or invalid token submitted']
    path=RESEARCH/'windows-login-abi.json';path.write_text(json.dumps(result,indent=2)+'\n');return path

if __name__=='__main__':
    main()
    path=write_auth_map(json.loads((RESEARCH/'windows-login-interface-tables.json').read_text()));print(json.dumps({'authABI':str(path),'sha256':sha(path)}))
