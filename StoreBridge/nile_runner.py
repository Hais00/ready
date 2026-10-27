#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-or-later
"""Adapt Keychain credentials to Nile's open config API; encrypted temporary user store."""
import contextlib,hashlib,json,os,pathlib,sys,time
from nile.utils.config import Config,ConfigType
from nile import constants
from nile.cli import main
from nile.api.library import Library
from nile.api.session import APIHandler
from nile.api.self_update import SelfUpdateHandler
from nile.downloading.manager import DownloadManager
from nile.utils.download import calculate_checksum,get_hashing_function

def run():
    os.umask(0o077)
    source=pathlib.Path(os.environ.pop('READY_CREDENTIAL_FILE'));credentials=json.loads(source.read_text());source.unlink()
    config=Config();uid=credentials.get('customer_id') or credentials.get('device_serial')
    if not uid or not credentials.get('access_token'):raise RuntimeError('Amazon credentials missing')
    user_id=str(uid);config.write('current_user',{'name':'Ready profile','user_id':user_id})
    name=hashlib.md5(user_id.encode()).hexdigest();key=hashlib.sha256(user_id.encode()).digest()
    payload={'tokens':{'bearer':{k:credentials[k] for k in ('access_token','refresh_token','expires_in') if k in credentials}},'NILE':{'token_obtain_time':time.time()},'extensions':{'device_info':{'device_serial_number':credentials['device_serial']},'customer_info':{'user_id':user_id,'given_name':'Ready profile'}}}
    payload['tokens']['bearer'].setdefault('expires_in',3600)
    config.write(name,payload,cfg_type=ConfigType.JSONENC,enc_key=key)
    # Downloading game content does not require Amazon's proprietary runtime SDK.
    # Never silently fetch that SDK into an otherwise open-source distribution.
    SelfUpdateHandler.get_sdk=lambda self:None
    original_finish=DownloadManager.finish
    def checked_finish(manager,verifying):
        # Upstream Nile 1.2.0 can finish after worker failures/checksum warnings.
        # Fail closed before it records a completed install.
        for future in manager.threads:future.result()
        root=pathlib.Path(manager.install_path).resolve()
        for package in manager.manifest.packages:
            for item in package.files:
                file=(root/item.path.replace('\\','/')).resolve()
                if not file.is_relative_to(root) or not file.is_file() or file.stat().st_size!=item.size:
                    raise RuntimeError('Amazon file verification failed')
                function=get_hashing_function(item.hash.algorithm)
                if function is None or calculate_checksum(function,str(file))!=item.hash.value:
                    raise RuntimeError('Amazon file checksum failed')
        return original_finish(manager,verifying)
    DownloadManager.finish=checked_finish
    try:
        # Nile install reads its cached entitlement list. Populate it from the real
        # authenticated service in this ephemeral config before invoking install.
        Library(config,APIHandler(config)).sync(force=True)
        return main()
    finally:
        for p in [pathlib.Path(constants.CONFIG_PATH)/(name+'.enc'),pathlib.Path(constants.CONFIG_PATH)/'current_user.json']:
            with contextlib.suppress(FileNotFoundError):p.unlink()
if __name__=='__main__':sys.exit(run())
