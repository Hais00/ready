#!/usr/bin/env python3
"""Download public upstream sources; pin archives and hashes. Never execute vendor code."""
import concurrent.futures, datetime, hashlib, json, pathlib, re, shutil, tarfile, urllib.request
ROOT = pathlib.Path(__file__).resolve().parents[1]
VENDOR = ROOT / "Vendor"
VENDOR.mkdir(exist_ok=True)
def get(url):
    return urllib.request.urlopen(urllib.request.Request(url, headers={"User-Agent": "M1Launcher-source-fetcher"}), timeout=90)
def github(repo, ref=None):
    if ref is None:
        releases = json.load(get(f"https://api.github.com/repos/{repo}/releases?per_page=20"))
        releases = [r for r in releases if not r['draft']]
        ref = releases[0]['tag_name'] if releases else json.load(get(f"https://api.github.com/repos/{repo}"))['default_branch']
    return ref, f"https://codeload.github.com/{repo}/tar.gz/{ref}"
def obtain(item):
    name, ref, url = item
    dest = VENDOR / name
    meta = VENDOR / (name + ".source.json")
    if dest.exists() and meta.exists(): return json.loads(meta.read_text())
    archive = VENDOR / (name + ".partial")
    print(f"Downloading {name} {ref}", flush=True)
    digest = hashlib.sha256()
    with get(url) as src, archive.open("wb") as out:
        while chunk := src.read(1024*1024): out.write(chunk); digest.update(chunk)
    staging = VENDOR / (name + ".extracting")
    staging.mkdir(exist_ok=True)
    with tarfile.open(archive) as tar: tar.extractall(staging, filter="data")
    roots = list(staging.iterdir())
    if len(roots) == 1 and roots[0].is_dir(): roots[0].rename(dest); staging.rmdir()
    else: staging.rename(dest)
    archive.unlink()
    record = dict(name=name, version=ref, url=url, sha256=digest.hexdigest(), fetched_at=datetime.datetime.now(datetime.timezone.utc).isoformat())
    meta.write_text(json.dumps(record, indent=2)+"\n")
    print(f"Ready {name}", flush=True)
    return record
def main():
    wine_index = get("https://dl.winehq.org/wine/source/11.x/").read().decode()
    versions = sorted(set(re.findall(r'wine-(11\.\d+)\.tar\.xz', wine_index)), key=lambda s: tuple(map(int,s.split('.'))))
    wine = versions[-1]
    mesa_index = get("https://archive.mesa3d.org/").read().decode()
    mesa_versions = sorted(set(re.findall(r'mesa-([\d.]+(?:-rc\d+)?)\.tar\.xz', mesa_index)), key=lambda s: (tuple(map(int,s.split('-')[0].split('.'))), '-rc' not in s, s))
    mesa = mesa_versions[-1]
    jobs = [('wine', wine, f'https://dl.winehq.org/wine/source/11.x/wine-{wine}.tar.xz'),
            ('mesa', mesa, f'https://archive.mesa3d.org/mesa-{mesa}.tar.xz')]
    for name,repo,ref in [('moltenvk','KhronosGroup/MoltenVK',None), ('dxvk','doitsujin/dxvk',None),
                          ('vkd3d-proton','HansKristian-Work/vkd3d-proton',None), ('steamkit','SteamRE/SteamKit',None),
                          ('gptk-resources','apple/game-porting-toolkit','main'), ('apple-homebrew','apple/homebrew-apple','main')]:
        try:
            ver,url=github(repo,ref); jobs.append((name,ver,url))
        except Exception as e: print(f'Metadata error {repo}: {e}',flush=True)
    records=[]
    with concurrent.futures.ThreadPoolExecutor(max_workers=2) as pool:
        futures = {pool.submit(obtain,j): j[0] for j in jobs}
        for f in concurrent.futures.as_completed(futures):
            try: records.append(f.result())
            except Exception as e: records.append({'name':futures[f], 'error':str(e)});print(str(e),flush=True)
            (ROOT/'sources.lock.json').write_text(json.dumps(sorted(records,key=lambda x:x['name']),indent=2)+'\n')
if __name__ == '__main__': main()
