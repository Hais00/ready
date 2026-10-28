#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-only
"""Explicitly compact/restore only this project's four .NET SDK build-tool trees."""
import argparse, contextlib, fcntl, gzip, hashlib, json, os, pathlib, posixpath, shutil, stat, tarfile, uuid
ROOT = pathlib.Path(__file__).resolve().parents[1]
NAMES = ('sdk', 'packs', 'templates', 'sdk-manifests')
RESTORE_RESERVE = 512 * 1024 * 1024
COMPACT_RESERVE = 64 * 1024 * 1024


def sha(path):
    with path.open('rb') as stream: return hashlib.file_digest(stream, 'sha256').hexdigest()


def atomic(path, value):
    temporary = path.with_name(path.name + '.pending')
    with temporary.open('x') as stream:
        os.chmod(temporary, 0o600); json.dump(value, stream, sort_keys=True, indent=2); stream.write('\n'); stream.flush(); os.fsync(stream.fileno())
    os.replace(temporary, path)


def owned(path, kind):
    info = path.lstat()
    expected = stat.S_ISDIR if kind == 'directory' else stat.S_ISREG
    if info.st_uid != os.geteuid() or not expected(info.st_mode): raise ValueError('Unsafe SDK cache path: ' + str(path))
    return info


def relative(value):
    parts = pathlib.PurePosixPath(value).parts
    if not parts or value.startswith('/') or any(p in ('.', '..') for p in parts) or parts[0] not in NAMES or '\\' in value: raise ValueError('Out-of-scope SDK archive path')
    return pathlib.Path(*parts)


def entry(path, name):
    info = path.lstat(); value = {'mode': stat.S_IMODE(info.st_mode)}
    if info.st_uid != os.geteuid(): raise ValueError('SDK entry has another owner')
    if stat.S_ISDIR(info.st_mode): value['kind'] = 'directory'
    elif stat.S_ISREG(info.st_mode):
        if info.st_nlink != 1: raise ValueError('Hardlinked SDK entries are not compacted')
        value.update(kind='file', size=info.st_size, sha256=sha(path))
    elif stat.S_ISLNK(info.st_mode):
        target = os.readlink(path); resolved = posixpath.normpath(posixpath.join(posixpath.dirname(name), target))
        if target.startswith('/') or resolved == '..' or resolved.startswith('../'): raise ValueError('SDK symlink escapes dotnet root')
        value.update(kind='symlink', target=target)
    else: raise ValueError('Special SDK file rejected')
    return value


def snapshot(base, names=NAMES):
    result = {}
    def visit(path, name):
        value = entry(path, name); result[name] = value
        if value['kind'] == 'directory':
            for child in sorted(path.iterdir()): visit(child, name + '/' + child.name)
    for name in names:
        if (base/name).exists() or (base/name).is_symlink(): visit(base/name, name)
    return result


class BudgetWriter:
    def __init__(self, stream): self.stream = stream
    def write(self, data):
        if shutil.disk_usage(self.stream.name).free < len(data) + COMPACT_RESERVE: raise OSError('Compression stopped before disk exhaustion; original SDK is untouched')
        return self.stream.write(data)
    def __getattr__(self, name): return getattr(self.stream, name)


class SDKCache:
    def __init__(self, sdk=None, *, fixture=False):
        self.sdk = pathlib.Path(sdk or ROOT/'Runtime/Tools/StoreBridge/dotnet')
        parent = self.sdk.parent
        if fixture:
            owned(parent/'.ready-sdk-cache-fixture', 'file')
            if self.sdk.name != 'dotnet': raise ValueError('Fixture SDK name must be dotnet')
        elif self.sdk != ROOT/'Runtime/Tools/StoreBridge/dotnet': raise ValueError('Only the project SDK may be compacted')
        owned(self.sdk, 'directory')
        if self.sdk.resolve() != self.sdk.absolute(): raise ValueError('SDK symlink/alias rejected')
        self.source = parent/'source.json'; owned(self.source, 'file')
        self.cache = parent/'sdk-cache'
        if not self.cache.exists(): self.cache.mkdir(mode=0o700)
        owned(self.cache, 'directory'); os.chmod(self.cache, 0o700)
        self.manifest = self.cache/'manifest.json'

    @contextlib.contextmanager
    def lock(self):
        fd = os.open(self.cache/'operation.lock', os.O_CREAT|os.O_RDWR|os.O_NOFOLLOW|os.O_CLOEXEC, 0o600)
        try:
            info=os.fstat(fd)
            if info.st_uid!=os.geteuid() or not stat.S_ISREG(info.st_mode): raise ValueError('Unsafe cache lease')
            fcntl.flock(fd, fcntl.LOCK_EX|fcntl.LOCK_NB); yield
        finally: os.close(fd)

    def load(self):
        owned(self.manifest, 'file'); checksum=self.cache/'manifest.sha256.json'; owned(checksum,'file')
        if json.loads(checksum.read_text())!=sha(self.manifest): raise ValueError('SDK manifest SHA256 mismatch')
        m=json.loads(self.manifest.read_text())
        if m.get('schema')!=1 or m.get('roots')!=list(NAMES) or m.get('sourceSHA256')!=sha(self.source): raise ValueError('SDK source/cache identity mismatch')
        if not m['archive'].startswith('sdk-buildtools-') or pathlib.Path(m['archive']).name!=m['archive']: raise ValueError('Unsafe SDK archive name')
        if any(m['entries'].get(name,{}).get('kind')!='directory' for name in NAMES): raise ValueError('SDK manifest lacks required roots')
        for name,value in m['entries'].items():
            path=relative(name)
            if value['kind'] not in ('file','directory','symlink'): raise ValueError('Invalid archive entry kind')
            if len(path.parts)>1 and m['entries'].get(str(path.parent),{}).get('kind')!='directory': raise ValueError('Non-directory archive parent')
        archive=self.cache/m['archive']; owned(archive,'file')
        if sha(archive)!=m['archiveSHA256']: raise ValueError('SDK archive SHA256 mismatch')
        return m

    def verify_archive(self, m, destination=None):
        seen=set()
        with tarfile.open(self.cache/m['archive'], 'r|gz') as tf:
            for member in tf:
                name=member.name; path=relative(name)
                if name in seen or name not in m['entries']: raise ValueError('Unexpected/duplicate archive entry')
                seen.add(name); expected=m['entries'][name]
                kind='directory' if member.isdir() else 'file' if member.isfile() else 'symlink' if member.issym() else 'invalid'
                if kind!=expected['kind'] or member.mode!=expected['mode']: raise ValueError('Archive kind/mode mismatch')
                target=destination/path if destination else None
                if kind=='directory':
                    if target: target.mkdir(mode=0o700, parents=True, exist_ok=False)
                elif kind=='symlink':
                    if member.linkname!=expected['target']: raise ValueError('Archive symlink mismatch')
                    resolved=posixpath.normpath(posixpath.join(posixpath.dirname(name),member.linkname))
                    if member.linkname.startswith('/') or resolved=='..' or resolved.startswith('../'): raise ValueError('Archive symlink escapes SDK root')
                    if target: target.symlink_to(member.linkname)
                else:
                    if member.size!=expected['size']: raise ValueError('Archive size mismatch')
                    with tf.extractfile(member) as stream:
                        if target:
                            with target.open('xb') as out: shutil.copyfileobj(stream,out,1024*1024)
                            actual=sha(target)
                        else: actual=hashlib.file_digest(stream,'sha256').hexdigest()
                    if actual!=expected['sha256']: raise ValueError('Archive content mismatch')
                if target and kind=='file': os.chmod(target,expected['mode'])
        if seen!=set(m['entries']): raise ValueError('Incomplete SDK archive')
        if destination:
            for name,value in sorted(m['entries'].items(), key=lambda item:len(pathlib.PurePosixPath(item[0]).parts), reverse=True):
                path=destination/relative(name)
                if value['kind']=='directory': os.chmod(path,value['mode'])
                elif value['kind']=='symlink' and stat.S_IMODE(path.lstat().st_mode)!=value['mode']: os.chmod(path,value['mode'],follow_symlinks=False)
            if snapshot(destination)!=m['entries']: raise ValueError('Restored SDK does not match manifest')

    def compact(self):
        with self.lock():
            if self.manifest.exists():
                m=self.load(); self.verify_archive(m)
            else:
                if not all((self.sdk/n).is_dir() and not (self.sdk/n).is_symlink() for n in NAMES): raise ValueError('Complete original SDK required before first compact')
                entries=snapshot(self.sdk); fingerprint=hashlib.sha256(json.dumps(entries,sort_keys=True,separators=(',',':')).encode()).hexdigest()
                name='sdk-buildtools-'+fingerprint[:20]+'.tar.gz'; archive=self.cache/name; partial=self.cache/(name+'.partial')
                if archive.exists() or partial.exists(): raise ValueError('Previous cache artifact needs review')
                try:
                    with partial.open('xb') as stream:
                        os.chmod(partial,0o600)
                        with tarfile.open(fileobj=BudgetWriter(stream),mode='w:gz',compresslevel=6,dereference=False) as tf:
                            for path,value in entries.items():
                                info=tarfile.TarInfo(path); info.mode=value['mode']; info.uid=info.gid=0; info.mtime=0
                                if value['kind']=='directory': info.type=tarfile.DIRTYPE; tf.addfile(info)
                                elif value['kind']=='symlink': info.type=tarfile.SYMTYPE; info.linkname=value['target']; tf.addfile(info)
                                else:
                                    info.size=value['size']
                                    with (self.sdk/path).open('rb') as source: tf.addfile(info,source)
                        stream.flush(); os.fsync(stream.fileno())
                    partial.rename(archive)
                except BaseException:
                    partial.unlink(missing_ok=True); raise
                m={'schema':1,'roots':list(NAMES),'sourceSHA256':sha(self.source),'archive':name,'archiveSHA256':sha(archive),'entries':entries,'uncompressedFileBytes':sum(v.get('size',0) for v in entries.values())}
                atomic(self.manifest,m); atomic(self.cache/'manifest.sha256.json',sha(self.manifest)); self.verify_archive(m)
            # Rename complete original roots before recursive deletion. A partial
            # deletion can leave only an owned cache stage, never a partial SDK root.
            state=self.cache/'removal-state.json'
            if state.exists():
                owned(state,'file'); previous=json.loads(state.read_text())
                if previous['manifestSHA256']!=sha(self.manifest): raise ValueError('Removal state manifest mismatch')
                token=previous['stage']
                if not token.startswith('remove-') or pathlib.Path(token).name!=token: raise ValueError('Unsafe removal stage')
                stage=self.cache/token
                try: owned(stage,'directory')
                except FileNotFoundError:
                    # rmtree may have committed before state.unlink. The manifest
                    # is bound above; recreate only an absent empty private stage.
                    stage.mkdir(mode=0o700)
                    owned(stage,'directory')
            else:
                stage=self.cache/('remove-'+uuid.uuid4().hex);stage.mkdir(mode=0o700);atomic(state,{'stage':stage.name,'manifestSHA256':sha(self.manifest)})
            current=snapshot(self.sdk)
            if any(m['entries'].get(name)!=value for name,value in current.items()): raise ValueError('SDK changed after archive verification')
            for name in NAMES:
                target=self.sdk/name
                if target.exists() or target.is_symlink():
                    expected={p:v for p,v in m['entries'].items() if p==name or p.startswith(name+'/')}
                    if snapshot(self.sdk,(name,))!=expected or (stage/name).exists(): raise ValueError('SDK root conflict during compact')
            # Fully recheck every remaining original before moving/removing it.
            for name in NAMES:
                if (self.sdk/name).exists(): (self.sdk/name).rename(stage/name)
            if any(p.name not in NAMES for p in stage.iterdir()): raise ValueError('Unrelated data in SDK removal stage')
            remaining=snapshot(stage)
            if any(m['entries'].get(name)!=value for name,value in remaining.items()): raise ValueError('Removal stage contains changed/untracked SDK data')
            shutil.rmtree(stage); state.unlink()
            return {'compacted':True,'archive':str(self.cache/m['archive']),'archiveSHA256':m['archiveSHA256'],'fileBytes':m['uncompressedFileBytes'],'archiveBytes':(self.cache/m['archive']).stat().st_size,'freeBytes':shutil.disk_usage(self.cache).free}

    def restore(self):
        with self.lock():
            m=self.load();self.verify_archive(m)
            missing=[]
            for name in NAMES:
                target=self.sdk/name;expected={p:v for p,v in m['entries'].items() if p==name or p.startswith(name+'/')}
                if target.exists() or target.is_symlink():
                    if snapshot(self.sdk,(name,))!=expected: raise ValueError('Existing SDK root conflicts with verified cache')
                else: missing.append(name)
            if not missing:return {'restored':False,'alreadyComplete':True}
            required=m['uncompressedFileBytes']+RESTORE_RESERVE
            if shutil.disk_usage(self.cache).free<required: raise OSError('Not enough space to restore SDK while preserving512MiB reserve')
            stage=self.cache/('restore-'+uuid.uuid4().hex);stage.mkdir(mode=0o700)
            try:
                self.verify_archive(m,stage)
                # All conflicts are checked before the first rename. Repeat after
                # interruption accepts exact already-restored roots only.
                for name in missing:
                    if (self.sdk/name).exists() or (self.sdk/name).is_symlink(): raise ValueError('SDK destination appeared during restore')
                for name in missing:(stage/name).rename(self.sdk/name)
                if snapshot(self.sdk)!=m['entries']: raise ValueError('SDK restore verification failed')
            finally: shutil.rmtree(stage)
            return {'restored':True,'roots':missing,'archiveSHA256':m['archiveSHA256']}


def main():
    p=argparse.ArgumentParser(description=__doc__);p.add_argument('operation',choices=['compact','restore','verify']);a=p.parse_args();cache=SDKCache()
    if a.operation=='compact':result=cache.compact()
    elif a.operation=='restore':result=cache.restore()
    else:
        with cache.lock():m=cache.load();cache.verify_archive(m);result={'verified':True,'archiveSHA256':m['archiveSHA256']}
    print(json.dumps(result,indent=2))
if __name__=='__main__':main()
