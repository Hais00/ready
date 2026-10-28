# Native macOS Steam host: bounded research evidence

This work establishes a native ARM64 loader, interface and offline control
prototype and a real offline host/peer connection using the user's genuine
external Valve client. It does **not** establish successful native-client
authentication, ownership of a game, working game-to-host IPC or Steamworks
compatibility. No real account or token was used in the recorded offline
controls. The existing, unrelated Steam process remained
unchanged according to all three dynamic reports.

Ready's independently authored host/adapter source is separate from proprietary
Valve assets. GameNative's proprietary bootstrap was inspected privately, never
executed or copied into Ready's GPL source. No Valve SDK headers or closed
implementation bodies are included in this document or the repository.

## Exact image and interface boundary

All addresses below are **unslid ARM64 virtual addresses**, and all vtable slots
are zero-based, measured on this single image:

`steamclient.dylib` SHA-256:
`b9d62be2ac64b77dc77e1d19eefcf3880df99495c7db85b30623095310b6a6bd`.

The installed image is universal ARM64/x86_64; this ABI analysis covers ARM64.
Bundle version `6.1` is bootstrap metadata, not a verified client build revision.
Factory descriptor, architecture and exact image identity must be checked before
using an indexed method. A different image is unavailable until separately
validated. Addresses are evidence anchors, not absolute runtime call targets.

Observed descriptors are `CLIENTENGINE_INTERFACE_VERSION005`, `SteamClient023`,
`SteamUser023` and `STEAMAPPS_INTERFACE_VERSION008`. `CreateInterface` is exported
at `0x1093ba0`. The client-engine vtable address point is `0x1782288`;
`IClientUserMap` is `0x176e270`, independently identified through its RTTI and
the paired named IPC dispatch paths.

| Native C export | ARM64 address | Primitive ABI and ordering |
|---|---:|---|
| `Steam_CreateSteamPipe` | `0x68736c` | `int32(void)` |
| `Steam_CreateGlobalUser` | `0x6873e8` | One output-pipe pointer; writes 32-bit pipe, returns a logical 32-bit user handle |
| `Steam_ConnectToGlobalUser` | `0x687414` | `int32(int32 pipe)` |
| `Steam_BLoggedOn` | `0x6875b0` | `bool(int32 user, int32 pipe)` |
| `Steam_ReleaseUser` | `0x687440` | `void(int32 pipe, int32 user)` |
| `Steam_BReleaseSteamPipe` | `0x687388` | `bool(int32 pipe)` |

The release ordering is intentionally different from `BLoggedOn` and the
client-engine `GetUser` method. The latter is slot 8, byte offset 64, and takes
`(this, user, pipe)`. Invalid user/pipe pairs can assert rather than simply return
false. Valve's public documentation describes the signed 32-bit handle types and
the public release contracts. The static export wrappers reach those same engine
methods without reordering the two release arguments.
([Valve ISteamClient](https://partner.steamgames.com/doc/api/ISteamClient#ReleaseUser))

## Identity, subscription and login methods

The following internal methods were mapped using the actual proxy vtable,
method-name references, serialization and corresponding server dispatch. These
are per-image interoperability observations, not a stable Valve API contract.

| `IClientUserMap` method | Slot / byte offset | Observed primitive shape |
|---|---:|---|
| `LogOn` | 1 / 8 | One 8-byte scalar by value; 32-bit status result |
| `GetSteamID` | 10 / 80 | No non-`this` argument; 8-byte return, zero on proxy failure |
| `BHasCachedCredentials` | 49 / 392 | String argument; one-byte Boolean result |
| `SetAccountNameForCachedCredentialLogin` | 50 / 400 | String plus one-byte flag; Boolean result |
| `SetLoginInformation` | 54 / 432 | Two strings plus one-byte flag; no typed return payload consumed |
| `SetLoginToken` | 56 / 448 | Two strings; no typed return payload consumed |
| `BIsSubscribedApp` | 181 / 1448 | 32-bit AppID; one-byte Boolean result |

Data flow supports `(accountName, secret, remember)` for
`SetLoginInformation`, and `(token, accountName)` for `SetLoginToken`. Those
semantic names are static inferences. They do not prove that any supplied token
will be accepted. `LogOn` serializes a scalar, not a pointer to a guessed login
structure; its returned status is not proof of completed authentication.

The public adapter route was measured separately:

- `SteamClient023`, vtable `0x175fec0`: slot 5 gets `SteamUser023`, and slot 15
  gets `STEAMAPPS_INTERFACE_VERSION008`, with `(this, user, pipe, version)`.
- `SteamUser023`, vtable `0x176c700`: slot 1 forwards `BLoggedOn`; slot 2 forwards
  `GetSteamID` to internal user offset 80.
- `SteamApps008`, vtable `0x175e918`: slot 6 implements `BIsSubscribedApp` using
  the genuine internal user query **and additional genuine client checks**.
  The raw internal Boolean is not assumed equivalent to that public adapter.

Valve describes `GetSteamID` as identifying the logged-in account and the public
app query as checking an active subscription. A subscription need not mean a
permanent purchase; shared and temporary licence contexts exist. A false result
while offline or after failed IPC must be reported as unavailable or
unauthenticated, not as a conclusive lack of ownership. Matching a selected
SteamID alone also does not prove that a new login succeeded.
([GetSteamID](https://partner.steamgames.com/doc/api/ISteamUser#GetSteamID),
[BIsSubscribedApp](https://partner.steamgames.com/doc/api/ISteamApps#BIsSubscribedApp))

## Recorded dynamic controls and their limits

The retained reports are distinct experiments, not rewritten history:

| Report | Recorded result |
|---|---|
| `6f7ac52a33724c7090cb95a9649fb4ae` | ARM64 image/factory success; user 1 / pipe 1; public User/Apps adapters present; logged-on false; AppID 480 subscription false |
| `6e5608d82f174534bfdedc470fa26a38` | Synthetic invalid-token login dispatch returned 1; logged-on remained false; user and pipe released; no authentication or game compatibility |
| `f4545e8e6ee2436ca56fdb60aa9be5e0` | Genuine offline host and peer both exited 0; peer connected to host; public adapters present; 11 host / 3 peer callbacks with valid sizes; both released user and pipe |
| `047b26d7af6941dfb0d3b8ea041d17eb` | Later composed-adapter host/peer run: both exit 0, reciprocal established TCP connection, valid callbacks and handle release; the three controller mapping errors are absent |

All three observe SteamID `76561197960265728`, a base/uninitialized identity in these
controls, **not a real authenticated account**. Each binds the same client image,
report the library and existing Steam processes unchanged, and record passing
negative controls for normal-state read, normal-state write, outbound network
and unrelated execution. These controls cover the tested operations, not every
possible syscall or future client version.

The schema-1 `6f7ac52a` report contains stale summary fields:
`networkPermitted:false` does not describe the scoped loopback IPC permission,
and `privateVtableInvoked:false` is not a reliable description of its indexed
public-adapter calls. Schema 2 separates `internetPermitted:false` from its two
allowed loopback endpoints and records indexed-method attempts. The original
schema-1 report remains unchanged; use the newer report for those declarations.

The `f4545e8e` test held the owned host alive while the owned peer used
`CreateSteamPipe` and `ConnectToGlobalUser` with the same endpoint and private
state. Captured `lsof` evidence shows the host listening on loopback port 52930
and reciprocal established connections with the peer on port 52932. It records
six passing negative controls, unchanged client code and unchanged existing Steam
processes. Both stayed logged out with the same base identity. Callback metadata
was recorded without dumping payloads.

The genuine different-namespace peer negative control is still pending. Real QR
login, authenticated identity, positive/negative game-licence outcomes and game
launch remain unproved. The current `SessionManager` gate rejects all direct
Steam launches before prefix preparation; replacing that gate requires a verified
owned authenticated host-session lease. The coordinator reports 21 passing
SessionManager fixture checks; this static audit did not rerun them.

Subsequent coordinator-run live QR attempts are outside those offline receipts.
One returned a genuine QR credential result, then failed during the separate
authorization request; another failed at `qr_authentication`. Neither establishes
successful native-client authentication, a positive ownership preflight or game
IPC. This source audit did not read the credential payloads or repeat those logins.

### QR exception diagnostics

The pinned local SteamKit source exposes a typed `AuthenticationException.Result`.
Both beginning a QR session and polling a non-OK authentication response can throw
that exception. Previously, `SteamSafeFailure` used only the separately observed
callback result, which is null during QR polling, so it lost the available SDK
result and returned `steam_error / qr_authentication / null`.

The helper now uses the typed exception's result when no explicit callback result
has been observed. It never serializes the exception message or an inner
exception. The existing enum allowlist is unchanged: `Expired` and `Fail` are
reported directly, while `FileNotFound` and unknown enum values remain `Unknown`.
A non-authentication exception without a result remains null. This is a
diagnostic correction, not evidence of the cause of an earlier generic failure
and not an automatic retry policy. The current helper and previous external
candidate are retained; only a new isolated candidate is rebuilt.

The isolated source rebuild passed 19 protocol/runtime guards and 33 pure
decision/diagnostic checks, including typed `AuthenticationException` cases for
`Expired`, `FileNotFound`, `Fail` and an unknown enum, explicit-result precedence,
and a non-authentication exception without an SDK result. No real account or
network authorization was used. The candidate DLL SHA-256 is
`c7b6bfd4a519881d0e0ac9fc58a24a9822d2db01a0694cd2a170595e3ac94a39`;
the production `Program.cs` SHA-256 is
`de53418ec6b0ca3fdd36f23cd744f9092f8ea7404b35434f483f3171c8a9886a`.
The local `Evidence/steam-ownership-preflight-fixtures.json` binds its external
build, SDK archive and cached NuGet inputs. The previous `4bb69b…` candidate and
its receipt/source beforeimages remain retained; the normal helper and project
SDK runtime were not replaced or restored in place.

### Post-ticket cleanup diagnostics and an in-memory retry boundary

A later coordinator-run live attempt completed login and received an ownership
callback with `EResult.OK`, then failed before the complete authorization result.
That observation alone does not establish a matching nonempty ticket, a positive
decision or successful cleanup. The old `finally` sequence could replace a
decision exception with a later cleanup exception.

The next isolated helper records separate response, decision, ticket-clear,
logoff, cancellation, disconnection and pump stages. Its error diagnostics contain
only allowlisted exception kinds and nullable factual Booleans: response received,
AppID matched, ticket nonempty, SteamID present and decision authorized. Cleanup
failures remain failures, but no longer hide a prior decision failure, and the
remaining cleanup steps are still attempted. No ticket bytes, account identifiers,
exception messages or stacks are added to an error response.

The suspected SHA-256/environment problem did not reproduce: both the preserved
old candidate's positive fixture and the new helper's pure decision fixture passed
with the broker's exact minimal environment and network denied. The new isolated
build passed 20 protocol/runtime guards and 44 decision/diagnostic/cleanup checks;
its DLL SHA-256 is
`8d552562a3ab2f1e96f65c0aad6a525966a5331933462bd89787a58b3c9834dc`.
This narrows the diagnosis without claiming that the live failure has been
reproduced or fixed. The prior `c7b6bf…` candidate and receipt/source snapshots
remain retained.

The broker's optional `beginQR` API now returns a redacted `AuthenticatedSession`
that holds credentials only in the current process for at most ten minutes.
`authorize_game` requires an explicit helper command on each attempt, allowing the
coordinator to pin a corrected helper before retrying authorization without a new
QR. There is no automatic retry or helper selection. Close, cancellation and idle
expiry drop the session's credential references; no disk, Keychain or diagnostic
credential cache is created. Python immutable heap copies cannot promise forensic
erasure, and separately returned handoff frames remain caller-owned.

Twenty-seven offline broker/session checks cover the explicit retry with only one
QR, strict safe error metadata, idle expiry, cancellation and the compatible
one-shot API. These tests use synthetic helpers; they do not authenticate an
account or launch a native Steam worker.

### Identified SteamKit WebSocket cleanup defect

A later held session produced a genuine positive decision with all five ticket
facts true, then reported `InvalidOperationException` specifically at
`ownership_disconnect`. Source inspection contradicted the initial inline-task
hypothesis: SteamKit's `AsyncJob<T>` already uses
`RunContinuationsAsynchronously`. The concrete defect is in
`WebSocketContext.Dispose`, which calls `RunSynchronously()` on the task returned
by `ClientWebSocket.CloseAsync`. That task is already an asynchronous promise;
moving the same invalid call into `Task.Run` does not make it valid.

`Scripts/steamkit_websocket_close.patch` corrects only an owned external copy of
the pinned LGPL-2.1-only SteamKit source. It awaits the close task synchronously
through `GetAwaiter().GetResult()`, with an independent three-second cancellation
budget and `WaitAsync` bound, and disposes the socket in `finally`. It does not
silence `InvalidOperationException` or turn cleanup failure into authorization
success. The original vendored source remains unchanged.

The patch, original/patched source hashes, upstream revision and target framework
are pinned in `Scripts/steamkit_websocket_close.lock.json`; the external build
retains its patch receipt, corresponding sources and LGPL notice. The new build
passed 21 protocol/runtime guards and 47 pure checks, including the invalid
promise-task call both directly and inside `Task.Run`, the corrected await, and
the independent cancellation budget. These are offline controls; a live retry is
the coordinator's separate proof.

The new candidate `ReadySteamBridge.dll` SHA-256 is
`f127cc65ee2aca9703584e21967a6742dacbcd354ed666eae73a402b4cb05698`,
and its rebuilt `SteamKit2.dll` SHA-256 is
`32aab21e6a6faa11bf6844e5d72ed8ccc7d3155c8b59079b7ba0286d4f81f272`.
The complete output-file hash map has fingerprint
`951a2c8a1f7475523a1fff452bc32fe72265e80856a18e575348fdacc1d1db5d`.
Consumers must pin that new closure, not merely the host DLL name. The previous
helper/dependency closure and the normal installed helper remain intact.

## IPC, shared objects and file-state isolation

Both `CreateGlobalUser` and `CreateSteamPipe` explicitly read the nonempty
`steam_master_ipc_name_override` environment value before falling back to
`Steam3Master`. The actual Mac path reaches a TCP address parser: an earlier
dynamic test rejected a non-address namespace string in
`BSetIpPortFromName`. The subsequent controlled probes used loopback endpoints.
The earlier static uncertainty about TCP parsing must not be treated as evidence
of Android incompatibility.

`ConnectToGlobalUser` validates an existing pipe, sends a connection request and
records the returned user/pipe pair. There is no direct `CreateGlobalUser` call
in that method. It also synchronizes state after connecting; the audit does not
prove that every transitive initializer is free of process or file side effects.
Independent execution restrictions remain necessary.

Controller shared-state construction passes the literal `Master` and formats
`SteamController_%s`, `SteamController_Fast_%s` and `SteamController_Slow_%s`,
then appends `_mem`. No override was observed on this inspected creation path.
Before POSIX access, the logical names become standard CRC32-based names:

| Logical mapping | Actual POSIX name |
|---|---|
| `SteamController_Master_mem` | `/Shm/c9edbd50` |
| `SteamController_Fast_Master_mem` | `/Shm/fe20b6d7` |
| `SteamController_Slow_Master_mem` | `/Shm/671c2a99` |

Semaphore families include `/BSem/%x` with `.2`, `/MTX/%x` with `.2`, and
`/Evt/%x` with `.BinSemLock`. Consequently, matching the logical controller
strings only at the POSIX boundary cannot isolate these objects.

Worker-local interposition must consistently translate both open and unlink
names. On **Darwin**, `shm_open` and `sem_open` are variadic: mode, and the
semaphore initial value, are present only for `O_CREAT`. The ARM64 mapping caller
stores mode on the stack. An earlier static note incorrectly called `shm_open`
fixed-three-argument; the new private v2 map corrects it without rewriting that
historical note. The Mac SDK declaration and the cross-process fixture exposed
this distinction.

The separate namespace shim now has **16 fixture checks passing** across ARM64
and x86_64, including sharing within one namespace, separation between namespaces,
scoped unlink and denial of uninterposed names. It used only owned random test
objects and executed no Valve code. The later genuine host/peer test used both
the state and IPC shims, but still reported failures creating all three controller
memory mappings. A file-operation composition failure around `ftruncate` /
`F_GETPATH` was then isolated in an actual composed fixture: the filesystem wrapper rejected
POSIX SHM descriptors because they do not have ordinary `F_GETPATH` results.
The narrow correction revalidates each descriptor using the current process's
kernel SHM metadata, owner and exact current namespace. It does not allow arbitrary
unknown descriptors. Eight composed fixture groups pass on ARM64/x86_64 and both
library orders, including duplicate descriptors, reused pipe descriptors and
foreign namespace rejection; the prior 16 filesystem groups also pass.

The later genuine `047b26d7` host/peer run uses this correction and records no
controller mapping failures in either worker. Seven sandbox controls include
denial of an unrelated Unix socket and unscoped SHM/semaphores. Its host processes
12 callbacks with valid sizes; both workers release handles and exit 0. This
addresses the observed composition failure. It still does **not** establish
complete game/profile isolation or game interoperability.

File-state interposition redirects selected normal Steam-state paths into a
private worker directory while retaining the selected code bundle. It is **not
a sandbox**: unsupported APIs, direct syscalls, Mach IPC, inherited handles or an
uninstrumented child can bypass a lookup wrapper. The independent sandbox must
deny original-state fallback. The inspected directory helper otherwise derives
`Library/Application Support/Steam` from `HOME` or the account home-directory
fallback; no Steam-specific data-root override was verified. This research did
not change `HOME`.

A child or game needing private named objects must explicitly share the intended
namespace and compatible adapter. Random names alone do not authenticate peers,
and namespacing every object can disrupt a framework expecting global OS IPC.
These boundaries require real host/game and conflicting-profile tests before
claiming profile isolation.

## Callback and lifetime boundary

`Steam_BGetCallback` at `0xa134f8` takes `(int32 pipe, outputHeader*)` and returns a
Boolean. `Steam_FreeLastCallback` at `0xa13528` takes the pipe and returns no
typed value. Observed header fields are 32-bit user and callback ID at offsets 0
and 4, a payload pointer at 8, and a 32-bit byte length at 16; allocate with
8-byte alignment, including padding to 24 bytes.

Get actively drains IPC callbacks. Every retrieved callback must be freed before
the next Get, on the **same thread**: the implementation checks an in-flight flag
and `ThreadGetCurrentId`. The payload is borrowed until Free; credentials and
ticket payloads must not enter ordinary diagnostics.

The Android helper resolves these Get/Free exports and polls with 20 ms sleeps
during login and launch-related waits. No named `BMainLoop` or `RunFrame` export
resolution was observed in those paths. Native `CSteamClient::RunFrame` is
client-engine slot 19 and is also forwarded by public `SteamClient023` slot 19.
The separate `CSteamEngine::BMainLoop` belongs to another backend object; its
vtable slot must not be transplanted onto `IClientEngine005`. Static analysis does
not establish which frame pumping is required for a successful native login.

## Evidence retention

The credential handoff now uses a bounded binary frame over an explicitly owned
stdin pipe. Structural identity validation is not authentication. The native
reader has a total three-second deadline, rejects malformed/trailing input and
clears its buffer. A separate broker performs genuine SteamKit QR authorization
and ownership preflight before handing the frame to the native worker. Its
offline tests cover cancellation, stale/duplicate terminal events, private
handoff and safe errors. Neither fixture suite counts as real account proof.

Native authorization preparation `25519b5b317344f38a1ea0952a7445d2` passes the
sandbox controls and a real DNS/TCP connection to Valve's public API host, without
loading the Valve client or using credentials. The online policy explicitly
permits public outbound traffic, DNS's OS-owned Unix socket and ephemeral client
binds; it retains the original-state, execution and unrelated IPC restrictions.
An initial human-approved QR flow reached the subsequent ownership request but
ended with the old broker's generic helper error. Its original result cannot
identify whether logon or ownership failed, and no native credential handoff or
native account logon is established by that attempt. Diagnostics and persistent
login settings are being corrected before another real attempt.

The local research pointer `Evidence/steam-native-headless-research.json` binds
the private compact map and the three dynamic reports. Disassembly, copied proprietary
research images and raw image/process inventories remain outside the repository
on the authorized external research volume. The current compact v3 map is bound
by SHA-256
`85f094549c24d8b1250ad1f39240f1f3eccceca084c96248f08875cc93f67e37`;
it references the unchanged v2 ABI correction packet and the actual peer report.
The namespace fixture report is separately retained as
`Evidence/steam-native-ipc-namespace-fixtures.json`.

Nothing here approves Valve binary redistribution, promotes an open-source-only
runtime containing proprietary client assets, changes active providers or grants
game ownership. Consumer integration remains gated on actual authentication,
isolation, lifecycle and owned-game evidence.
