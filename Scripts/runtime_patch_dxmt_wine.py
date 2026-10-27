#!/usr/bin/env python3
# SPDX-License-Identifier: LGPL-2.1-or-later
"""Build Wine 11.20's explicit legacy-window ABI adapter for pinned DXMT.

This compiles a copied LGPL Wine source file, retains original Vendor untouched,
and installs only into the isolated DXMT experiment. No live runtime set changes.
"""
import difflib
import hashlib
import json
import os
import pathlib
import shlex
import shutil
import subprocess

ROOT=pathlib.Path(__file__).resolve().parents[1]
SOURCE=ROOT/'Vendor/wine/dlls/winemac.drv/window.c'
BUILD=ROOT/'Runtime/build-wine-11.20'
STAGING=ROOT/'Runtime/wine-ready-dxmt-adapter'
ADAPTER=r'''

struct ready_dxmt_win_data
{
    HWND hwnd;
    WineWindow *cocoa_window;
    WineContentView *cocoa_view;
    WineContentView *client_cocoa_view;
};

static CFMutableDictionaryRef ready_dxmt_views;
static __thread struct ready_dxmt_win_data ready_dxmt_legacy;
static __thread struct macdrv_win_data *ready_dxmt_locked;

static struct ready_dxmt_win_data *ready_dxmt_get_win_data(HWND hwnd)
{
    struct macdrv_win_data *data = get_win_data(hwnd);
    ready_dxmt_locked = data;
    if (!data) return NULL;
    ready_dxmt_legacy.hwnd = hwnd;
    ready_dxmt_legacy.cocoa_window = data ? data->cocoa_window : NULL;
    ready_dxmt_legacy.cocoa_view = NULL;
    ready_dxmt_legacy.client_cocoa_view = NULL;
    if (data && !data->client_view && data->cocoa_window)
    {
        WineContentView *view = macdrv_create_view(cgrect_from_rect(data->rects.client));
        if (!ready_dxmt_views) ready_dxmt_views = CFDictionaryCreateMutable(NULL, 0, NULL, NULL);
        if (!view || !ready_dxmt_views)
        {
            if (view) macdrv_dispose_view(view);
            release_win_data(data);
            ready_dxmt_locked = NULL;
            return NULL;
        }
        CFDictionarySetValue(ready_dxmt_views, hwnd, view);
        macdrv_set_view_superview(view, NULL, data->cocoa_window, NULL, NULL);
        macdrv_set_view_hidden(view, FALSE);
        data->client_view = view;
    }
    if (data)
    {
        ready_dxmt_legacy.cocoa_view = data->client_view;
        ready_dxmt_legacy.client_cocoa_view = data->client_view;
    }
    return &ready_dxmt_legacy;
}

static void ready_dxmt_release_win_data(struct ready_dxmt_win_data *legacy)
{
    struct macdrv_win_data *data = ready_dxmt_locked;
    if (legacy != &ready_dxmt_legacy) return;
    ready_dxmt_locked = NULL;
    release_win_data(data);
}

static WineWindow *ready_dxmt_get_cocoa_window(HWND hwnd, BOOL require_on_screen)
{
    return macdrv_get_cocoa_window(hwnd, require_on_screen != FALSE);
}

static void ready_dxmt_update_view(struct macdrv_win_data *data)
{
    WineContentView *view;
    if (!ready_dxmt_views || !(view = (WineContentView *)CFDictionaryGetValue(ready_dxmt_views, data->hwnd))) return;
    macdrv_set_view_frame(view, cgrect_from_rect(data->rects.client));
    macdrv_set_view_superview(view, NULL, data->cocoa_window, NULL, NULL);
}

static void ready_dxmt_dispose_view(struct macdrv_win_data *data)
{
    WineContentView *view;
    if (!ready_dxmt_views || !(view = (WineContentView *)CFDictionaryGetValue(ready_dxmt_views, data->hwnd))) return;
    CFDictionaryRemoveValue(ready_dxmt_views, data->hwnd);
    if (data->client_view == view) data->client_view = NULL;
    macdrv_dispose_view(view);
}

struct ready_dxmt_functions
{
    void (*unused_init_display_devices)(BOOL);
    struct ready_dxmt_win_data *(*get_win_data)(HWND);
    void (*release_win_data)(struct ready_dxmt_win_data *);
    WineWindow *(*get_cocoa_window)(HWND, BOOL);
    MTLDevice_id (*create_metal_device)(void);
    void (*release_metal_device)(MTLDevice_id);
    WineMetalView *(*create_metal_view)(WineContentView *, MTLDevice_id);
    CAMetalLayer *(*get_metal_layer)(WineMetalView *);
    void (*release_metal_view)(WineMetalView *);
    void *unused_on_main_thread;
};

__attribute__((visibility("default")))
const struct ready_dxmt_functions macdrv_functions =
{
    NULL,
    ready_dxmt_get_win_data,
    ready_dxmt_release_win_data,
    ready_dxmt_get_cocoa_window,
    macdrv_create_metal_device,
    macdrv_release_metal_device,
    macdrv_view_create_metal_view,
    macdrv_view_get_metal_layer,
    macdrv_view_release_metal_view,
    NULL
};
'''

def digest(path):return hashlib.sha256(path.read_bytes()).hexdigest()
def main():
    original=SOURCE.read_text()
    forward='static void ready_dxmt_update_view(struct macdrv_win_data *data);\nstatic void ready_dxmt_dispose_view(struct macdrv_win_data *data);\n'
    source=original.replace('static CFMutableDictionaryRef win_datas;','static CFMutableDictionaryRef win_datas;\n'+forward)
    anchor='static void sync_window_position(struct macdrv_win_data *data, UINT swp_flags, const struct window_rects *old_rects)\n{'
    if source.count(anchor)!=1:raise RuntimeError('Wine window position ABI anchor changed')
    source=source.replace(anchor,anchor+'\n    ready_dxmt_update_view(data);')
    anchor='    if (data->drag_event) NtSetEvent(data->drag_event, NULL);\n\n    destroy_cocoa_window(data);'
    if source.count(anchor)!=1:raise RuntimeError('Wine window destruction ABI anchor changed')
    source=source.replace(anchor,'    if (data->drag_event) NtSetEvent(data->drag_event, NULL);\n\n    ready_dxmt_dispose_view(data);\n    destroy_cocoa_window(data);')+ADAPTER
    STAGING.mkdir(exist_ok=True);adapted=STAGING/'window.c';adapted.write_text(source)
    (ROOT/'Scripts/runtime_wine_dxmt_window.patch').write_text(''.join(difflib.unified_diff(original.splitlines(keepends=True),source.splitlines(keepends=True),fromfile='a/dlls/winemac.drv/window.c',tofile='b/dlls/winemac.drv/window.c')))
    env=dict(os.environ);env['PATH']='/opt/homebrew/opt/bison/bin:/opt/homebrew/opt/flex/bin:/opt/homebrew/opt/llvm/bin:/opt/homebrew/bin:/usr/bin:/bin'
    env['DYLD_LIBRARY_PATH']=str(ROOT/'Runtime/wine-deps/lib')+':'+str(ROOT/'Runtime/vulkan-sdk-1.4.366/lib')
    flags=['CFLAGS=-O2 -g0 -U_FORTIFY_SOURCE -D_FORTIFY_SOURCE=0','i386_CFLAGS=-O2 -g0','x86_64_CFLAGS=-O2 -g0']
    subprocess.run(['/opt/homebrew/bin/gmake','-j3',*flags,'dlls/winemac.drv/winemac.so'],cwd=BUILD,env=env,check=True)
    dry=subprocess.check_output(['/opt/homebrew/bin/gmake','-n','-W','../../Vendor/wine/dlls/winemac.drv/window.c',*flags,'dlls/winemac.drv/window.o'],cwd=BUILD,env=env,text=True)
    line=next(x for x in dry.replace('\\\n',' ').splitlines() if '-c -o dlls/winemac.drv/window.o ' in x)
    args=shlex.split(line);old='../../Vendor/wine/dlls/winemac.drv/window.c'
    if args.count(old)!=1:raise RuntimeError('Unexpected Wine driver compile command')
    subprocess.run([str(adapted) if x==old else x for x in args],cwd=BUILD,env=env,check=True)
    subprocess.run(['/opt/homebrew/bin/gmake','-j3',*flags,'dlls/winemac.drv/winemac.so'],cwd=BUILD,env=env,check=True)
    built=BUILD/'dlls/winemac.drv/winemac.so';symbols=subprocess.check_output(['/usr/bin/nm','-gU',str(built)],text=True)
    if '_macdrv_functions' not in symbols:raise RuntimeError('Expected adapter table was not exported')
    record={'wineVersion':'11.20','dxmtSourceCommit':'3b252590cb0290e36fca6f088b5255b871d2d95a','originalSourceSHA256':digest(SOURCE),'adaptedSourceSHA256':digest(adapted),'moduleSHA256':digest(built),'license':'LGPL-2.1-or-later','tableExported':True,'vendorSourceUnmodified':True,'installed':False}
    shutil.copy2(built,STAGING/'winemac.so')
    (ROOT/'Evidence/runtime-dxmt-window-adapter.json').write_text(json.dumps(record,indent=2)+'\n');print(json.dumps(record,indent=2))
if __name__=='__main__':main()
