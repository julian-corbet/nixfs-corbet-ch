# nixfs

The filesystem, block-layer and recovery toolchain as one declared fact per
host — resolved from nixpkgs on NixOS and non-NixOS hosts alike, so the tools
you reach for when a disk is failing are pinned and identical everywhere.

The thesis in three sentences: NixOS already installs check/repair userland for
the filesystems a host **mounts**, and nothing anywhere installs userland for
the filesystems a host **meets** — a USB stick, a disk pulled from a retired
machine, an SD card someone hands you. On a host whose own distro is not NixOS,
nothing installs either kind, so those tools arrive by hand at whatever version
the distro shipped the day somebody remembered, or they never arrive at all.
Both halves are the same failure, and it is the worst-shaped one available: you
discover which tools are missing at the exact moment you need them.

## Quickstart

```nix
{
  inputs.nixfs.url = "github:julian-corbet/nixfs-corbet-ch";
}
# in your nixosSystem modules — or, unchanged, in a system-manager config:
imports = [ inputs.nixfs.nixosModules.default ];
nixfs = {
  enable = true;
  media = "removable";
};
```

There is no default `media` and there never will be a guessed one. Too low a
tier installs nothing and looks perfectly healthy right up until the tools are
needed, so an unset `media` is a hard evaluation error rather than a fallback.

## The one option that matters

`nixfs.media` answers a single question: **what kinds of storage does this
machine encounter?** Everything else follows from it.

| tier | what it means | what it adds |
|---|---|---|
| `none` | No block devices of its own — a container, or a guest handed one virtual disk it never inspects. | Nothing. Declare `nixfs.filesystems` for whatever it does mount. |
| `fixed` | Owns its disks; nothing foreign is ever plugged in. | Drive health (SMART, ATA, NVMe, bus), partitioning, LUKS. |
| `removable` | People plug things into it. | The formats consumer devices ship with (FAT, exFAT, NTFS), the block layers a foreign Linux disk hides its filesystem under (LVM, MD), and data recovery. |
| `arbitrary` | Media of unknown and possibly ancient format arrives to be ingested. | Everything — including the formats nothing creates today, which is precisely why they turn up on old disks. |

Every other way of slicing this turned out to be a proxy for that question. A
server that ingests old drives and a server that only ever sees its own NVMe
want completely different toolchains, and calling both "server" hides that — so
the tier is named after the exposure itself.

Each tier is a strict superset of the one below it **by construction, not by
promise**: `media.nix` lets a tier declare only what it *adds*, and the
cumulative set is computed. There is no way to express "remove" there, so
moving a host up a tier can only ever add tools. CI checks it anyway.

## Options

`nixfs.*`:

- `enable` — turn the module on.
- `media` — `"none"`, `"fixed"`, `"removable"` or `"arbitrary"`. No default;
  see above.
- `filesystems` — filesystem userland this host needs *beyond* its tier,
  normally the filesystems it actually mounts. Additive. On NixOS this is
  usually unnecessary (anything in `fileSystems.*` is already handled and nixfs
  does not duplicate it); on a non-NixOS host nothing does it for you.
- `volumes` / `recovery` / `inspection` / `partitioning` / `throughput` —
  additive per-group selections on top of the tier, for the host that needs one
  more thing than its tier gives it.
- `omit` — escape hatch, written as `"<group>.<key>"`. Always warns; see below.
- `selected` / `packageNames` — read-only. What this host resolved to, without
  instantiating anything.

## Deliberate decisions

**One catalogue column, not two.** The sibling toolbox module resolves each
tool to both a nixpkgs attribute and a distro package, because dev tooling is
fine — often better — coming from whatever the host distro ships. Recovery
tooling is the opposite case. You reach for it when something is already
broken, under time pressure, usually on media you cannot re-read. That is the
worst possible moment to discover this machine's `ddrescue` is two years older
than the one you learned the flags on, or that `testdisk` is simply absent
because nobody thought to install it here. So nixfs resolves to nixpkgs on
every host regardless of distro, and accepts the duplicate copy as the price of
the toolchain being identical.

**One module file, both backends.** `nixosModules.default` and
`systemManagerModules.default` are the same file. That is not a convenience —
it is the whole point, and it is only possible *because* of the decision above:
resolving to nixpkgs everywhere leaves nothing platform-specific to write.
CI evaluates both backends at every tier and fails if the two ever disagree.

**A missing package is a build failure, not a warning.** nixpkgs drops
packages — ReiserFS tooling went when the kernel dropped the filesystem. No
entry here is optional; every one was asked for. A recovery tool that quietly
stopped being installed some months ago, discovered while a disk is dying, is
the worst outcome this module can produce, so it fails at eval with the name in
the message.

**ZFS is deliberately absent and always will be.** Its userland must match the
loaded kernel module exactly, so it can only come from whatever provides that
module — `boot.zfs` on NixOS, the distro's own packaging elsewhere. A second,
independently versioned copy installed from here is a hazard, not a
convenience. A CI check exists so that adding it later has to be a deliberate,
visible act rather than a plausible-looking one-line addition.

**`omit` always warns, and the warning does not go away.** It exists for one
honest case: a package broken or marked insecure in the pinned nixpkgs, where
the alternative is that the host cannot build at all. A host quietly missing
part of its recovery toolchain is the exact situation nixfs exists to prevent,
so it keeps saying so until the omission is removed.

## Tests

```
nix flake check
```

24 eval-time tests, no VM. They cover the three claims worth failing CI over:
the catalogue still resolves against nixpkgs, the tiers are monotone, and the
two backends agree. Plus the failure modes actually failing — unset `media`, a
typo'd `omit` key — because an assertion nobody has watched fire is a comment.

## Scope

nixfs installs tools. It does not mount anything, export anything, scrub
anything, or watch anything: mounting is native `fileSystems`, sharing belongs
to the NFS/CIFS layer, and periodic scrubs belong to whatever owns the pool.
This is the userland you need in your hands, and nothing else.
