#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-only
"""Write versioned central runtime paths. Capabilities require successful real probes."""
import json
import os
import pathlib
import shutil
import hashlib

ROOT=pathlib.Path(__file__).resolve().parents[1]
RUNTIME=ROOT/"Runtime"

def main():
    import argparse
    parser=argparse.ArgumentParser();parser.add_argument('--staging',action='store_true');args=parser.parse_args()
    existing=RUNTIME/'runtime.json'
    if not args.staging and existing.exists():
        current=json.loads(existing.read_text())
        if current.get('immutableRuntimeSet'):
            print(json.dumps(current,indent=2));return
    bin_dir=RUNTIME/"bin";bin_dir.mkdir(exist_ok=True)
    wrapper=bin_dir/"ready-wine"
    wrapper.write_text('''#!/bin/sh
# SPDX-License-Identifier: GPL-3.0-only
set -u
READY_RUNTIME=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
READY_WINE="$READY_RUNTIME/wine-11.20/bin/wine"
READY_SERVER="$READY_RUNTIME/wine-11.20/bin/wineserver"
export DYLD_LIBRARY_PATH="$READY_RUNTIME/vulkan-sdk-1.4.366/lib:$READY_RUNTIME/wine-deps/lib${DYLD_LIBRARY_PATH:+:$DYLD_LIBRARY_PATH}"
export DYLD_FALLBACK_LIBRARY_PATH="$DYLD_LIBRARY_PATH"
# Apple's protected shell strips DYLD_* on entry. Carry our path in a normal
# variable and restore it only for the unprotected, locally built Wine child.
if [ -n "${READY_OVERLAY_LIBRARY:-}" ] && [ -f "$READY_OVERLAY_LIBRARY" ]; then
  export DYLD_INSERT_LIBRARIES="$READY_OVERLAY_LIBRARY"
fi
case "${1:-}" in --version|--help) exec "$READY_WINE" "$@" ;; esac
if [ -z "${WINEPREFIX:-}" ]; then
  echo 'ready-wine requires an explicit per-game/per-profile WINEPREFIX' >&2
  exit 64
fi
trap '"$READY_SERVER" -k >/dev/null 2>&1 || true' TERM INT HUP
"$READY_WINE" "$@" &
READY_CHILD=$!
wait "$READY_CHILD"
READY_STATUS=$?
# Wine's initial process may exit before its game child. Keep the session lease alive.
"$READY_SERVER" -w
exit "$READY_STATUS"
''')
    wrapper.chmod(0o755)
    engines=RUNTIME/"engines";engines.mkdir(exist_ok=True)
    dxvk=RUNTIME/"dxvk-3.1.1/x64"
    vkd3d=RUNTIME/"vkd3d-proton-3.0.1/x64"
    vkd3d_engine=engines/"vkd3d-kosmic-3.0.1";vkd3d_engine.mkdir(exist_ok=True)
    if vkd3d.exists():
        for name in ["d3d12.dll","d3d12core.dll"]:
            source=vkd3d/name
            if source.exists():shutil.copy2(source,vkd3d_engine/name)
    if (dxvk/"dxgi.dll").exists():shutil.copy2(dxvk/"dxgi.dll",vkd3d_engine/"dxgi.dll")
    wine=RUNTIME/"wine-11.20/bin/wine"
    verified=[]
    evidence=ROOT/"Evidence/runtime-engine-probes.json"
    if evidence.exists():
        probes=json.loads(evidence.read_text())
        module=RUNTIME/'wine-11.20/lib/wine/x86_64-unix/win32u.so'
        matches_module=module.is_file() and probes.get('wineModuleSHA256')==hashlib.sha256(module.read_bytes()).hexdigest()
        for engine,result in (probes.get("engines",{}).items() if probes.get("strictNativeDLLs") and matches_module else []):
            if result.get("wineVersion")=="wine-11.20" and result.get("exitCode")==0 and result.get("verified")==True:
                verified.append(engine)
    config={"wine":str(wrapper) if wine.exists() else None,
        "wineVersion":"wine-11.20" if wine.exists() else None,
        "wineServer":str(RUNTIME/"wine-11.20/bin/wineserver") if wine.exists() else None,
        "wineBoot":None,
        "builtin32Directory":str(RUNTIME/"wine-11.20/lib/wine/i386-windows"),
        "kosmicICD":str(RUNTIME/"mesa-x64-26.3.0-rc2/share/vulkan/icd.d/kosmickrisp_mesa_icd.x86_64.json"),
        "moltenICD":str(RUNTIME/"moltenvk-1.4.2/MoltenVK/dynamic/dylib/macOS/MoltenVK_icd.json"),
        "vulkanLibrary":str(RUNTIME/"vulkan-sdk-1.4.366/lib/libvulkan.1.dylib"),
        "engineDLLs":{"dxvkKosmic":str(dxvk),"dxvkMolten":str(dxvk),"vkd3dKosmic":str(vkd3d_engine)},
        "verifiedEngines":verified,
        "engineAPIs":{key:(["d3d9"] if key=="wineD3D" else ["vulkan"] if key in ["vulkanKosmic","vulkanMolten"] else ["d3d11"] if key.startswith("dxvk") else ["d3d12"] if key.startswith("vkd3d") else []) for key in verified},
        "componentVersions":{"wine":"11.20","kosmicKrisp":"26.3.0-rc2","moltenVK":"1.4.2","vulkanLoader":"1.4.366","dxvk":"3.1.1","vkd3dProton":"3.0.1","appleEvaluation":"4.0 beta 3"},
        "appleOptional":{"installedLocally":True,"sourceOpen":False,"wineABIValidated":False,"enabled":False},
        "capabilityNote":"Native ICD GPU readback is verified separately. DLL presence alone does not establish Wine/DirectX compatibility."}
    output=RUNTIME/("staging-runtime.json" if args.staging else "runtime.json")
    output.write_text(json.dumps(config,indent=2)+'\n')
    print(json.dumps(config,indent=2))
if __name__=="__main__":main()
