# Persistent Steam service

`ReadySteamBridge.dll --service` adds one long-lived SteamKit connection per
profile process. The existing invocation without arguments keeps its one-shot
stdin request API. This service does not host Steamworks, launch games, download
games, send chat messages, or bypass Steam entitlement checks.

The caller starts the exact selected helper/runtime and supplies anonymous stdin
and stdout pipes. Every request has a fresh UUID `id`, UUID `profileID`, UUID
`profileGeneration`, and `operation`. The first request binds the process to that
profile and generation; subsequent mismatches or reused IDs terminate the
protocol. Responses preserve the request ID spelling. Profile/generation fields
are canonical UUIDs. Every event includes an increasing `sequence`; unsolicited
events have `id: null`.

Operation fields may be top-level, as in the Swift client, or inside `options`.
If `options` exists it must be an object and supplies those fields.

| Operation | Fields and behavior |
| --- | --- |
| `snapshot` | Offline-safe result with `state`, `reason`, `steamResult`, `connectionResultContext`, `account`, `friends`, capabilities and protocol version. It does not connect. |
| `connect` | Top-level `credentials: {username, refresh_token}`; logs on with the stored profile account. |
| `authenticate` | `method: qr` or `password`. Password mode accepts `username`/`password` operation fields or a top-level credentials object. It uses SteamKit's official authentication and Steam Guard interfaces. No automatic QR is started by another operation. |
| `guard_code` | `challengeID`, `code`; replies to the single active email/device-code challenge. A challenge can be answered once. Mobile approval emits a notification with no code challenge. Email addresses and codes are never echoed. |
| `friends` | Optional `offset`, `limit` (1–20000); result includes friends, total and next offset. |
| `set_presence` | Steam `EPersonaState` name, case insensitive. `Offline` disconnects and disables automatic reconnect. Other values update Steam persona state. |
| `set_persona_name` | Explicit `displayName` (1–128 characters, not blank, no control characters). Changes the public persona name through `SteamFriends.SetPersonaName`; the login `accountName` stays immutable. Waits for a matching `PersonaChangeCallback`. |
| `add_friend` | Explicit `steamID`; sends a request through `SteamFriends.AddFriend` and waits for the matching `FriendAddedCallback`. An OK callback acknowledges the request, **not** acceptance of friendship by the other person. |
| `remove_friend` | Explicit `steamID`; calls `RemoveFriend` and waits for a FriendsList callback proving relationship `None` (or absence from a complete list). An already absent relationship returns `unchanged`, without claiming a server acknowledgement. |
| `block_friend` / `unblock_friend` | Explicit `steamID`; uses the genuine `IgnoreFriend(steamID, true/false)` job and its `IgnoreFriendCallback` result. These actions do not send messages. |
| `authorize_game` | `gameID`; obtains a genuine ownership ticket through the current connection. Result requires successful matching AppID, nonempty ticket, and actual logged-in SteamID. Ticket bytes are cleared after the decision and never emitted. |
| `library` | Reuses the current connection's license callback and Steam PICS package/app APIs. Result has the existing `games[]` shape, including launch metadata. macOS platform metadata keeps architecture unknown. |
| `set_activity` | `gameID`, strict boolean `running`. Starting activity requires a successful ownership decision in the current connection epoch. Sends the upstream `ClientGamesPlayed` packet. The caller must send it **after** successful game launch; this operation does not prove or perform a launch. Stopping removes that game from the activity list. Optional titles are ignored. |
| `offline` | Disconnects, cancels jobs and disables automatic reconnect, retaining the in-memory refresh credential. |
| `reconnect` | Explicitly reconnects with the retained refresh credential; never starts QR authentication. |
| `logout` | Disconnects and disables reconnect. `forgetCredentials: true` additionally drops the in-memory refresh credential and returns `invalidateCredentials: true`. The caller controls the profile vault. |
| `cancel` | `requestID`; cancels that exact pending request. |
| `shutdown` | Cancels owned jobs, closes the owned transport and ends the process. EOF also disposes it. |

`qr`, `guard`, `credentials`, `result` and `error` correlate to their request ID.
`state`, `persona`, `friends` and `heartbeat` are unsolicited. Persona includes
`steamID`, `accountName`, `displayName`, and `presence`; friends include their
SteamID, display name, presence and optional current game ID/name. The credentials
event contains only `credentials: {username, refresh_token}` and belongs to the
private pipe. The caller must strip it before UI/log forwarding and save it only
to the matching profile/generation vault. A genuine newly issued refresh token is
emitted before CM logon, allowing a transient CM failure to retry without a second
QR. Passwords, Steam Guard codes, access tokens, tickets, exception messages and
stack traces are not output. Managed input strings are released by normal .NET
garbage collection; this is not a claim of deterministic string zeroization.

Friends snapshots preserve the actual SDK `relationship` enum, including
`Blocked`, `RequestRecipient` (incoming), `RequestInitiator` (outgoing), `Ignored`
and `IgnoredFriend`, as well as `Friend`. The SDK list contains these individual
relationships; it is not filtered to accepted friends. Social targets must be
decimal public-universe, individual, desktop-instance SteamIDs with a nonzero
account number, and must differ from the logged-in user's ID when known. No
account-name lookup, bulk action, automatic friend request or automatic rename
is performed.

Manual mutation results include `serverAcknowledged`, `requestSent`, `pending`,
`status`, `requestedAction`, optional `requestedSteamID`, plus the currently
observed account/friends snapshot. A missing callback after 15 seconds returns
`pending: true`; the state is not fabricated. Rename/add/remove APIs do not expose
job IDs, so the target's pending slot remains reserved after timeout or cancelled
waiting until a matching callback or connection reset. A retry in that interval
returns `awaiting_prior_confirmation` without resending. This prevents a late
reply from confirming a different request. Cancel stops waiting; it cannot retract
an action already sent to Steam. Block/unblock replies are tied to the exact job
and epoch; a job exception is an error, not a server acknowledgement. Rename
snapshots retain the last confirmed name rather than publishing SteamKit's eager
local-cache update as a confirmed public rename. Actual changes require explicit
user confirmation in the caller UI and genuine server acceptance.

The callback pump persists across reconnects. A network disconnect retries at
1, 2, 4, 8, 16 and 30 seconds, with a 30-second attempt budget, then requires an
explicit reconnect. A server LoggedOff callback, remote session replacement,
revocation, expired/invalid password, manual offline or logout suppresses these
retries. A LoggedOff notice describes the current CM session: it stops owned
activity and automatic retry but preserves the saved refresh credential, including
Expired/Revoked/InvalidPassword results. An explicit reconnect can try that
credential. Only a rejected LogOn response using it may emit
`invalidateCredentials: true` for Expired/Revoked/InvalidPassword/disabled/locked
results. Explicit user logout still forgets the selected profile normally.
The context is recorded as `logged_off` or `logon_response`; a reason string alone
never authorizes vault deletion. Server reasons/results are fixed names, never
raw exception text. Epoch checks precede applying failed as well as successful
logon results, preventing a late failure from erasing a newer session.
The service LoginID is random nonzero in `1...0x7fffffff`, separate from the
downloader's reserved `0xD0000000...0xDfffffff` range. Reconnect retains that LoginID.
Disconnect callbacks are drained before reusing the SteamClient, so an earlier
connection cannot satisfy/fail a later connection's completion source.

The previous frontend also erased the vault based on reason text alone; this
has been removed. Only an explicit strict-Boolean invalidation event from the
current service generation can authorize that operation. Fixed error classes
now distinguish network/timeout/rate-limit/session changes from a corroborated
ownership denial. A failed or malformed response never creates a game grant.
Private diagnostics retain only whitelisted result/context codes and comparison
booleans, not accounts, SteamIDs, token/ticket bytes, ticket digests or raw errors.

One live post-game interruption exposed the misleading error and an already
missing Ready credential item. The old service/frontend did not preserve the
exact server result/context, so the historical cause cannot be reconstructed
and no token-rotation claim follows. The context separation and stale-result
guards pass 177 service checks; frontend error/grant tests pass 100 checks.
Live repeat-launch validation of this correction is pending renewed user login;
the deleted credential cannot be recreated by installing the fix.

Limits: 64 KiB input characters per complete JSONL frame, 4 MiB output characters,
16 pending requests, 4096 unique requests per process, four-minute request budgets,
15-second service heartbeats, and 20000 library entries/friends. Restarting the
service after its request limit can reuse the profile's saved credentials. Invalid
frames/envelopes fail closed; the caller must supervise process termination.
Reconnect invalidates ownership/activity epoch state, so a later activity update
requires a fresh entitlement check. Current friends and activity updates depend
on actual Steam callback delivery; offline tests do not prove server delivery.

`Scripts/test_steam_persistent_service.py` builds an independent candidate on the
marked external work volume using the existing verified SDK/NuGet cache and
patched SteamKit sources. It does not select that candidate. The compiled fake
transport tests state changes, cancellation, Guard challenges, reconnect/backoff,
remote kicks, revocation, saved-credential reuse, profile/generation correlation,
ownership/activity boundaries and bounded frames. Separate actual-SteamKit
snapshot/shutdown and legacy self-test executions run under network denial.
No genuine login, real friends update, real presence change, real activity packet,
game launch, or download is claimed from those fixtures.
