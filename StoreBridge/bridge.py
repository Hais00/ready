#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-only
"""Ready store protocol bridge. One JSON request on stdin; JSONL events on stdout.

Credentials and auth state are IPC-only. No credential files are persisted by the
direct adapters. Backend download credentials are ephemeral, mode 0600 and removed
after the child exits. The caller owns Keychain persistence and user consent.
"""
from __future__ import annotations
import base64, contextlib, hashlib, json, os, pathlib, plistlib, secrets, shutil
import signal, struct, subprocess, sys, tempfile, time, urllib.error, urllib.parse, urllib.request, uuid

ROOT = pathlib.Path(__file__).resolve().parents[1]
MAX_JSON = 16 * 1024 * 1024
PUBLIC_CLIENT_IDS = {
    # Public launcher identifiers, NOT user credentials. See upstream NOTICE.
    "epic": ("34a02cf8f4414e29b15921876da36f9a", "daafbccc737745039dffe53d94fc76cf"),
    "gog": ("46899977096215655", "9d85c43b1482497dbbce61f6e4aa173a433796eeae2ca8c5f6129f2dc4de46d9"),
}
GOG_REDIRECT = "https://embed.gog.com/on_login_success?origin=client"
AMAZON_DEVICE = "A2UMVHOX7UP4V7"
AMAZON_UA = "com.amazon.agslauncher.win/3.0.9202.1"

class BridgeError(Exception):
    def __init__(self, code, message): self.code, self.message = code, message

def emit(kind, **data):
    print(json.dumps({"type": kind, **data}, ensure_ascii=False, separators=(",", ":")), flush=True)

def require(value, message="Required field missing"):
    if value is None or value == "": raise BridgeError("invalid_request", message)
    return value

class SafeRedirect(urllib.request.HTTPRedirectHandler):
    def redirect_request(self, req, fp, code, msg, headers, newurl):
        new = super().redirect_request(req, fp, code, msg, headers, newurl)
        if new and urllib.parse.urlparse(req.full_url).netloc != urllib.parse.urlparse(newurl).netloc:
            for k in ["Authorization", "X-amzn-token", "Cookie"]: new.remove_header(k)
        return new

class HTTP:
    def __init__(self): self.opener = urllib.request.build_opener(SafeRedirect())
    def json(self, url, method="GET", headers=None, data=None, form=None):
        if urllib.parse.urlparse(url).scheme != "https": raise BridgeError("invalid_endpoint", "Only HTTPS endpoints are allowed")
        h = {"User-Agent": "Ready/0.1 (open-source game launcher)", "Accept": "application/json", **(headers or {})}
        body = None
        if data is not None: body = json.dumps(data).encode(); h["Content-Type"] = "application/json"
        if form is not None: body = urllib.parse.urlencode(form).encode(); h["Content-Type"] = "application/x-www-form-urlencoded"
        try:
            with self.opener.open(urllib.request.Request(url, data=body, headers=h, method=method), timeout=40) as r:
                raw = r.read(MAX_JSON + 1)
                if len(raw) > MAX_JSON: raise BridgeError("response_too_large", "Store response exceeded the limit")
                return json.loads(raw)
        except urllib.error.HTTPError as e:
            # Never return response bodies or request URLs: both can contain credentials.
            raise BridgeError("authentication_required" if e.code in (401, 403) else "http_error", f"Store request failed with HTTP {e.code}") from None
        except (urllib.error.URLError, TimeoutError): raise BridgeError("network_error", "Store connection failed or timed out") from None
        except json.JSONDecodeError: raise BridgeError("invalid_response", "Store returned an invalid JSON document") from None

def bearer(credentials): return {"Authorization": "Bearer " + require(credentials.get("access_token"), "Sign in to this store first")}
def basic(store): return "Basic " + base64.b64encode(":".join(PUBLIC_CLIENT_IDS[store]).encode()).decode()
def encoded(value): return urllib.parse.quote(str(value), safe="")
def normalize_credentials(c, previous=None):
    out = {**(previous or {}), **c}
    if "expires_in" in c: out["expires_at_epoch"] = time.time() + float(c["expires_in"])
    return out
def variant(platform):
    return {"id": platform, "platform": platform, "architecture": "unknown", "installed": False,
            "arguments": [], "verification": "Store metadata only; inspect installed binary before declaring Apple Silicon native"}
def game(store, identity, title, platforms, art=None, metadata=None):
    return {"id": store+":"+str(identity), "store": store, "storeID": str(identity), "title": title or str(identity),
            "artworkURL": art, "variants": [variant(p) for p in platforms], "selectedVariant": None,
            "engine": "automatic", "saveRules": [], "metadata": metadata or {}}

class StoreAdapter:
    def __init__(self, http, store): self.http, self.store = http, store
    def auth_begin(self, profile):
        state = {"profileID": profile, "nonce": secrets.token_urlsafe(32), "created": time.time()}
        if self.store == "epic":
            redirect = "https://www.epicgames.com/id/api/redirect?"+urllib.parse.urlencode({"clientId":PUBLIC_CLIENT_IDS['epic'][0],"responseType":"code"})
            url = "https://www.epicgames.com/id/login?"+urllib.parse.urlencode({"redirectUrl":redirect,"state":state['nonce']})
        elif self.store == "gog":
            url = "https://auth.gog.com/auth?"+urllib.parse.urlencode({"client_id":PUBLIC_CLIENT_IDS['gog'][0],"redirect_uri":GOG_REDIRECT,"response_type":"code","layout":"galaxy","state":state['nonce']})
        elif self.store == "amazon":
            serial = uuid.uuid4().hex.upper(); client = (serial+"#"+AMAZON_DEVICE).encode().hex()
            verifier = secrets.token_urlsafe(32); challenge = base64.urlsafe_b64encode(hashlib.sha256(verifier.encode()).digest()).decode().rstrip("=")
            state.update(device_serial=serial,client_id=client,code_verifier=verifier)
            url = "https://www.amazon.com/ap/signin?"+urllib.parse.urlencode({
                "openid.ns":"http://specs.openid.net/auth/2.0", "openid.claimed_id":"http://specs.openid.net/auth/2.0/identifier_select",
                "openid.identity":"http://specs.openid.net/auth/2.0/identifier_select", "openid.mode":"checkid_setup",
                "openid.oa2.scope":"device_auth_access", "openid.ns.oa2":"http://www.amazon.com/ap/ext/oauth/2",
                "openid.oa2.response_type":"code", "openid.oa2.code_challenge_method":"S256", "openid.oa2.client_id":"device:"+client,
                "language":"en_US", "marketPlaceId":"ATVPDKIKX0DER", "openid.return_to":"https://www.amazon.com",
                "openid.pape.max_auth_age":"0", "openid.ns.pape":"http://specs.openid.net/extensions/pape/1.0",
                "openid.assoc_handle":"amzn_sonic_games_launcher", "pageId":"amzn_sonic_games_launcher", "openid.oa2.code_challenge":challenge})
        else: raise BridgeError("unsupported", "Steam authentication uses the SteamKit helper")
        return {"url":url,"authState":state,"instructions":"Complete sign-in in your browser, then paste the final redirect URL or authorization code into Ready."}

    def auth_complete(self, profile, options):
        state = require(options.get("authState"), "Start an authentication flow first")
        if state.get('profileID') != profile or time.time()-state.get('created',0)>900: raise BridgeError("invalid_auth_state", "Authentication belongs to another profile or expired")
        redirect = options.get("redirectURL", "")
        query = urllib.parse.parse_qs(urllib.parse.urlparse(redirect).query)
        code = options.get("code") or (query.get("code") or query.get("openid.oa2.authorization_code") or [None])[0]
        code = require(code, "Authorization code missing from the response")
        if self.store == "gog" and not options.get("code"):
            if not secrets.compare_digest((query.get('state') or [''])[0], state['nonce']): raise BridgeError("invalid_auth_state", "OAuth state mismatch")
        if self.store == "epic":
            c = self.http.json("https://account-public-service-prod03.ol.epicgames.com/account/api/oauth/token", "POST", {"Authorization":basic('epic')}, form={"grant_type":"authorization_code","code":code,"token_type":"eg1"})
        elif self.store == "gog":
            cid, secret = PUBLIC_CLIENT_IDS['gog']
            c = self.http.json("https://auth.gog.com/token?"+urllib.parse.urlencode({"client_id":cid,"client_secret":secret,"grant_type":"authorization_code","code":code,"redirect_uri":GOG_REDIRECT}))
        else:
            c = self.http.json("https://api.amazon.com/auth/register", "POST", data={
                "auth_data":{"authorization_code":code,"client_domain":"DeviceLegacy","client_id":state['client_id'],"code_algorithm":"SHA-256","code_verifier":state['code_verifier'],"use_global_authentication":False},
                "registration_data":{"app_name":"AGSLauncher for Windows","app_version":"1.0.0","device_model":"Windows","device_name":None,"device_serial":state['device_serial'],"device_type":AMAZON_DEVICE,"domain":"Device","os_version":"10.0.19044.0"},
                "requested_extensions":["customer_info","device_info"],"requested_token_type":["bearer","mac_dms"],"user_context_map":{}})
            c = c['response']['success']['tokens']['bearer']
            c.update(device_serial=state['device_serial'],client_id=state['client_id'])
        require(c.get('access_token'),"Store did not return an access token")
        return normalize_credentials(c)

    def refresh(self, c):
        token = require(c.get('refresh_token'), "Sign in again: refresh token missing")
        if self.store == 'epic':
            result = self.http.json("https://account-public-service-prod03.ol.epicgames.com/account/api/oauth/token","POST",{"Authorization":basic('epic')},form={"grant_type":"refresh_token","refresh_token":token,"token_type":"eg1"})
        elif self.store == 'gog':
            cid,secret = PUBLIC_CLIENT_IDS['gog'];result=self.http.json("https://auth.gog.com/token?"+urllib.parse.urlencode({"client_id":cid,"client_secret":secret,"grant_type":"refresh_token","refresh_token":token}))
        else:
            result=self.http.json("https://api.amazon.com/auth/token","POST",{"x-amzn-identity-auth-domain":"api.amazon.com"},data={"source_token":token,"source_token_type":"refresh_token","requested_token_type":"access_token","app_name":"AGSLauncher for Windows","app_version":"1.0.0"})
        return normalize_credentials(result,c)

    def library(self,c):
        if self.store=='epic':return self.epic_library(c)
        if self.store=='gog':return self.gog_library(c)
        return self.amazon_library(c)

    def epic_library(self,c):
        owned={};cursor=None;seen=set()
        for _ in range(1000):
            url="https://library-service.live.use1a.on.epicgames.com/library/api/public/items?includeMetadata=true"
            if cursor:url+='&cursor='+encoded(cursor)
            page=self.http.json(url,headers=bearer(c))
            for record in page.get('records',[]):
                app=record.get('appName') or record.get('appId') or record.get('catalogItemId')
                if record.get('namespace')=='ue' or record.get('sandboxType')=='PRIVATE' or app=='1':continue
                if app:owned[app]=record
            cursor=(page.get('responseMetadata') or {}).get('nextCursor')
            if not cursor:break
            if cursor in seen:raise BridgeError('pagination_loop','Epic returned a repeated pagination cursor')
            seen.add(cursor)
        else:raise BridgeError('pagination_limit','Epic library exceeded pagination limit')
        assets={}
        for platform,normalized in [('Windows','windows'),('Mac','macOS')]:
            for asset in self.http.json(f'https://launcher-public-service-prod06.ol.epicgames.com/launcher/api/public/assets/{platform}?label=Live',headers=bearer(c)):
                app=asset.get('appName');assets.setdefault(app,{'platforms':[],'asset':asset})['platforms'].append(normalized)
        output=[]
        for app,record in owned.items():
            found=assets.get(app,{});asset=found.get('asset',{});ns=record.get('namespace') or asset.get('namespace');cid=record.get('catalogItemId') or asset.get('catalogItemId')
            detail={}
            if ns and cid:
                detail=self.http.json('https://catalog-public-service-prod06.ol.epicgames.com/catalog/api/shared/namespace/'+encoded(ns)+'/bulk/items?'+urllib.parse.urlencode({'id':cid,'includeDLCDetails':'false','includeMainGameDetails':'false','country':'US','locale':'en'}),headers=bearer(c)).get(cid,{})
            art=next((i.get('url') for i in detail.get('keyImages',[]) if i.get('type') in ('DieselGameBoxTall','Thumbnail','OfferImageTall')),None)
            output.append(game('epic',app,detail.get('title') or record.get('title') or app,found.get('platforms',[]),art,{'namespace':ns,'catalogItemId':cid,'appName':app,'asset':asset}))
        return output

    def gog_library(self,c):
        owned=self.http.json('https://embed.gog.com/user/data/games',headers=bearer(c)).get('owned',[])
        result=[]
        for gid in dict.fromkeys(str(i) for i in owned):
            d=self.http.json('https://api.gog.com/products/'+encoded(gid)+'?expand=downloads',headers=bearer(c))
            platforms=[]
            systems=d.get('content_system_compatibility') or {}
            installers=(d.get('downloads') or {}).get('installers',[])
            if systems.get('windows') or any(i.get('os')=='windows' for i in installers):platforms.append('windows')
            if systems.get('osx') or any(i.get('os') in ('osx','mac','macos') for i in installers):platforms.append('macOS')
            images=d.get('images') or {};art=images.get('logo2x') or images.get('logo') or images.get('icon')
            if art and art.startswith('//'):art='https:'+art
            result.append(game('gog',gid,d.get('title'),platforms,art,{'installers':installers}))
        return result

    def amazon_library(self,c):
        serial=require(c.get('device_serial'),'Amazon device registration missing');token=None;seen=set();result={}
        for _ in range(1000):
            page=self.amazon_post(c,'GetEntitlements',{'Operation':'GetEntitlements','clientId':'Sonic','syncPoint':None,'nextToken':token,'maxResults':50,'productIdFilter':None,'keyId':'d5dc8b8b-86c8-4fc4-ae93-18c0def5314d','hardwareHash':hashlib.sha256(serial.encode()).hexdigest().upper()})
            for e in page.get('entitlements',[]):
                p=e.get('product') or {};gid=p.get('id');eid=e.get('id')
                if not gid or not eid:continue
                pd=p.get('productDetail') or {};details=pd.get('details') or {}
                result[gid]=game('amazon',gid,p.get('title'),['windows'],pd.get('iconUrl') or details.get('logoUrl'),{'entitlementId':eid,'product':p})
            token=page.get('nextToken')
            if not token:break
            if token in seen:raise BridgeError('pagination_loop','Amazon returned a repeated pagination token')
            seen.add(token)
        else:raise BridgeError('pagination_limit','Amazon library exceeded pagination limit')
        return list(result.values())

    def amazon_post(self,c,operation,data):
        entitlement=operation=='GetEntitlements'
        suffix='entitlement.AnimusEntitlementsService.' if entitlement else 'external.AnimusDistributionService.'
        url='https://gaming.amazon.com/api/distribution/'+('entitlements' if entitlement else 'v2/public')
        return self.http.json(url,'POST',{'X-Amz-Target':'com.amazon.animusdistributionservice.'+suffix+operation,'x-amzn-token':require(c.get('access_token'),'Sign in to Amazon first'),'User-Agent':AMAZON_UA,'Content-Encoding':'amz-1.0'},data=data)

    def launch_info(self,c,options):
        if self.store=='epic':
            d=self.http.json('https://account-public-service-prod03.ol.epicgames.com/account/api/oauth/exchange',headers=bearer(c))
            metadata=options.get('metadata') or {};app=require(options.get('gameID'));account=require(c.get('account_id'))
            args=['-AUTH_LOGIN=unused','-AUTH_PASSWORD='+require(d.get('code')),'-AUTH_TYPE=exchangecode','-epicapp='+app,'-epicenv=Prod','-EpicPortal','-epicuserid='+account,'-epiclocale='+options.get('locale','en')]
            return {'arguments':args,'environment':{},'sensitiveArguments':True,'metadata':metadata}
        return {'arguments':[],'environment':{},'note':'Game-specific launcher requirements must be validated; unsupported requirements are not bypassed.'}

def inspect_native(path):
    p=pathlib.Path(path).expanduser()
    if p.suffix=='.app':
        try:
            info=plistlib.loads((p/'Contents/Info.plist').read_bytes())
            if info.get('LSRequiresIPhoneOS'):raise BridgeError('unsupported_platform','This is an iOS application, not a macOS build')
            name=info['CFBundleExecutable']
            if '/' in name or name in ('.','..'):raise BridgeError('invalid_binary','Invalid application executable')
            p=p/'Contents/MacOS'/name
        except (OSError,KeyError,plistlib.InvalidFileException):raise BridgeError('invalid_binary','Application executable could not be resolved') from None
    try:
        with p.open('rb') as f:header=f.read(4096)
    except OSError:raise BridgeError('invalid_binary','Executable is not readable') from None
    if len(header)<8:raise BridgeError('invalid_binary','Executable header is incomplete')
    magic=header[:4];cpus=[]
    if magic in (b'\xcf\xfa\xed\xfe',b'\xce\xfa\xed\xfe'):cpus=[struct.unpack_from('<I',header,4)[0]]
    elif magic in (b'\xfe\xed\xfa\xcf',b'\xfe\xed\xfa\xce'):cpus=[struct.unpack_from('>I',header,4)[0]]
    elif magic in (b'\xca\xfe\xba\xbe',b'\xca\xfe\xba\xbf',b'\xbe\xba\xfe\xca',b'\xbf\xba\xfe\xca'):
        endian='<' if magic in (b'\xbe\xba\xfe\xca',b'\xbf\xba\xfe\xca') else '>';n=struct.unpack_from(endian+'I',header,4)[0];stride=32 if magic in (b'\xca\xfe\xba\xbf',b'\xbf\xba\xfe\xca') else 20
        if n>64 or len(header)<8+n*stride:raise BridgeError('invalid_binary','Invalid universal Mach-O header')
        cpus=[struct.unpack_from(endian+'I',header,8+i*stride)[0] for i in range(n)]
    else:raise BridgeError('invalid_binary','Not a Mach-O executable')
    arm=0x0100000c in cpus;intel=0x01000007 in cpus
    architecture='universal' if arm and intel else 'arm64' if arm else 'x86_64' if intel else 'unknown'
    return {'path':str(p),'architecture':architecture,'appleSiliconNative':arm,'verification':'Mach-O CPU type inspected; full execution compatibility not yet tested'}

def validate_request(r):
    if not isinstance(r,dict):raise BridgeError('invalid_request','Request must be a JSON object')
    operation=require(r.get('operation'));store=r.get('store')
    if operation not in ('capabilities','native_inspect'):
        if store not in ('steam','epic','gog','amazon'):raise BridgeError('invalid_store','Unsupported storefront')
        try:uuid.UUID(require(r.get('profileID')))
        except (ValueError,AttributeError):raise BridgeError('invalid_profile','profileID must be a UUID') from None
    for name in ('credentials','options'):
        if not isinstance(r.get(name,{}),dict):raise BridgeError('invalid_request',name+' must be an object')
    return operation,store,r.get('credentials',{}),r.get('options',{})

def dispatch(r,http=None):
    operation,store,c,o=validate_request(r)
    operation={'auth_start':'auth_begin','install':'download'}.get(operation,operation)
    if operation!=r.get('operation'):r={**r,'operation':operation}
    if 'authState' not in o and 'state' in o:o={**o,'authState':o['state']}
    if operation=='capabilities':return {'protocolVersion':1,'stores':['steam','epic','gog','amazon'],'operations':['auth_begin','auth_complete','refresh','library','download','launch_info','native_inspect'],'nativeArchitecturePolicy':'unknown until local Mach-O inspection','credentialsTransport':'stdin/stdout only; caller must store in Keychain'}
    if operation=='native_inspect':return inspect_native(require(o.get('path')))
    if store=='steam':
        from backend import steam_request
        return steam_request(r)
    a=StoreAdapter(http or HTTP(),store)
    if operation=='auth_begin':return a.auth_begin(r['profileID'])
    if operation=='auth_complete':return {'credentials':a.auth_complete(r['profileID'],o)}
    if operation=='refresh':return {'credentials':a.refresh(c)}
    if operation in ('library','download','launch_info') and c.get('expires_at_epoch',float('inf')) < time.time()+60:
        c=a.refresh(c);r={**r,'credentials':c}
    if operation=='library':
        return {'games':a.library(c),'credentials':c}
    if operation=='launch_info':return a.launch_info(c,o)
    if operation=='download':
        from backend import download
        return download(r)
    raise BridgeError('unsupported_operation','Unsupported operation')

def main():
    os.umask(0o077)
    def cancelled(signum,frame):
        signal.signal(signal.SIGTERM,signal.SIG_IGN)
        raise KeyboardInterrupt
    signal.signal(signal.SIGTERM,cancelled)
    try:
        line=sys.stdin.buffer.readline(MAX_JSON+1)
        if len(line)>MAX_JSON:raise BridgeError('invalid_request','Request is too large')
        request=json.loads(line)
        op=request.get('operation') if isinstance(request,dict) else None
        if op=='auth_start':op='auth_begin'
        result=dispatch(request)
        if op=='auth_begin' and request.get('store')!='steam':emit('auth_url',**result)
        else:emit('result',**result)
    except BridgeError as e:emit('error',code=e.code,message=e.message);return 1
    except KeyboardInterrupt:emit('error',code='cancelled',message='Store operation cancelled');return 130
    except (json.JSONDecodeError,UnicodeDecodeError):emit('error',code='invalid_request',message='Input must be one UTF-8 JSON object');return 1
    except Exception:
        # Avoid inadvertently leaking bearer tokens from third-party exceptions.
        emit('error',code='internal_error',message='Store bridge failed; no credentials were logged');return 1
    return 0
if __name__=='__main__':
    # backend imports the same module so BridgeError identity remains stable.
    sys.modules.setdefault('bridge',sys.modules[__name__])
    sys.exit(main())
