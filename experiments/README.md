# Experiments

Throwaway trials: spikes, one-off scripts, measurements not yet worth writing
up properly. Nothing here is guaranteed to work, be maintained, or survive the
next cleanup pass. If something turns out to matter, distill the finding into
[`../studies/`](../studies/README.md) and let the experiment stay disposable.

This is also the open-questions ledger for nixfs's own judgment calls. Every
entry below is a design choice that is *reasoned*, not *measured* — recorded
here so the difference stays visible. Results feed back into `media.nix` and
`lib/catalogue.nix` as they close.

All open; nothing has been run yet.

## 001 — is `removable` the right tier for data recovery?

**Question:** `ddrescue` and `testdisk` sit at `removable`, not `arbitrary`.

**Reasoning as it stands:** the moment someone hands you a dying stick is the
moment you need `ddrescue`, and that happens on any machine people plug things
into — not only on a host whose job is ingesting unknown media. Putting
recovery one tier higher would mean the common case (a laptop, a failing USB
drive, data that exists nowhere else) is the case that does not have the tool.

**What would settle it:** the counter-argument is closure size on machines that
will never use it. Measure the actual delta these two add to a `removable`
closure, and weigh it against how often a `removable` host has genuinely needed
them. If the delta is negligible the question is closed by default; if it is
large the tier boundary deserves re-litigating rather than defending.

## 002 — should `fixed` include drive-health tooling on virtualised disks?

**Question:** `fixed` contributes `smartmontools`, `hdparm` and `nvme-cli`. On
a cloud guest whose "disk" is a network-backed virtual block device, none of
those return anything meaningful.

**Reasoning as it stands:** the tier is about what the machine *encounters*,
and a guest handed one virtual disk it never inspects is already described by
`none` — so a host in that position should be declaring `none`, not `fixed`,
and the tier table is not wrong. But that puts the burden on picking the tier
correctly, and "it owns its disk" reads like `fixed` to most operators.

**What would settle it:** whether real configs pick the tier the table intends.
If hosts keep landing on `fixed` when `none` is correct, the tier names are
wrong, not the operators.

## 003 — is the catalogue missing a filesystem that actually turns up?

**Question:** the table covers ext, FAT, exFAT, NTFS, XFS, btrfs, F2FS, HFS+,
UDF, JFS and NILFS2. Old media is exactly where a gap would hide.

**Reasoning as it stands:** this is the set with live nixpkgs packaging and
plausible presence on media someone would still try to read. ReiserFS is
absent because the package is gone from nixpkgs, not because it was skipped.

**What would settle it:** the first time an `arbitrary` host meets a volume it
cannot identify. Record what it was; that is the experiment. Until then any
addition would be speculative, and shipping a package nobody has needed is a
worse default than shipping a gap somebody will report.
