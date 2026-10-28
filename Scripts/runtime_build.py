#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-only
"""Local reproducible runtime builds; no system install and no security-policy changes."""
import argparse
import os
import pathlib
import subprocess
import hashlib
import json
import shutil

ROOT = pathlib.Path(__file__).resolve().parents[1]
SHORT = pathlib.Path("/tmp") / ("ready-runtime-" + str(os.getuid()))

def short_root():
    if SHORT.is_symlink():
        if SHORT.resolve() != ROOT:
            raise RuntimeError("Build alias belongs to another source directory")
    elif SHORT.exists():
        raise RuntimeError("Refusing to replace an existing build alias")
    else:
        SHORT.symlink_to(ROOT, target_is_directory=True)
    return SHORT

def run(argv, cwd=ROOT, env=None):
    print("Running:", " ".join(map(str, argv)), flush=True)
    subprocess.run(list(map(str, argv)), cwd=cwd, env=env, check=True)

def configure_wine():
    short_root()
    build = ROOT / "Runtime/build-wine-11.20"
    build.mkdir(parents=True, exist_ok=True)
    base = SHORT / "Runtime/wine-deps/lib"
    if not (base/"libfreetype.dylib").exists() or not (base/"libgnutls.dylib").exists():
        raise RuntimeError("Run runtime_fetch.py --wine-deps-only before configuring Wine")
    sdk = SHORT / "Runtime/vulkan-sdk-1.4.366"
    env = dict(os.environ)
    env["PATH"] = "/opt/homebrew/opt/bison/bin:/opt/homebrew/opt/flex/bin:/opt/homebrew/opt/llvm/bin:/opt/homebrew/bin:/usr/bin:/bin"
    env["CC"] = "/usr/bin/clang -arch x86_64"
    env["CXX"] = "/usr/bin/clang++ -arch x86_64"
    env["CROSSCC"] = "/opt/homebrew/opt/llvm/bin/clang"
    env["CROSSCXX"] = "/opt/homebrew/opt/llvm/bin/clang++"
    env["CFLAGS"] = "-O2 -g0"
    env["CXXFLAGS"] = "-O2 -g0"
    env["LDFLAGS"] = f"-L{sdk}/lib -L{base} -Wl,-rpath,{sdk}/lib -Wl,-rpath,{base}"
    env["DYLD_FALLBACK_LIBRARY_PATH"] = str(base)
    env["VULKAN_LIBS"] = f"-L{sdk}/lib -lvulkan"
    headers=SHORT/"Runtime/dependency-headers"
    gnutls_headers=sorted((headers/"gnutls").glob('*/include'))
    freetype_headers=sorted((headers/"freetype").glob('*/include/freetype2'))
    if not gnutls_headers or not freetype_headers:raise RuntimeError('Run runtime_fetch.py --dependency-headers')
    env["GNUTLS_CFLAGS"] = f"-I{gnutls_headers[-1]}"
    env["GNUTLS_LIBS"] = f"-L{base} -lgnutls"
    env["FREETYPE_CFLAGS"] = f"-I{freetype_headers[-1]}"
    env["FREETYPE_LIBS"] = f"-L{base} -lfreetype"
    # Community dependency dylibs use bare LC_ID_DYLIB names. Wine's otool
    # parser otherwise captures the trailing '(compatibility version ...)' text.
    env["ac_cv_lib_soname_freetype"]="libfreetype.6.dylib"
    env["ac_cv_lib_soname_gnutls"]="libgnutls.30.dylib"
    env["ac_cv_lib_soname_vulkan"]="libvulkan.1.dylib"
    options = ["../../Vendor/wine/configure", f"--prefix={SHORT}/Runtime/wine-11.20",
        "--host=x86_64-apple-darwin", "--build=x86_64-apple-darwin", "--enable-win64",
        "--enable-archs=x86_64,i386", "--disable-tests", "--with-vulkan", "--with-gnutls", "--with-freetype",
        "--without-x", "--without-gstreamer", "--without-dbus", "--without-pulse", "--without-alsa",
        "--without-cups", "--without-sane", "--without-gphoto", "--without-usb", "--without-krb5",
        "--without-oss", "--without-sdl"]
    run(options, cwd=build, env=env)

def build_wine(jobs):
    short_root()
    env=dict(os.environ)
    env["PATH"]="/opt/homebrew/opt/bison/bin:/opt/homebrew/opt/flex/bin:/opt/homebrew/opt/llvm/bin:/opt/homebrew/bin:/usr/bin:/bin"
    env["DYLD_LIBRARY_PATH"]=str(SHORT/"Runtime/wine-deps/lib")+":"+str(SHORT/"Runtime/vulkan-sdk-1.4.366/lib")
    env["DYLD_FALLBACK_LIBRARY_PATH"]=env["DYLD_LIBRARY_PATH"]
    flags=["CFLAGS=-O2 -g0 -U_FORTIFY_SOURCE -D_FORTIFY_SOURCE=0", "i386_CFLAGS=-O2 -g0", "x86_64_CFLAGS=-O2 -g0"]
    # The protected Apple make strips DYLD_* before invoking build-time tools.
    # Homebrew GNU make preserves the local dependency path without any SIP change.
    make="/opt/homebrew/bin/gmake"
    if not pathlib.Path(make).exists():raise RuntimeError('Homebrew GNU make is required for local dylib build dependencies')
    # Experimental copied-source adapters use these same intermediate targets.
    # A normal upstream build must rebuild them from pristine Vendor sources;
    # its immutable provider projections are never touched here.
    for relative in ['dlls/win32u/vulkan.o','dlls/winemac.drv/window.o','dlls/ntdll/unix/signal_x86_64.o']:
        (ROOT/'Runtime/build-wine-11.20'/relative).unlink(missing_ok=True)
    run([make, f"-j{jobs}", *flags], cwd=ROOT/"Runtime/build-wine-11.20", env=env)
    run([make, "install", *flags], cwd=ROOT/"Runtime/build-wine-11.20", env=env)

def build_dwrite(jobs):
    """Correct the old configured SONAME in a candidate module, never installed live."""
    short_root();build=ROOT/'Runtime/build-wine-11.20'
    configuration=(build/'include/config.h').read_text()
    if '#define SONAME_LIBFREETYPE "libfreetype.6.dylib"' not in configuration:
        raise RuntimeError('Configure Wine with the explicit FreeType SONAME first')
    env=dict(os.environ);env['PATH']='/opt/homebrew/opt/bison/bin:/opt/homebrew/opt/flex/bin:/opt/homebrew/opt/llvm/bin:/opt/homebrew/bin:/usr/bin:/bin'
    env['DYLD_LIBRARY_PATH']=str(SHORT/'Runtime/vulkan-sdk-1.4.366/lib')+':'+str(SHORT/'Runtime/wine-deps/lib')
    # The observer experiment may have used this intermediate. Restore pristine
    # source compilation before linking the standalone candidate module.
    (build/'dlls/ntdll/unix/signal_x86_64.o').unlink(missing_ok=True)
    for path in (build/'dlls/dwrite').glob('*.o'):path.unlink()
    flags=['CFLAGS=-O2 -g0 -U_FORTIFY_SOURCE -D_FORTIFY_SOURCE=0','CXXFLAGS=-O2 -g0','i386_CFLAGS=-O2 -g0','x86_64_CFLAGS=-O2 -g0']
    command=['/opt/homebrew/bin/gmake','-j'+str(jobs),*flags,'dlls/dwrite/dwrite.so'];run(command,cwd=build,env=env)
    output=ROOT/'Runtime/SourceRuntimeModules';output.mkdir(exist_ok=True);target=output/'wine-11.20-dwrite.so';shutil.copy2(build/'dlls/dwrite/dwrite.so',target)
    if b'libfreetype.6.dylib\0' not in target.read_bytes() or b'libfreetype.dylib (compatibility' in target.read_bytes():raise RuntimeError('Candidate FreeType SONAME is not correct')
    source=ROOT/'Vendor/wine/dlls/dwrite/freetype.c'
    record={'source':str(source.relative_to(ROOT)),'sourceSHA256':hashlib.sha256(source.read_bytes()).hexdigest(),'moduleSHA256':hashlib.sha256(target.read_bytes()).hexdigest(),'soname':'libfreetype.6.dylib','recipeScriptSHA256':hashlib.sha256(pathlib.Path(__file__).read_bytes()).hexdigest(),'command':command,'cwd':str(build),'vendorModified':False,'oldFrozenModuleModified':False}
    (ROOT/'Evidence/runtime-dwrite-source-rebuild.json').write_text(json.dumps(record,indent=2)+'\n');print(json.dumps(record))

def build_loader(jobs):
    sdk=ROOT/"Runtime/vulkan-sdk-1.4.366"
    run(["cmake","-S","Runtime/vulkan-headers-1.4.366","-B","Runtime/build-vulkan-headers",f"-DCMAKE_INSTALL_PREFIX={sdk}"])
    run(["cmake","--install","Runtime/build-vulkan-headers"])
    run(["cmake","-S","Runtime/vulkan-loader-1.4.366","-B","Runtime/build-vulkan-loader","-G","Ninja",
         "-DCMAKE_OSX_ARCHITECTURES=arm64;x86_64","-DCMAKE_BUILD_TYPE=Release",f"-DCMAKE_INSTALL_PREFIX={sdk}",
         f"-DVULKAN_HEADERS_INSTALL_DIR={sdk}","-DBUILD_TESTS=OFF"])
    run(["cmake","--build","Runtime/build-vulkan-loader",f"-j{jobs}"])
    run(["cmake","--install","Runtime/build-vulkan-loader"])

def build_mesa(jobs):
    env=dict(os.environ)
    env["PATH"]="/opt/homebrew/opt/llvm/bin:/opt/homebrew/bin:/usr/bin:/bin"
    common=["-Dbuildtype=release","-Dplatforms=macos","-Dvulkan-drivers=kosmickrisp","-Dgallium-drivers=",
            "-Dopengl=false","-Degl=disabled","-Dgbm=disabled","-Dglx=disabled","-Dbuild-tests=false"]
    build=ROOT/"Runtime/build-mesa-26.3.0-rc2"
    if not (build/"build.ninja").exists():
        run(["meson","setup",build,"Vendor/mesa",f"--prefix={ROOT}/Runtime/mesa-26.3.0-rc2",*common,"-Dllvm=enabled","-Dshared-llvm=enabled"],env=env)
    run(["ninja","-C",build,f"-j{jobs}"],env=env)
    run(["ninja","-C",build,"install"],env=env)
    cross=ROOT/"Runtime/meson-x86_64.ini"
    cross.write_text("""[binaries]
c = ['/usr/bin/clang', '-arch', 'x86_64']
cpp = ['/usr/bin/clang++', '-arch', 'x86_64']
objc = ['/usr/bin/clang', '-arch', 'x86_64']
objcpp = ['/usr/bin/clang++', '-arch', 'x86_64']
ar = '/usr/bin/ar'
strip = '/usr/bin/strip'
pkg-config = '/opt/homebrew/bin/pkg-config'
[host_machine]
system = 'darwin'
cpu_family = 'x86_64'
cpu = 'x86_64'
endian = 'little'
[properties]
needs_exe_wrapper = true
""")
    env["PATH"]=str(build/"src/compiler/clc")+":"+str(build/"src/compiler/spirv")+":"+str(build/"src/kosmickrisp/clc")+":"+env["PATH"]
    x64=ROOT/"Runtime/build-mesa-x64-26.3.0-rc2"
    if not (x64/"build.ninja").exists():
        run(["meson","setup",x64,"Vendor/mesa","--cross-file",cross,f"--prefix={ROOT}/Runtime/mesa-x64-26.3.0-rc2",*common,
             "-Dllvm=disabled","-Dspirv-tools=disabled","-Dmesa-clc=system","-Dprecomp-compiler=system","-Dzstd=disabled"],env=env)
    run(["ninja","-C",x64,f"-j{jobs}"],env=env)
    run(["ninja","-C",x64,"install"],env=env)

if __name__ == "__main__":
    parser=argparse.ArgumentParser()
    parser.add_argument("operation", choices=["configure-wine", "build-wine", "build-loader", "build-mesa", "build-dwrite"])
    parser.add_argument("--jobs", type=int, default=3)
    args=parser.parse_args()
    if args.operation=="configure-wine": configure_wine()
    elif args.operation=="build-wine": build_wine(args.jobs)
    elif args.operation=="build-loader": build_loader(args.jobs)
    elif args.operation=="build-dwrite": build_dwrite(args.jobs)
    else: build_mesa(args.jobs)
