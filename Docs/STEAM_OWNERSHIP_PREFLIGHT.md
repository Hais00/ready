# Steam ownership preflight

`StoreBridge/SteamBridge/Program.cs` adds `authorize_game` to the standalone
SteamKit helper's private stdin/stdout JSONL protocol. This is an account-side
preflight, not a Steamworks runtime, native/Wine IPC implementation, permanent
purchase assertion or guarantee that a game will launch. It does not start the
Steam application, modify a game or replace its own authorization checks.

Request, sent over private stdin rather than process arguments:

```json
{"operation":"authorize_game","options":{"gameID":"123"},"credentials":{"username":"<private>","refresh_token":"<private>"}}
```

The app ID must be a nonzero uint32 decimal string or JSON uint32 number.
Malformed/missing IDs and credentials are rejected before `SteamClient` is
created or connected. The normal logon path authenticates the supplied account
with Steam. After a successful login, the helper requests
`SteamApps.GetAppOwnershipTicket(appID)` from the genuine Steam service and waits
for its matching asynchronous callback. Authorization requires all of:

- `EResult.OK` from the ownership-ticket request;
- the exact requested app ID in the response;
- nonempty ticket bytes;
- a nonzero SteamID from the authenticated client.

The only successful response shape is:

```json
{"type":"result","steamID":"<authenticated SteamID>","appID":123,"authorized":true,"ownershipTicketReceived":true,"ticketSHA256":"<SHA256>"}
```

The ticket itself and credentials are never emitted by this operation. The
callback's ticket byte buffer is cleared after the decision. SteamKit/.NET may
retain other internal copies; this is not a claim that all process memory is
zeroized. The helper logs off, disconnects and stops its callback pump on both
successful and rejected ticket decisions. A non-OK result, mismatched app ID or
missing ticket/identity returns a sanitized `not_authorized` error; authentication,
validation, timeout and connection failures retain their sanitized error codes.
No server diagnostic or exception text is used as a credential log.

A result applies to that authenticated request and app ID. Consumers must bind
it to their profile/request generation, reject stale responses and require a new
preflight when identity or target changes. They must not reinterpret cached
library metadata, a previous successful request or a caller-provided boolean as
this result. Even a real successful ticket does not establish a compatible local
Steamworks host or authorize bypassing a game's own DRM/ownership validation.

## Isolated verification

`Scripts/test_steam_ownership_preflight.py` builds a separate helper under the
marked external work volume. It copies the project's already pinned .NET
10.0.403 host/shared files and verifies/extracts the existing SDK build-tool
archive there; it does not restore into the normal Tools directory, invoke
`store_bootstrap.py` or fetch the newest SDK. Source projects and exact cached
NuGet inputs, temporary files, caches and build outputs also remain external.
NuGet sources are cleared for the isolated build. Cached raw archive SHA512 and
the separately recorded assets/content identity are both retained; this is not
an audit approving the full .NET/NuGet redistribution/source closure.

The tests compile the same production validation/decision code into a separate
test-only entry point. It simulates denied, wrong-app, missing-ticket and
missing-identity callbacks, and verifies the shape of a synthetic positive case.
That executable is labelled fixture-only. There is no fake-authorization
operation or caller-supplied callback result in the production helper protocol.
Invalid request/credential cases and the existing self-test execute with network
access denied. The normal compiled helper is inventoried before/after and is
never overwritten by this test.

No real account login or ownership request is performed by this fixture suite.
A genuine authorized-account request remains an explicit later test after user
sign-in. Until then, evidence must state `genuineOwnershipVerified: false` and
must not describe fixture callbacks as a Steam entitlement result. Native/Wine
host-session validation remains a separate gate.

## Persistent-session login and safe diagnostics

The QR authentication request uses `AuthSessionDetails.IsPersistentSession=true`.
The shared `SteamLoginPolicy.CreateLogOnDetails` therefore sets
`ShouldRememberPassword=true` when logging on with its access/refresh token.
This follows the explicit documentation on `SteamUser.LogOnDetails` in the
pinned local SteamKit source:
`Vendor/steamkit/SteamKit2/SteamKit2/Steam/Handlers/SteamUser/SteamUser.cs`.
The same corrected policy applies to the existing authenticated library and
launch-info paths. The flag is a login-protocol requirement; this change adds no
password/credential file writer.

A rejected login now returns `code: "steam_login_failed"`, with a constant
`stage: "logon"` and an allowlisted `steamResult` enum name, for example
`InvalidPassword`. Other stages are `request`, `connecting`, `qr_authentication`,
`ownership_ticket`, `library` and `launch_info`. A result is null when no SDK
callback result has been observed at that stage. Unknown or unapproved enum
values become `Unknown`. Validation errors remain distinct from login rejection.

Error messages are constant. Exception text, server text, account names, tokens
and raw tickets are not emitted as diagnostics. Offline tests verify the shared
login policy, known login/ownership failure enums, timeout handling and rejection
of arbitrary exception/stage/result values. A new external candidate is built
without replacing the earlier candidate or the normal installed helper. These
source/protocol tests do not repeat account authentication; the caller must use
its explicitly authorized user flow for any later QR or genuine ownership test.
