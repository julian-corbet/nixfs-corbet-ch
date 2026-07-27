# Experiments

Throwaway trials: spikes, one-off scripts, measurements not yet worth writing
up properly. Nothing here is guaranteed to work, be maintained, or survive the
next cleanup pass. If something turns out to matter, distill the finding into
[`../studies/`](../studies/README.md) and let the experiment stay disposable.

This is also the open-questions ledger for nixfs's own judgment calls. Every
entry below is a design choice that is *reasoned*, not *measured* — recorded
here so the difference stays visible. Results feed back into `modules/nixfs.nix` and
`lib/catalogue.nix` as they close.

All open; nothing has been run yet.

## 001 — should any `tools.*` group default OFF?

**Question:** all five groups default to `true`, on the reasoning that the generic toolkit is not
a per-host judgment call.

**Reasoning as it stands:** the failure this project exists to remove is "the tool was not there
when I needed it". Defaulting a group off recreates exactly that, and shifts the burden onto every
host to remember something it has no reason to think about until the bad day.

**What would settle it:** the counter-argument is closure size on machines that will never use a
group. Measure the real delta per group against a minimal system closure, rather than the summed
size of the packages, which double-counts everything they share. If one group is disproportionate,
its default is worth re-litigating; the rest are not.

## 002 — is the group the right granularity, or should it be per-tool?

**Question:** `inspection` is eight packages behind one boolean. A host wanting smartctl but not
sg3_utils has to take both.

**Reasoning as it stands:** these travel together in practice — nobody wants SMART but not NVMe on
a box that has both kinds of drive — and per-tool options here would be a dozen booleans nobody
sets, which is a worse interface than one that is occasionally slightly too generous.

**What would settle it:** an actual host that wants part of a group and has a real reason. Until
one exists, splitting would be speculative. `omit` already covers the one-off case without adding
option surface.

## 003 — is the catalogue missing a filesystem that actually turns up?

**Question:** the table covers ext, FAT, exFAT, NTFS, XFS, btrfs, F2FS, HFS+, UDF, JFS and NILFS2.
Old media is exactly where a gap would hide.

**Reasoning as it stands:** this is the set with live nixpkgs packaging and plausible presence on
media someone would still try to read. ReiserFS is absent because the package is gone from
nixpkgs, not because it was skipped.

**What would settle it:** the first time a host meets a volume it cannot identify. Record what it
was; that is the experiment. Until then any addition would be speculative, and shipping a package
nobody has needed is a worse default than shipping a gap somebody will report.
