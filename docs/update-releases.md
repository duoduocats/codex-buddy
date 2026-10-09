# Update release operations

The maintainer chooses `none`, `notify`, or `silent` for each release. Beta receipt
is a separate client preference, off by default. All changes still require local
installation, review, and explicit publication approval.

Stable updates always use GitHub's recommended Latest release. Beta-enabled
clients add eligible public Beta releases to that candidate set. Removing a
stable version from Latest prevents this client from selecting it even when its
historical download page remains public. A newer installed version is never
automatically downgraded. Withdraw a broken version and issue a higher repair
version for clients which already installed it.

Successful routine checks run six hours apart. Failed checks retry after one,
five, fifteen, then sixty minutes, preserving the last successful check time.
Network recovery and wake can bring forward connection-failure retries. Server
Retry-After and rate-limit reset instructions take precedence, including during
manual checks. In-memory ETag/Last-Modified conditional requests reuse unchanged
responses without weakening origin, size, policy, or package validation.

## Optional phased release

Omitting `--rollout-percentage` preserves the existing all-users behavior and
schema 1/2 metadata. An explicitly chosen percentage uses schema 3:

```sh
python3 scripts/prepare-release.py 2.5.0-beta.1 --mode none --rollout-percentage 10
```

This only prepares a local reviewable candidate. It does not publish anything.
The workflow's optional percentage field preserves saved metadata when blank.
The mode remains a separate explicit choice; a percentage never implies silent
installation or a notification policy.

The client keeps a random installation ID locally and hashes it into a stable
cohort. Increasing 10 to 50 to 100 includes earlier members. No ID, cohort,
update status or usage is uploaded. A manual check/download can bypass the
percentage, while still respecting Beta opt-out, ignored-request races, version
ordering, origin and integrity checks. Percentage 0 pauses background distribution;
it is not an emergency withdrawal because manual installation remains possible.

Older clients do not implement schema 3 and safely treat it as unverified policy,
so they do not silently install or receive its automatic notification. Their
existing manual download behavior remains. Use phased metadata only after the
compatible updater is available; do not claim it controls older clients.

## Replacement and recovery

The updater checks recommendation/channel membership, asset digests and policy
again before downloading and after staging. A changed or withdrawn offer is
discarded before the old app exits. Only protocol-1 replacement apps support the
new startup acknowledgement; legacy bundles cannot be replaced through this path.

The helper retains the prior app, launches the replacement with a private local
token, and waits up to 30 seconds for its native initialization receipt. It also
checks that the exact spawned process remains alive immediately afterwards.
No network or quota response is required. Failure terminates only that process,
restores and relaunches the prior app, and keeps local recovery information.
Compatible prior clients record the failed version and suppress another automatic
attempt; a deliberate manual retry remains possible.

Clients with the earlier updater cannot acquire these new guarantees retroactively.
Startup confirmation catches crashes and hangs during initialization, not layout
or functional defects after startup. Continue real UI regression checks and Beta
validation before wider distribution.

## Public messages and activity data

These data checks are separate from software release checks. During the active
campaign, successful checks run five minutes apart. Failures retry after one,
five, fifteen, then sixty minutes; server Retry-After and quota reset deadlines
still take precedence across restart, wake, manual checks and window opens.
Inactive campaign history checks run hourly. Receiving switches stop requests.

The fixed raw feed remains the usual source. Connection failures and unavailable
or malformed responses can use the same public repository's Contents API without
credentials. Foreground activity opens verify this official branch endpoint even
when an intermediary returns an old raw-source 304. Validators are scoped to
their source; a successful alternate stays usable, and an hourly byte comparison
can return it to the CDN when the content matches the validated cache. Existing
schema and revision checks still reject altered or older history.

Network recovery uses the existing native path monitor. No new background timer,
account identifier, cookie, credential, third-party mirror or telemetry is added.
The anonymous Contents API remains subject to GitHub's rate limits; a final
successful quota-zero response is retained while its next deadline is respected.
