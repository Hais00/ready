#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-only
"""Private SDK metadata worker. Never calls an install/download method."""
import contextlib,io,json,logging,lzma,os,pathlib,stat,sys,types,urllib.parse
MAX_JSON=4*1024*1024
class BoundedOutput(io.StringIO):
    def write(self,value):
        if self.tell()+len(value)>MAX_JSON:raise ValueError('metadata limit')
        return super().write(value)
def private_json(path,value):
    fd=os.open(path,os.O_WRONLY|os.O_CREAT|os.O_EXCL|os.O_NOFOLLOW,0o600)
    with os.fdopen(fd,'w')as output:json.dump(value,output)
def refreshed_credentials(context,previous,scratch):
    """Only SDK token fields return on the private stream, never in the plan.
    Preserve refresh rotation even when a later manifest request fails."""
    try:
        path=scratch/('legendary/user.json'if context['store']=='epic'else'gog/auth.json')
        fd=os.open(path,os.O_RDONLY|os.O_NOFOLLOW)
        with os.fdopen(fd,'r')as stream:
            s=os.fstat(stream.fileno())
            if not stat.S_ISREG(s.st_mode)or s.st_uid!=os.getuid()or s.st_mode&0o077 or s.st_size>65536:return None
            value=json.load(stream)
        if context['store']=='gog':
            from gogdl.auth import CLIENT_ID
            value=value.get(CLIENT_ID,{})
        if not isinstance(value,dict):return None
        allowed={'access_token','refresh_token','expires_in','expires_at','account_id','user_id','token_type','scope','client_id'}
        updated={**previous,**{k:v for k,v in value.items()if k in allowed and isinstance(v,(str,int,float))and not isinstance(v,bool)}}
        if all(updated.get(k)==previous.get(k)for k in ('access_token','refresh_token')):return None
        if type(updated.get('expires_in'))in(int,float)and 0<updated['expires_in']<365*86400:updated['expires_at_epoch']=__import__('time').time()+updated['expires_in']
        return updated
    except (OSError,ValueError,TypeError):return None
def epic(c,credentials,scratch):
    config=scratch/'legendary';config.mkdir(mode=0o700)
    private_json(config/'user.json',credentials);os.environ['LEGENDARY_CONFIG_PATH']=str(config)
    from legendary.cli import LegendaryCLI
    args=types.SimpleNamespace(app_name_or_manifest=c['gameID'],platform='Mac'if c['platform']=='macOS'else'Windows',offline=False,json=True,pretty_json=False)
    if pathlib.Path(c['gameID']).exists():raise ValueError('ambiguous app name')
    cli=LegendaryCLI(api_timeout=15) # override_config is an INI file, not a directory.
    output=BoundedOutput()
    try:
        with contextlib.redirect_stdout(output):cli.info(args)
        return json.loads(output.getvalue())
    finally:cli.core.exit()
def gog(c,credentials,scratch):
    config=scratch/'gog';config.mkdir(mode=0o700);os.environ['GOGDL_CONFIG_PATH']=str(config)
    from gogdl.auth import AuthorizationManager,CLIENT_ID
    from gogdl.api import ApiHandler
    from gogdl.languages import Language
    from gogdl.dl.managers.manager import Manager
    from gogdl.dl.objects import v1,v2
    from gogdl.dl import dl_utils
    language=Language.parse(c['language'])
    if language is None:return {'error':'invalid_language'}
    path=config/'auth.json';private_json(path,{CLIENT_ID:{**credentials,'loginTime':__import__('time').time()}})
    class Args(types.SimpleNamespace):
        def __contains__(self,key):return hasattr(self,key)
    args=Args(command='info',platform='osx'if c['platform']=='macOS'else'windows',id=c['gameID'],branch=None,password=None,force_generation=None,workers_count=1,build=None,lang=language.code,dlcs=False,dlcs_list=None,dlc_only=False)
    api=ApiHandler(AuthorizationManager(str(path)));manager=Manager(args,[],api);manager.setup_download_manager()
    selected=manager.download_manager;selected.get_meta()
    generation=manager.target_build['generation']
    manifest=v1.Manifest(args.platform,selected.meta,language,[],api,False)if generation==1 else v2.Manifest(selected.meta,language,[],api,False)
    if str(manifest.product_id)!=c['gameID']:return {'error':'manifest_unavailable'}
    if not manifest.depots:return {'error':'manifest_unavailable'}
    # The SDK's selected depots apply language OR wildcard once, avoiding the
    # overlapping language buckets returned by info.calculate_download_size.
    from size_plan import uint64
    disk=download=0;disk_known=download_known=True;seen=set()
    raw=selected.meta['product']['depots']if generation==1 else selected.meta['depots']
    for depot in manifest.depots:
        if depot.manifest in seen:continue
        seen.add(depot.manifest)
        row=next((entry for entry in raw if entry.get('manifest')==depot.manifest),{})
        size=uint64(row.get('size'));compressed=size if generation==1 else uint64(row.get('compressedSize'))
        disk_known &= size is not None;download_known &= compressed is not None
        disk+=size or 0;download+=compressed or 0
    dependencies=manifest.dependencies_ids
    if dependencies:
        build=api.get_dependencies_repo();repository=dl_utils.get_zlib_encoded(api,build['repository_manifest'])[0]
        for depot in repository['depots']:
            if depot['dependencyId']in dependencies and not depot['executable']['path'].startswith('__redist'):
                size=uint64(depot.get('size'));compressed=uint64(depot.get('compressedSize'))
                disk_known &= size is not None;download_known &= compressed is not None;disk+=size or 0;download+=compressed or 0
    return {'gameID':c['gameID'],'selected':{'disk_size':disk if disk_known else None,'download_size':download if download_known else None},'generation':generation,'language':language.code}
def amazon(c,credentials,scratch):
    # No nile.cli, Config or SelfUpdateHandler: this route cannot fetch Amazon's
    # proprietary runtime SDK, create an install folder or start a downloader.
    from bridge import HTTP,StoreAdapter
    games=StoreAdapter(HTTP(),'amazon').amazon_library(credentials)
    game=next((g for g in games if g['storeID']==c['gameID']),None)
    if game is None:return {'error':'manifest_unavailable'}
    from nile.api.library import Library
    from nile.api.session import APIHandler
    from nile.models.manifest import Manifest
    from nile.proto import sds_proto2_pb2 as sds
    class CredentialView:
        def get(self,name,key=None,**kwargs):
            if name=='current_user'and key=='user_id':return str(credentials.get('customer_id')or credentials['device_serial'])
            if key=='tokens//bearer//access_token':return credentials['access_token']
            raise ValueError('unexpected config read')
    view=CredentialView();api=APIHandler(view);library=Library(view,api)
    metadata=library.get_game_manifest(game['metadata']['entitlementId'])
    if not isinstance(metadata,dict):return {'error':'manifest_unavailable'}
    url=urllib.parse.urlsplit(metadata['downloadUrl'])
    if url.scheme!='https'or not url.hostname or url.username or url.password:raise ValueError('invalid manifest URL')
    url=urllib.parse.urlunsplit(url._replace(path=url.path.rstrip('/')+'/manifest.proto'))
    with api.session.get(url,stream=True,timeout=15,allow_redirects=False)as response:
        response.raise_for_status();raw=bytearray()
        for chunk in response.iter_content(65536):
            raw.extend(chunk)
            if len(raw)>16*1024*1024:raise ValueError('manifest limit')
    manifest=Manifest()
    def decompress(content):
        if manifest.header_pb.compression.algorithm==sds.lzma:
            decoder=lzma.LZMADecompressor();data=decoder.decompress(content,max_length=64*1024*1024+1)
            if not decoder.eof or len(data)>64*1024*1024:raise ValueError('manifest expansion limit')
            return data
        if manifest.header_pb.compression.algorithm==sds.none and len(content)<=64*1024*1024:return content
        raise ValueError('unsupported manifest compression')
    manifest._decompress=decompress;manifest.parse(bytes(raw)) # SDK verifies RSA signature.
    return {'gameID':c['gameID'],'signatureVerified':True,'packageCount':len(manifest.packages),
      'files':[{'path':f.path,'size':f.size,'hash':f.hash.value}for package in manifest.packages for f in package.files]}
def main():
    os.umask(0o077);logging.disable(logging.CRITICAL)
    request=None
    try:
        line=sys.stdin.buffer.readline(65537)
        if len(line)>65536:raise ValueError('request limit')
        request=json.loads(line);c=request['context'];credentials=request['credentials'];scratch=pathlib.Path(request['scratch'])
        if scratch.resolve()!=pathlib.Path.cwd()or scratch.stat().st_uid!=os.getuid()or scratch.stat().st_mode&0o7777!=0o700:raise ValueError('invalid private directory')
        import requests
        original=requests.sessions.Session.request
        def bounded(self,method,url,**kwargs):
            if urllib.parse.urlsplit(url).scheme!='https':raise ValueError('non HTTPS SDK endpoint')
            kwargs.setdefault('timeout',15);kwargs['allow_redirects']=False
            return original(self,method,url,**kwargs)
        requests.sessions.Session.request=bounded
        with contextlib.redirect_stdout(BoundedOutput()):
            result={'epic':epic,'gog':gog,'amazon':amazon}[c['store']](c,credentials,scratch)
    except SystemExit:result={'error':'manifest_unavailable'}
    except Exception:result={'error':'manifest_unavailable'}
    output={'sdkMetadata':result}
    if isinstance(request,dict):
        credentials=refreshed_credentials(request['context'],request['credentials'],pathlib.Path(request['scratch']))
        if credentials is not None:output['credentials']=credentials
    print(json.dumps(output,separators=(',',':')),flush=True)
if __name__=='__main__':main()
