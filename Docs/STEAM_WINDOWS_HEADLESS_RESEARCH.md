<!-- SPDX-License-Identifier: GPL-3.0-only -->
# Windows Steam host: measured prototype and remaining work

The independent GPL-3.0-only probe loads the genuine Valve Windows client in a separate Wine process and obtains `CLIENTENGINE_INTERFACE_VERSION005` and `SteamClient023`, on PE32 and PE64. The subsequent opt-in bootstrap also creates and releases a disconnected user through measured Valve C exports. It does not authenticate an account or launch a game. A returned factory object is not evidence of login, ownership, Steamworks IPC, or game compatibility.

## Inputs and provenance

The inspected GameNative source is pinned to `eaa715cf38fddfea6f8d1278c7dd89c0bb50e063`. Its `PluviaMain.kt` selects `steamhost-20261021.tzst`; `SteamService.kt` downloads it from `https://downloads.gamenative.app/steamhost-20261021.tzst`. The retained archive is 56,292,091 bytes, SHA256 `ff15ac383e6ceefd7e3e6e0f01c1c931a79d39d671d74653ec9780b779e77ec1`.

GameNative's THIRD_PARTY_NOTICES identifies its headless helper as proprietary, with source withheld. Its `steam.exe` and `steamhost64.exe` are byte-identical PE64 images; `steamhost32.exe` is PE32. Those helpers were inspected statically and never executed. They are not copied into Ready, its package, or its source implementation. Their package-bound token handling is not reproduced.

The six selected Valve DLLs (`steamclient`, `tier0_s`, `vstdlib_s`, in both architectures) independently pass full Authenticode verification with osslsigncode 2.14 against the system CA bundle: PE digest, signature, and chain verification succeed, with Valve Corp. as signer. Hashes, commands, verifier source commit, verifier hash, and verification logs are retained in `authenticode-verification.json`. This establishes the inspected DLL identity; it grants no redistribution rights. Valve's files remain proprietary external inputs.

## Static interoperability facts

The helper resolves `CreateInterface`, `Steam_BGetCallback`, and `Steam_FreeLastCallback`. Factory calls ask for engine005; log/call-site anchors identify creation of a global user, IClientUser, IClientFriends, IClientUserStats, and IClientAppManager. Authentication method names include SetLoginToken, SetAccountNameForCachedCredentialLogin, CanLogonOffline, LogOnOffline, and LogOn. LaunchApp has separate app ID, launch option, and parameters. Exact private method ABI and authenticated behavior are not established by these names alone.

The helper has no direct USER32/GDI32 imports. The archive contains SteamUI.dll and omits steamwebhelper.exe. The observed steamwebhelper string is used in process-tree comparisons/exclusions, which does not prove process creation. No general guarantee of a UI-free authenticated lifetime follows from the static findings.

Valve documents the factory calling convention in its public [interface.h](https://github.com/ValveSoftware/source-sdk-2013/blob/master/src/public/tier1/interface.h). The public [ISteamClient API](https://partner.steamgames.com/doc/api/ISteamClient) connects to an existing global user; it does not document the consumer token-login bootstrap seen here. Valve's [Proton lsteamclient](https://github.com/ValveSoftware/Proton/blob/proton_11.0/lsteamclient/steamclient_main.c) is a distinct Windows-to-native bridge, not evidence that a Windows host can omit its genuine client engine.

## Executed scope

`steam_windows_factory_probe.c` is an independent freestanding Windows program. It accepts an explicit DLL path, loads only the architecture-appropriate genuine client, checks exports, calls the public factory convention, and never dereferences the returned interfaces. It observes its own visible windows and whether SteamUI.dll is loaded. The extended probe also verifies actual module paths for steamclient and its two Valve dependencies.

The driver creates a new owned prefix on the authorized external APFS volume. It denies IP networking, other executable images, user and existing Steam data, Keychains, unrelated temporary files, and the closed GameNative helpers. Only this prefix's exact Wine UNIX socket is permitted for Wine IPC. Positive startup controls and separate negative read/write/direct-loopback/exec controls precede Valve execution. No saved sessions, accounts, or tokens are inputs. Existing native Steam processes are observed by executable path and left running.

Early attempts are retained as failures: the first overstrict OS-read sandbox aborted in dyld; the second correctly rejected Wine's hardcoded `/tmp/.wine-UID/server-dev-inode` directory before Valve ran. These are not client failures. Later runs whitelist only the new prefix's exact server directory. The raw Wine invocation in this narrow experiment can report FreeType unavailable because sandbox-exec strips DYLD environment; the measured factory result does not certify fonts or a complete runtime environment.

`Evidence/steam-windows-factory.json` is the small hash-bound pointer to the latest raw execution report. The prior successful baseline is retained separately, including stdout/stderr and the original probe build. Reports distinguish signed DLL identity, factory success, and authenticated-host success explicitly.

## Remaining execution target

The build-specific C export ABI for disconnected user creation and release is now established by static PE32/PE64 evidence and the measured lifecycle below. A usable open host still needs independently established callback lifetime, legitimate token login, license receipt, app configuration, and authenticated launch/IPC. Authentication requires a separate explicit user flow, with tokens supplied by a legitimate login under the user's control. It must not attach an existing user's client or reuse GameNative's restricted credential seal.

No DRM/CEG bypass, fake ownership, game-DLL replacement, or direct EXE launch presented as authenticated Steam support is part of this work. No Windows headless host is enabled in the launcher by this prototype. The final integration needs a real owned-game test and an independently reviewed distribution boundary for Valve's external files.

## Disconnected-user bootstrap result

The opt-in `--create-user` probe uses only `Steam_CreateGlobalUser(int32_t *pipeOut)`, `Steam_ReleaseUser(int32_t pipe, int32_t user)`, and `Steam_BReleaseSteamPipe(int32_t pipe)`. The x86 exports use cdecl and the x64 exports use the Windows x64 convention. Static forwarding is recorded against the exact signed DLL hashes; no returned interface object's vtable is dereferenced. The ordinary factory-only mode remains separate.

A new private JSONL file receives probe events using CREATE_NEW. Valve stdout/stderr is retained separately as untrusted diagnostic text. Events are committed before user creation, after its return, and after each release, so a timeout can preserve the last completed phase. Each execution retains its exact source snapshot and build receipt.

The final measured run `bootstrap-run-ff02993ea43440eeb515124e375cd209` passed on both architectures under the original IP-network denial. PE64 completed in 7.939 seconds and PE32 in 8.058 seconds; both returned user1/pipe1, returned from ReleaseUser, successfully released the pipe, and exited0. Own visible windows remained0 and SteamUI.dll was absent at the final observation. The real loaded client/tier0/vstdlib paths matched the six signed selected DLLs. All four native sandbox negative controls returned EPERM. Existing native Steam processes, configurations, provider executables, probes, and Valve DLL hashes remained unchanged; the exact synthetic prefix and its Wine IPC directory were removed.

This result does not establish usable client networking or Steam IPC: Valve still logs denied binding to port0 (WSAEACCES10013), GetAdaptersAddresses error2, missing optional SDL/video modules, and an unavailable gldriverquery executable. No such executable was provided or run. One earlier bootstrap attempt exceeded its25second bound; its failure is retained, so successful lifecycle observations are not a steady-state reliability certification. No network exception was added to obtain success.

`Evidence/steam-windows-bootstrap.json` points to the hash-bound raw report and complete evidence index. Login, account ownership, app launch, and game compatibility remain unverified.

## Windows IPC is shared memory, with measured isolation

The exact Windows images use named shared-memory mappings and events for this client IPC path. The `steam_master_ipc_name_override` value feeds IPC names and the platform implementation forms `<name>_SharedMemFile` and `<name>_SharedMemLock` using CreateFileMapping/OpenFileMapping and CreateEvent/OpenEvent. It does not apply the native Mac backend's IPv4 endpoint parser here. Supplying `127.0.0.1:<port>` would rename a Windows object; it would not establish the Mac TCP transport. The port0 WSAEACCES warning remains a separate client network-initialization diagnostic.

A subsequent real two-process experiment uses a unique `ReadyWin-<random>` namespace and a host held alive on a private release signal. Consumers call only Steam_CreateSteamPipe and Steam_ConnectToGlobalUser, never CreateGlobalUser. For both PE64 and PE32, the matching namespace in the principal prefix returns pipe1/user1, while a different namespace and the same namespace in a second prefix return pipe0/user0. A second matching consumer succeeds after both negatives while the original host remains alive. This demonstrates a real status returned through the Valve library between processes, with negative controls ruling out silent creation of a fallback host. Wine traces show the host creating the unique SharedMemLock event and matching consumers opening it. All IP networking remains denied; only each prefix's exact Wine UNIX socket is permitted.

The original raw aggregate result remains **false**: its negative-case cleanup predicate incorrectly expected pipe release when no pipe existed, and the PE32 host genuinely exited1 after writing successful user/pipe-release and no-UI events. All eight consumer processes exited0; the PE64 host exited0. The derived assessment separately records verified two-process status/isolation on both architectures and the unresolved PE32 process teardown. It does not relabel the raw result as a complete pass, and the execution was not repeated to change that result. The retained logs contain no explicit unhandled exception diagnosis. The last complete event precedes FreeLibrary, CloseHandle, and ExitProcess in our source, which bounds investigation but does not identify the cause. The public ShutdownIfAllPipesClosed method is a statically identified future cleanup candidate, not an applied fix.

See `Evidence/steam-windows-sharedmem.json`, the immutable raw report and its separate `ipc-assessment.json`. Both scratch prefixes and their exact Wine IPC directories were removed after scoped server waits; original providers, configurations, and native Steam processes remained unchanged.

## Exact Windows login and callback ABI, static only

`steam_windows_login_abi.py` parses PE metadata and MSVC RTTI from the hash-pinned signed images. The IClientUserMap tables have259 entries on both architectures. Selected method bodies independently reference their genuine method-name strings; method addresses and64byte code-prefix hashes are retained. No Mac offsets are imported.

| Primitive | Windows index or export | Static calling contract |
| --- | --- | --- |
| Engine GetUser |8 | this, int32 user, int32 pipe → IClientUserMap pointer |
| User LogOn |1 | uint64 SteamID by value → int32 result code, not bool |
| User BLoggedOn |4 | bool8; also available as C export Steam_BLoggedOn(user,pipe) |
| User GetSteamID |10 | Windows MSVC hidden8byte output buffer, returned buffer pointer |
| User SetLoginInformation |54 | account, password, bool8 remember → void |
| User SetLoginToken |56 | token first, account second → void |
| Public GetISteamApps | SteamClient023 index15 | user, pipe, exact Apps version string |
| Public BIsSubscribedApp | Apps009/008 index6 | uint32 app ID → bool8; includes checks beyond internal UserMap181 |
| Public ShutdownIfAllPipesClosed | SteamClient023 index22 | statically identified, not executed |
| Callback fetch/free | Steam_BGetCallback / Steam_FreeLastCallback | two / one C arguments; cdecl on32, Windows x64 convention on64 |

The callback record is `{int32 user, int32 callbackID, void *payload, int32 payloadBytes}`. Its offsets are0/4/8/16 and size24 onPE64, and0/4/8/12 and size16 onPE32. The callback worker copies those sizes and tracks thread ownership. Fetch, inspect or copy a bounded payload, then free on the same thread before another fetch; no payload pointer may escape that lifetime.

`steam_windows_login_abi.h` contains independent declarations and architecture layout assertions, checked with the actual Windows target compiler for PE32 and PE64. `Evidence/steam-windows-login-abi.json` binds those checks and the raw ABI evidence. These declarations prepare a future host with private credential stdin; they neither implement token transport nor prove modern authentication. No real or invalid token was supplied and no LogOn, subscription, or auth method was executed during this static step.

## Private-stdin Windows host candidate

The separately invoked `--authenticate-bounded` candidate now reads the same28byte RDYAUTH1 frame as the native host, using Windows APIs. Its account and token limits are64 and8192 bytes. It accepts only an inherited pipe and validates the complete header, ASCII fields, individual/public/nonzero account identity, nonzero AppID, and final EOF. It additionally rejects AppID0xffffffff: a retained genuine API experiment reported that sentinel subscribed even while offline. The ordinary factory test driver does not expose this authentication mode.

Wine represents inherited Unix stdin as FILE_TYPE_PIPE but rejects PeekNamedPipe with ERROR_NOT_SUPPORTED50. Native Windows pipes can use Peek/Read; the Wine fallback uses a private ReadFile parser thread and a single monotonic3second main-thread budget for the entire frame and EOF. The main thread requests cancellation and waits at most250ms. This Wine I/O cannot always be cancelled, so an overdue parser terminates only its own pre-DLL worker. In that case process RAM is reclaimed; the report explicitly does not claim a quiescent buffer wipe or forensic zeroization. Successful and normally rejected parses explicitly wipe their buffers. No Valve library loads until parsing and EOF have succeeded.

The complete initial public-synthetic suite exercised26 parser cases. Four hard-timeout events initially mislabeled the3250ms limit as an elapsed measurement; that raw report is retained and those four timing measurements are not accepted. A scoped follow-up checks valid input, reserved AppID, a held-open writer, and cumulative header/body/EOF delay on both architectures. Actual hard stops measure3253/3259ms onPE64 and3252/3252ms onPE32; all occur before Valve loads. An initial Peek-only build failed closed before Valve, rather than silently switching to unbounded reads.

The final candidate is `ready-windows-steam-host-60e19eba8c325154522b`. Each architecture was tested in a distinct fresh prefix with only the public synthetic frame and all IP networking denied. The stdin handle closes before Valve loads. The candidate uses SetLoginInformation with rememberTRUE, SetLoginToken(token,account), then wipes its own volatile credential buffers before LogOn. The fixed invalid-token mode retains rememberFALSE. Callback pumping uses a25second monotonic deadline on one thread; payloads remain opaque and every fetched callback is freed on that same thread.

The genuine client can locally retain the SteamID supplied to LogOn, so a matching GetSteamID and dispatchResult1 do not demonstrate authentication. Readiness combines BLoggedOn, the exact expected SteamID, and the public Apps subscription result; the trusted caller must additionally establish the actual app/account ownership through the genuine SteamKit broker before supplying the frame. The parser cannot authenticate its writer or that preflight.

Both isolated final tests reject the public synthetic authentication: BLoggedOn=false and authenticatedReady=false, despite dispatch1 and an identity match. PE64 fetches/frees32 callbacks; PE32 fetches/frees31. Public shutdown returns true, both processes exit with the expected controlled failure code4, no SteamUI or visible windows appear, and all original runtime/configuration/native Steam hashes/processes remain unchanged. The earlier reused-prefix PE32 exit5 before auth remains recorded; fresh-prefix success does not establish its cause.

For this credential mode, Windows stdout/stderr handles are redirected to NUL and their old handles close before Valve loads. The private event handle remains separate. Actual tests show stdout0bytes and no Valve diagnostics in stderr; Wine's pre-main FreeType warning can still appear before credential handling. A real integration should also discard child stdout/stderr at the native process boundary. Only safe events may be retained; never log account names, tokens, callback payloads, or raw authentication tickets.

`Evidence/steam-windows-auth-candidate.json` binds the exact PE binaries, build/source receipt, parser evidence, and separate PE32/64 execution reports. This is an offline candidate, not an enabled runtime capability. No real account, Internet authentication, owned-game launch, or ticket transmission was tested.

A final comment-only recipe rebuild `1ede483c6d262163fe81` produces byte-identical PE32/PE64 executables to the tested60e19 candidate. The separate source-binding receipt preserves that equivalence and the current source hashes without editing frozen execution reports or claiming another execution.

## Real-network preparation wrapper (no account execution on this agent)

`steam_windows_authenticated_host.py` defaults to `--prepare-only`. It copies only our pinned PE and the three Authenticode-verified Valve DLLs into a new owned private prefix. It snapshots the wrapper/broker/codec sources and binds the exact c7b6 ownership helper, its companion output, and the external .NET host/runtime files. Broker modules load from that snapshot in a unique Python package, without using an already imported module from another task. Source or code hash changes invalidate the preparation.

The online sandbox follows the separately measured native policy: outbound IP networking excludes localhost, all other Unix sockets remain denied, and only OS mDNSResponder plus this exact prefix's Wine UNIX socket are exceptions. Ephemeral binds are explicitly allowed because the sandbox rejects a port0 selector. Inbound networking remains denied apart from the exact Wine socket. This is not a fixed Valve-host/IP allowlist. OS DNS and a public TCP connection to api.steampowered.com:443 are preparation smoke tests, not authentication or TLS certification. User/Steam account data, unscoped POSIX shared memory/semaphores, extra native executables, and other local IPv4/IPv6/Unix endpoints remain blocked.

The exact bootstrapped Wine EXE/DLL files and the copied four code inputs remain hash-bound. Unknown EXE/DLL reads from mutable state are denied, and writes to known code files are blocked. This excludes the ordinary Steam frontend, SteamUI, steamwebhelper, and GameNative's closed hosts rather than providing those files. The DLL namespace uses a unique ReadyOwned name, preserving isolation from the default Steam3Master namespace.

A native guardian owns a separate parent-lifetime pipe, never reads credential stdin, and validates the exact canonical prefix, UID, private nonce marker, device and inode before scoped wineserver cleanup. Parent disappearance stops only its child process group and that verified prefix; no global Steam server is killed. Preparation verifies this with our parser-only PE, before any Valve code loads. Original Wine/default/evaluation configurations remain unchanged.

The final prepared state is referenced by `Evidence/steam-windows-online-preparation.json`. All eight negative controls and the exact own-Wine-socket positive control pass; public DNS/TCP passes; Wine bootstrap exits0; parent-lifetime EOF produces guardian exit130 with exact-prefix cleanup. No Wine process remains after preparation. Earlier preparations and failures are retained; source revisions intentionally invalidate superseded states.

Real execution is a separate explicit Root-managed API call:

```python
authorize_and_launch(prepared_state,
    allow_real_auth=True,
    onQR=root_qr_callback,
    onPhase=root_phase_callback,
    cancel=root_cancel_event,
    expectedSteamID=selected_profile_steam_id)
```

The exact genuine broker must authenticate and obtain ownership authorization for the exact nonreserved AppID before its single-use private frame is written to the owned Wine child's stdin. QR URLs and frames never enter this wrapper's console or files. Parent and PE stdout/stderr are discarded. A cancellation cannot be reported as an authenticated result. Only safe worker status is retained; no raw ticket payload is supplied to the PE.

This preparation was executed only with our controls, Wine bootstrap and our parser-only lifetime child. `actualBackendNotAuth=true`, Valve online execution=false, real account authentication=false. The real-authorized API has not been executed by this agent; no game launch is implemented or verified here.

## Shared in-memory Root session, current8d helper

The current wrapper supersedes the old c7 preparation and pins the genuine ownership helper `8d552562a3ab2f1e96f65c0aad6a525966a5331933462bd89787a58b3c9834dc` from `steam-ownership-jvty72ta`. PE32 and PE64 have separate prepared prefixes. Their latest hash-bound state files are listed in `Evidence/steam-windows-online-preparation.json`; superseded states fail the current source/helper checks. The policy adds only the explicitly identified trustd.agent lookup for OS trust services, with no securityd or personal Keychain file grant.

The Root operator can retain one genuine AuthenticatedSession across the native and Windows trials:

```python
context64 = session.authorize_game(command8d, app_id,
    expectedSteamID=profile_steam_id, onPhase=root_phase_callback)
run_with_authorized_context(prepared64, context64, cancel=root_cancel_event)
context32 = session.authorize_game(command8d, app_id,
    expectedSteamID=profile_steam_id, onPhase=root_phase_callback)
run_with_authorized_context(prepared32, context32, cancel=root_cancel_event)
# Close the session only after the intended single-use frames were handed off.
session.close()
```

`run_with_authorized_context` makes no helper request and no QR operation. It verifies the exact AppID, structurally valid explicit SteamID, authorized/ticket flags, live private frame, and the frozen classes declared by the context's actual broker module. That module's canonical owned ROOT/work source file must match the pinned broker snapshot. It deliberately does not compare the Root context to a differently named prepared-package Python class. Only safe metadata is inspected; account/token/frame bytes are never decoded or logged. These checks are a trusted in-process caller boundary, not independent cryptographic ticket verification or protection from a caller that can rewrite this Python process.

The wrapper consumes and clears only the returned single-use frame. It never closes the caller's Session; the caller can obtain another genuine exact-game authorization context from the same in-memory credentials without another QR. `authorize_and_launch` remains the explicit fresh-QR convenience path using the corrected8d helper.

Eleven targeted context checks pass without starting a helper or Wine worker: dictionaries, attribute fakes, wrong app, invalid/bool/wrong-universe identity, missing authorization/ticket, and a consumed frame are rejected; the genuine same-source Root-module metadata shape is compatible across Python package names. Preparation controls and the guardian pass independently for both architectures. No real authorization context was sent to Wine by this agent.
