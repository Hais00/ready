#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-only
"""Acquire complete release-tag source trees without executing upstream code.

Primary Git objects and recursive gitlinks control identity; codeload archives
avoid cloning history. A source packet is not binary-build attestation or release
approval. Apple payloads and active Vendor/Runtime sets are never inputs/outputs.
"""
import argparse
import configparser
import hashlib
import json
import os
from pathlib import Path, PurePosixPath
import re
import shutil
import subprocess
import tarfile
import urllib.parse
import urllib.request

ROOT = Path(__file__).resolve().parents[1]
LOCK = Path(__file__).with_suffix('.lock.json')
BASE = ROOT / 'Runtime/CorrespondingSources'
RESERVE = 512 * 1024 * 1024
ROOTS = [
    ('dxvk', 'doitsujin/dxvk', 'v3.1.1', 'b1a1c99ab52b687cf950d62c88bc2fa316b41663', 'Runtime/dxvk-3.1.1.artifact.json'),
    ('vkd3d-proton', 'HansKristian-Work/vkd3d-proton', 'v3.0.1', '3b10bd7a7ec6a7347e616cf8bea59333afec2255', 'Runtime/vkd3d-proton-3.0.1.artifact.json'),
    ('moltenvk', 'KhronosGroup/MoltenVK', 'v1.4.2', 'db66022459ffb663aa2b50f6b018bc2e124f5edf', 'Runtime/moltenvk-1.4.2.artifact.json'),
]
MOLTEN_EXTERNAL = {
    'cereal': ('USCiLab/cereal', 'External/cereal'),
    'Vulkan-Headers': ('KhronosGroup/Vulkan-Headers', 'External/Vulkan-Headers'),
    'SPIRV-Cross': ('KhronosGroup/SPIRV-Cross', 'External/SPIRV-Cross'),
    'SPIRV-Tools': ('KhronosGroup/SPIRV-Tools', 'External/SPIRV-Tools'),
    'SPIRV-Headers': ('KhronosGroup/SPIRV-Headers', 'External/SPIRV-Tools/external/spirv-headers'),
    'Vulkan-Tools': ('KhronosGroup/Vulkan-Tools', 'External/Vulkan-Tools'),
    'Volk': ('zeux/Volk', 'External/Volk'),
}


def digest(path):
    with Path(path).open('rb') as stream:
        return hashlib.file_digest(stream, 'sha256').hexdigest()


def blob(data):
    return hashlib.sha1(b'blob ' + str(len(data)).encode() + b'\0' + data).hexdigest()


def write(path, value):
    path.parent.mkdir(parents=True, exist_ok=True)
    temporary = path.with_name(path.name + '.pending')
    temporary.write_text(json.dumps(value, indent=2, sort_keys=True) + '\n')
    os.replace(temporary, path)


def get(url):
    # No credential is sent. GitHub/primary raw endpoints are public.
    parsed = urllib.parse.urlsplit(url)
    if parsed.scheme != 'https' or parsed.hostname not in {'api.github.com', 'raw.githubusercontent.com', 'codeload.github.com'}:
        raise ValueError('Non-primary source URL rejected')
    return urllib.request.urlopen(urllib.request.Request(url, headers={'User-Agent': 'ready-corresponding-source-fetcher'}), timeout=120)


def api(path):
    with get('https://api.github.com/' + path) as response:
        return json.load(response)


def safe_path(value):
    path = PurePosixPath(value)
    if path.is_absolute() or not path.parts or any(x in {'..', '.'} for x in path.parts) or '\\' in value:
        raise ValueError('Unsafe source path')
    return Path(*path.parts)


def repo_name(url, parent):
    if url.startswith('../'):
        url = urllib.parse.urljoin('https://github.com/' + parent + '/', url)
    match = re.fullmatch(r'https://github\.com/([A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+?)(?:\.git)?/?', url)
    if not match:
        raise ValueError('Unsupported/non-primary submodule URL: ' + url)
    return match[1]


def raw(repo, commit, path, expected=None):
    with get(f'https://raw.githubusercontent.com/{repo}/{commit}/' + urllib.parse.quote(path, safe='/')) as stream:
        data = stream.read()
    if expected and blob(data) != expected:
        raise ValueError('Raw Git blob mismatch: ' + path)
    return data


def resolve():
    nodes, roots = {}, []

    def node(repo, commit):
        if not re.fullmatch('[0-9a-f]{40}', commit):
            raise ValueError('Source commit must be an exact SHA1')
        key = hashlib.sha256((repo.lower() + '@' + commit).encode()).hexdigest()[:20]
        if key in nodes:
            return key
        commit_data = api(f'repos/{repo}/git/commits/{commit}')
        if commit_data['sha'] != commit:
            raise ValueError('Commit identity mismatch')
        tree = api(f'repos/{repo}/git/trees/' + commit_data['tree']['sha'] + '?recursive=1')
        if tree.get('truncated') or tree['sha'] != commit_data['tree']['sha']:
            raise ValueError('Incomplete primary Git tree')
        n = {'id': key, 'repository': repo, 'commit': commit, 'treeSHA': tree['sha'], 'commitObject': commit_data, 'treeObject': tree, 'children': []}
        nodes[key] = n
        entries = {x['path']: x for x in tree['tree']}
        links = [x for x in tree['tree'] if x['mode'] == '160000']
        if links:
            modules = entries.get('.gitmodules')
            if not modules:
                raise ValueError('Gitlinks without .gitmodules')
            parser = configparser.ConfigParser(interpolation=None)
            parser.read_string(raw(repo, commit, '.gitmodules', modules['sha']).decode())
            declarations = {parser[s]['path']: parser[s]['url'] for s in parser.sections()}
            for link in links:
                safe_path(link['path'])
                child_repo = repo_name(declarations[link['path']], repo)
                child = node(child_repo, link['sha'])
                n['children'].append({'path': link['path'], 'node': child, 'kind': 'gitlink', 'gitlinkSHA': link['sha'], 'declaredURL': declarations[link['path']]})
        return key

    for name, repo, tag, expected, artifact_path in ROOTS:
        output = subprocess.check_output(['git', 'ls-remote', 'https://github.com/' + repo + '.git', 'refs/tags/' + tag, 'refs/tags/' + tag + '^{}'], text=True)
        references = {line.split()[1]: line.split()[0] for line in output.splitlines()}
        commit = references.get('refs/tags/' + tag + '^{}', references.get('refs/tags/' + tag))
        if commit != expected:
            raise ValueError('Release tag changed; review required')
        release = api(f'repos/{repo}/releases/tags/{tag}')
        artifact = json.loads((ROOT / artifact_path).read_text())
        asset_name = Path(urllib.parse.urlsplit(artifact['url']).path).name
        assets = [a for a in release['assets'] if a['name'] == asset_name and a['browser_download_url'] == artifact['url']]
        if release['tag_name'] != tag or len(assets) != 1:
            raise ValueError('Official release/asset identity mismatch')
        asset = assets[0]
        if asset.get('digest') not in [None, 'sha256:' + artifact['sha256']]:
            raise ValueError('Retained artifact hash differs from publisher digest')
        root_node = node(repo, commit)
        if name == 'moltenvk':
            n = nodes[root_node]
            entries = {x['path']: x for x in n['treeObject']['tree']}
            recipe = raw(repo, commit, 'fetchDependencies', entries['fetchDependencies']['sha'])
            n['externalRecipeSHA256'] = hashlib.sha256(recipe).hexdigest()
            for external, (child_repo, mount) in MOLTEN_EXTERNAL.items():
                revision_path = f'ExternalRevisions/{external}_repo_revision'
                revision = raw(repo, commit, revision_path, entries[revision_path]['sha']).decode().strip()
                n['children'].append({'path': mount, 'node': node(child_repo, revision), 'kind': 'upstream-fetchDependencies-revision', 'revisionFile': revision_path, 'revisionBlobSHA': entries[revision_path]['sha'], 'declaredURL': 'https://github.com/' + child_repo + '.git'})
        roots.append({'name': name, 'tag': tag, 'tagReferences': references, 'node': root_node, 'releaseURL': release['html_url'], 'releaseID': release['id'], 'artifact': artifact, 'publisherAsset': {k: asset.get(k) for k in ['id', 'name', 'size', 'digest', 'browser_download_url']}, 'artifactSourceCorrespondence': 'official-release-tag-associated; exact publisher binary build not attested', 'binaryRedistributionReady': False})
    return {'schema': 1, 'sourceScope': 'DXVK3.1.1,VKD3D-Proton3.0.1,MoltenVK1.4.2 recursive Git source trees', 'roots': roots, 'nodes': nodes, 'appleEntirelyExcluded': True, 'binaryRedistributionReady': False}


def download_node(n, stage, archive_cache=None):
    key = n['id']
    source = stage / 'repositories' / key
    archive = stage / 'archives' / (key + '.tar.gz')
    archive.parent.mkdir(parents=True, exist_ok=True)
    url = f"https://codeload.github.com/{n['repository']}/tar.gz/{n['commit']}"
    cached = archive_cache / 'archives' / (key + '.tar.gz') if archive_cache else None
    if cached is not None:
        cache_lock = json.loads((archive_cache / 'source.lock.json').read_text())
        origin = cache_lock['nodes'].get(key)
        if not origin or (origin['commit'], origin['treeSHA']) != (n['commit'], n['treeSHA']) or digest(cached) != origin['archiveSHA256']:
            raise ValueError('Source archive cache identity mismatch')
        shutil.copy2(cached, archive)
    else:
        with get(url) as src, archive.open('wb') as out:
            shutil.copyfileobj(src, out, 1024 * 1024)
    h = digest(archive)
    if n.get('archiveSHA256') and n['archiveSHA256'] != h:
        raise ValueError('Pinned archive mismatch')
    n.update(archiveURL=url, archiveSHA256=h)
    extracting = stage / ('extract-' + key)
    extracting.mkdir()
    with tarfile.open(archive) as tf:
        if sum(x.size for x in tf.getmembers()) + RESERVE > shutil.disk_usage(stage).free:
            raise RuntimeError('Not enough free disk for source extraction')
        tf.extractall(extracting, filter='data')
    children = list(extracting.iterdir())
    if len(children) != 1 or not children[0].is_dir():
        raise ValueError('Archive root changed')
    source.parent.mkdir(exist_ok=True)
    children[0].rename(source)
    extracting.rmdir()
    corrections, expected = [], set()
    for entry in n['treeObject']['tree']:
        if entry['type'] != 'blob':
            continue
        p = source / safe_path(entry['path'])
        expected.add(entry['path'])
        data = os.readlink(p).encode() if p.is_symlink() else p.read_bytes() if p.is_file() else None
        if data is None or blob(data) != entry['sha']:
            data = raw(n['repository'], n['commit'], entry['path'], entry['sha'])
            if p.is_symlink() or p.is_file():
                p.unlink()
            p.parent.mkdir(parents=True, exist_ok=True)
            if entry['mode'] == '120000':
                target = data.decode()
                resolved = (p.parent / target).resolve()
                if not resolved.is_relative_to(source.resolve()):
                    raise ValueError('Git source symlink escapes repository')
                p.symlink_to(target)
            else:
                p.write_bytes(data)
            corrections.append({'path': entry['path'], 'gitBlobSHA': entry['sha'], 'reason': 'restore exact Git content omitted/substituted by archive attributes'})
        if entry['mode'] != '120000':
            p.chmod(0o755 if entry['mode'] == '100755' else 0o644)
    actual = {str(p.relative_to(source)) for p in source.rglob('*') if p.is_file() or p.is_symlink()}
    if actual != expected:
        raise ValueError('Source tree has unexpected/missing files')
    n['archiveCorrections'] = corrections
    n['verifiedGitBlobCount'] = len(expected)
    # Whole sources preserve per-file notices; this index also collects license documents.
    notices = []
    for name in sorted(expected):
        p = source / name
        if p.is_symlink():
            continue
        if re.search(r'(?i)(license|copying|copyright|notice|authors)', p.name) or 'LICENSES' in p.parts:
            destination = stage / 'notices' / key / name
            destination.parent.mkdir(parents=True, exist_ok=True)
            shutil.copy2(p, destination)
            notices.append({'path': name, 'sha256': digest(p)})
    n['noticeDocuments'] = notices
    write(stage / 'metadata' / (key + '.json'), n)


def clone(source, target):
    target.parent.mkdir(parents=True, exist_ok=True)
    if sys_platform() == 'darwin':
        subprocess.run(['/bin/cp', '-cR', str(source), str(target)], check=True)
    else:
        shutil.copytree(source, target, symlinks=True)


def sys_platform():
    import sys
    return sys.platform


def assemble(key, destination, stage, nodes, ancestors=()):
    if key in ancestors:
        raise ValueError('Source dependency cycle')
    clone(stage / 'repositories' / key, destination)
    for child in sorted(nodes[key]['children'], key=lambda x: len(PurePosixPath(x['path']).parts)):
        target = destination / safe_path(child['path'])
        if target.exists():
            if not target.is_dir() or any(target.iterdir()):
                raise ValueError('Refusing to replace nonempty upstream source path')
            target.rmdir()
        assemble(child['node'], target, stage, nodes, ancestors + (key,))


def fingerprint(root):
    files = {}
    for p in sorted(root.rglob('*')):
        if p.name == 'packet-manifest.json':
            continue
        if p.is_symlink():
            if not p.resolve().is_relative_to(root.resolve()):
                raise ValueError('Packet symlink escapes source packet')
            files[str(p.relative_to(root))] = {'symlink': os.readlink(p)}
        elif p.is_file():
            files[str(p.relative_to(root))] = {'sha256': digest(p), 'executable': bool(p.stat().st_mode & 0o111)}
    return files


def verify(packet):
    if not (packet / '.ready-renderer-sources').is_file():
        raise ValueError('Unmarked source packet')
    manifest = json.loads((packet / 'packet-manifest.json').read_text())
    actual = fingerprint(packet)
    expected_fingerprint = hashlib.sha256(json.dumps(actual, sort_keys=True, separators=(',', ':')).encode()).hexdigest()
    if actual != manifest['files'] or expected_fingerprint != manifest['fingerprint']:
        raise ValueError('Source packet fingerprint mismatch')
    if json.loads((packet / 'source.lock.json').read_text()) != manifest['lock']:
        raise ValueError('Packet source lock differs from manifest')
    if digest(packet / 'runtime_fetch_renderer_sources.py') != manifest['lock']['recipeSHA256']:
        raise ValueError('Packet recipe hash mismatch')
    for key, n in manifest['lock']['nodes'].items():
        source = packet / 'repositories' / key
        for entry in n['treeObject']['tree']:
            if entry['type'] == 'blob':
                p = source / safe_path(entry['path'])
                data = os.readlink(p).encode() if p.is_symlink() else p.read_bytes()
                if blob(data) != entry['sha']:
                    raise ValueError('Git source blob verification failed')
    return manifest


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('operation', choices=['prepare', 'fetch', 'verify'])
    parser.add_argument('--packet', type=Path)
    parser.add_argument('--archive-cache', type=Path, help='Reuse only verified pinned archives from a previously acquired marked packet')
    args = parser.parse_args()
    if args.operation == 'verify':
        if not args.packet:
            parser.error('--packet is required for verify')
        result = verify(args.packet)
        print(json.dumps({'verified': True, 'packet': str(args.packet), 'fingerprint': result['fingerprint'], 'binaryRedistributionReady': False}))
        return
    if args.operation == 'prepare' and args.archive_cache:
        # Repackage verified sources/primary metadata without another API resolve.
        lock = verify(args.archive_cache)['lock']
        expected_roots = {(name, repo.lower(), tag, commit) for name, repo, tag, commit, _ in ROOTS}
        cached_roots = {(r['name'], lock['nodes'][r['node']]['repository'].lower(), r['tag'], lock['nodes'][r['node']]['commit']) for r in lock['roots']}
        if cached_roots != expected_roots:
            raise ValueError('Cached packet is not the expected three exact release roots')
    else:
        lock = resolve() if args.operation == 'prepare' else json.loads(LOCK.read_text())
    recipe_hash = digest(Path(__file__))
    if args.operation == 'fetch' and lock.get('recipeSHA256') != recipe_hash:
        raise ValueError('Use the exact committed recipe matching this source lock')
    if args.archive_cache:
        verify(args.archive_cache)
    # Source files + archives + APFS-clone metadata. Preserve room for other agents.
    estimate = sum(e.get('size', 0) for n in lock['nodes'].values() for e in n['treeObject']['tree'] if e['type'] == 'blob')
    available = shutil.disk_usage(ROOT).free
    if available < estimate * 2 + RESERVE:
        raise RuntimeError(f'Insufficient disk: need conservative {estimate * 2 + RESERVE} bytes, have {available}')
    BASE.mkdir(parents=True, exist_ok=True)
    identity = hashlib.sha256(json.dumps({'recipeSHA256': recipe_hash, 'sources': {k: (n['repository'], n['commit'], n['treeSHA']) for k, n in lock['nodes'].items()}}, sort_keys=True).encode()).hexdigest()[:20]
    packet = BASE / ('renderer-sources-' + identity)
    if packet.exists():
        result = verify(packet)
        if args.operation == 'fetch' and result['lock'] != lock:
            raise ValueError('Existing source packet differs from the selected lock')
        print(json.dumps({'verifiedExisting': True, 'packet': str(packet), 'fingerprint': result['fingerprint']}))
        return
    stage = packet.with_name(packet.name + '.preparing')
    stage.mkdir(mode=0o700)
    (stage / '.ready-renderer-sources').write_text('Owned versioned corresponding-source packet; no binaries built\n')
    print(json.dumps({'nodes': len(lock['nodes']), 'estimatedSourceBytes': estimate, 'freeBefore': available}), flush=True)
    for key, n in sorted(lock['nodes'].items()):
        print('Fetching source ' + n['repository'] + '@' + n['commit'], flush=True)
        download_node(n, stage, args.archive_cache)
    for root in lock['roots']:
        assemble(root['node'], stage / 'trees' / (root['name'] + '-' + root['tag']), stage, lock['nodes'])
    lock['recipeSHA256'] = recipe_hash
    lock['recipeLicenseSHA256'] = digest(ROOT / 'LICENSE')
    shutil.copy2(ROOT / 'LICENSE', stage / 'recipe-LICENSE')
    write(stage / 'source.lock.json', lock)
    write(stage / 'recipe.json', {'scriptSHA256': recipe_hash, 'sourceOnly': True, 'upstreamCodeExecuted': False, 'mode': args.operation, 'sourceBytesEstimated': estimate, 'publicPrimaryURLsOnly': True})
    shutil.copy2(Path(__file__), stage / 'runtime_fetch_renderer_sources.py')
    files = fingerprint(stage)
    identity = hashlib.sha256(json.dumps(files, sort_keys=True, separators=(',', ':')).encode()).hexdigest()
    write(stage / 'packet-manifest.json', {'schema': 1, 'fingerprint': identity, 'files': files, 'lock': lock, 'completeRecursiveGitSources': True, 'artifactBinaryBuildAttested': False, 'binaryRedistributionReady': False, 'appleEntirelyExcluded': True})
    stage.rename(packet)
    verify(packet)
    if args.operation == 'prepare':
        write(LOCK, lock)
    report = {'packet': str(packet), 'fingerprint': identity, 'nodes': len(lock['nodes']), 'completeRecursiveGitSources': True, 'artifactBinaryBuildAttested': False, 'binaryRedistributionReady': False, 'appleEntirelyExcluded': True, 'recipeSHA256': recipe_hash}
    print(json.dumps(report, indent=2))


if __name__ == '__main__':
    main()
