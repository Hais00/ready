<!-- SPDX-License-Identifier: GPL-3.0-only -->
# Restoring a saved Steam login after startup failure

An offline connection is separate from the profile's saved refresh credential.
The observed failure left the service at `offline/login_incomplete` after Ready
restarted, while the private credential file remained present and unchanged.
There was no current server result proving token rejection. The older preserved
AccessDenied diagnostic was from an earlier session.

The startup path now validates/selects saved credentials before attempting to
stop an earlier transport. Even that cleanup can fail or time out. Transient
saved-connect failures reuse the existing finite reconnection loop, with delays
of 1, 2, 4, 8, 16 and 30 seconds. They do not initiate QR/password authentication.
Explicit cancel/offline/logout, remote kicks, rejected credentials and permanent
login results do not trigger that automatic retry.

Cleanup rechecks its epoch after awaiting transport shutdown, so an older failure
cannot overwrite a newer logout/offline request. Each retry owns its exact local
cancellation source, and replacement loops cannot borrow a later loop's token.
Old cancellation sources are disposed after their task finishes. The initial
connect/reconnect service budget is capped at 30 seconds; the frontend allows
45 seconds so it does not cancel before backend cleanup/recovery can finish.

Manual Reconnect reloads the profile credential instead of assuming the service
already has one in memory. Startup transport stages are exposed through bounded
diagnostics and the account page distinguishes incomplete connection from a
request for new authorization. Credentials are still invalidated only under the
existing explicit logout or authoritative rejection rules.

The [validation checkpoint](../Validation/steam-startup-recovery-checkpoint.json)
includes controlled failure/race tests and a live saved-login restoration. Steam
returned OK using the original unchanged private file, without a new QR or
password. This does not promise recovery from every future outage or override
Steam's rejection of an account/token; exhausted retries leave Reconnect available.
