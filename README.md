# nixfs

The storage toolchain as a declared fact per host — resolved PER PLATFORM (a
pacman/AUR name on Arch, a nixpkgs attribute on NixOS) so the tools you reach
for when a disk is failing are actually reachable everywhere, not just pinned
somewhere nobody's `PATH` will find them.

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
```

On a NixOS host:

```nix
imports = [ inputs.nixfs.nixosModules.default ];
nixfs = {
  enable = true;
  filesystems = [ "btrfs" "vfat" "exfat" "ntfs" ];
};
```

On an Arch host running system-manager:

```nix
imports = [ inputs.nixfs.systemManagerModules.default ];
nixfs = {
  enable = true;
  filesystems = [ "btrfs" "vfat" "exfat" "ntfs" ];
};
# and, wherever this host's own pacman/AUR reconciler is configured:
nixarch.packages.pacman = config.nixfs.archPackages;
nixarch.packages.aur = config.nixfs.aurPackages;
```

That host gets userland for those four formats plus the whole generic toolkit.
`enable = true` on its own is also a complete answer: the toolkit, and no
filesystem userland. Which backend installs how much differs by design — see
"Deliberate decisions" below — but what a host is declared to want is identical
either way.

## Two halves, because they are two different questions

**`filesystems` is a per-host fact, so you declare it.** Which on-disk formats
a machine deals with cannot be derived. What it *mounts* is already NixOS's job
— userland for anything in `fileSystems.*` arrives automatically and nixfs does
not duplicate it. What it *meets* is a property of what people plug into it,
which no configuration can see. On a non-NixOS host neither half is handled, so
list what it mounts here too.

For every format at once, use the flake's own list rather than copying one:

```nix
nixfs.filesystems = inputs.nixfs.lib.allFilesystems;
```

**`tools.*` is not a per-host fact, so it defaults on.** Imaging a failing
device, asking a drive for its SMART counters, editing a partition table,
watching a long copy actually move — none of that is specific to an on-disk
format or to what a machine is for. It is the generic storage toolkit, so the
question a host answers is not *do I want this* but *can I actually use it*.

| group | what it is for | packages |
|---|---|---|
| `recovery` | get data off failing or damaged media | ddrescue, testdisk |
| `inspection` | ask the hardware what it thinks | smartmontools, hdparm, sdparm, nvme-cli, lsscsi, sg3_utils, usbutils, pciutils |
| `partitioning` | read, edit and back up partition tables | gptfdisk, parted |
| `volumes` | open the block layers between a disk and its filesystem | lvm2, mdadm, cryptsetup |
| `throughput` | see a long operation move, and measure what a drive really does | pv, fio |

Turn one off where the answer is genuinely no — a container with no block
devices of its own, a guest whose virtual disk has no SMART data to report, a
machine small enough that the closure matters — and say why in the host config:

```nix
nixfs = {
  enable = true;
  filesystems = [ "btrfs" ];
  tools = {
    recovery.enable = false;      # network-backed virtual disk; imaging it is meaningless
    inspection.enable = false;    # no SMART data behind a hypervisor
    partitioning.enable = false;
    volumes.enable = false;
    throughput.enable = false;
  };
};
```

> An earlier version collapsed both halves into a single four-value "media
> exposure" tier. That was wrong: it made *which filesystems* and *which tools*
> move together when they are independent, and it made a host describe itself
> with one word from a taxonomy invented here instead of stating the two things
> it actually knows.

## Options

`nixfs.*`:

- `enable` — turn the module on.
- `filesystems` — which on-disk formats this host needs userland for. Empty is a
  legitimate answer, and the right one for a machine that owns no block devices.
- `tools.<group>.enable` — one boolean per group above, all `true` by default.
- `omit` — escape hatch, by nixpkgs attribute name. Removes the named entry from
  BOTH channels at once. Always warns; see below.
- `packageNames` — read-only. The resolved selection as nixpkgs attribute names
  — what a NixOS host actually installs, and, on Arch, the identity every entry
  is named by regardless of channel.
- `archPackages` / `aurPackages` — read-only. The resolved selection as pacman /
  AUR package names, for an Arch host's own reconciler:
  `nixarch.packages.pacman = config.nixfs.archPackages;`. `aurPackages` is empty
  today — nothing in the catalogue is AUR-only yet — but exists for the same
  reason it exists in the sibling nixdev/nixoffice catalogues: the day an entry
  needs it, the option surface should not be a surprise.
- `unavailableOnArch` — read-only. Selected entries with no Arch package at all,
  by nixpkgs attribute name. These are the ones an Arch host still gets from
  nixpkgs — see below for why that is the one case where reaching for nixpkgs on
  a non-NixOS host is correct rather than the bug this project exists to fix.

## Deliberate decisions

**Two catalogue columns, not one.** This module used to resolve every entry to
nixpkgs only, on every host, and argued that recovery tooling was worth pinning
identically everywhere at the price of a duplicate copy. That bargain did not
hold, and it failed for a reason that has nothing to do with staleness: on a
live Arch host, `/usr/sbin` precedes the system-manager Nix profile on `PATH`,
so the distro's own `mkfs.xfs`, `smartctl`, `pv`, `lsscsi`, `mkfs.f2fs`,
`mcopy`, `mdadm` and `hdparm` all won every lookup, and the pinned nixpkgs
copies sat in `/run/system-manager/sw/bin`, never once reached by a bare
command name. The price actually paid was not the duplicate disk space — it was
the pin becoming decorative. So nixfs now names every entry twice, `arch` and
`nixpkgs`, the same shape as the sibling nixdev/nixoffice catalogues, and
resolves per platform instead. See `lib/catalogue.nix`'s own header for the
full account.

**Two different backends, because the platforms are not symmetric.** A NixOS
host has no second package manager to lose a `PATH` race against, so
`nixosModules.default` still installs every selected entry from nixpkgs,
unconditionally — the simple case, unchanged. An Arch host running
`systemManagerModules.default` gets pacman/AUR names published for its own
reconciler, and nixpkgs reached for ONLY on the entries Arch has nothing for at
all (`unavailableOnArch`, e.g. `hfsprogs` — AUR-only upstream, no official Arch
package). No entry is ever installed by both channels on the same host; CI
proves that property directly, as a real evaluation of both backends against
the real catalogue, not merely inferred from the code being structured that
way.

**A missing package is a build failure, not a warning.** nixpkgs drops packages
— ReiserFS tooling went when the kernel dropped the filesystem. No entry here is
optional; every one was asked for. A recovery tool that quietly stopped being
installed some months ago, discovered while a disk is dying, is the worst
outcome this module can produce, so it fails at eval with the name in the
message.

**ZFS is deliberately absent and always will be.** Its userland must match the
loaded kernel module exactly, so it can only come from whatever provides that
module — `boot.zfs` on NixOS, the distro's own packaging elsewhere. A second,
independently versioned copy installed from here is a hazard, not a convenience.
A CI check exists so that adding it later has to be a deliberate, visible act
rather than a plausible-looking one-line addition.

**`omit` always warns, and a stale entry is an error.** It exists for one honest
case: a package broken or marked insecure in the pinned nixpkgs, where the
alternative is that the host cannot build at all. It keeps warning until removed,
because a host quietly missing part of its toolchain is exactly what nixfs
exists to prevent — and omitting something the host was never going to install
fails the build, so an entry cannot sit in a config looking meaningful after
whatever pulled it in is gone.

## Family convention: consuming `lib.catalogue` (or any sibling's shared fact) never through `_module.args`

This section binds every project in the family, not just this one — it lives
here because `nixfs.lib.catalogue` is the shared fact that first taught it.

`nixfs.lib.catalogue` is data, not a module: no `enable`, no config surface,
just the f2fs recipe (mkfs feature bits, mount options, the kernel floor they
need) as a plain attrset. Two sibling flakes — `nixnas` and `nixvault` — each
consume it to build their own f2fs container, and each publishes a NixOS
module of its own for a downstream host to import. The question both had to
answer is *how does a plain fetched value become an argument inside a module
someone else composes* — and there is exactly one safe answer.

**The wrong shape:** thread the value through as `_module.args.nixfsCatalogue`,
so any module imported alongside yours can reach it as an ordinary module
argument. It works — right up until a second flake, on the exact same host,
does the same thing under the same name. `nixnas` and `nixvault` both did:
correct in each flake alone, and a hard *"the option ... is defined multiple
times"* evaluation failure the one time a consumer (`infra`'s `mkNixnas`)
composed both together. `_module.args` is not per-flake — it is ONE namespace
shared by every module composed onto that host, merged with
`mergeOneOption`, which rejects a second definition **even when both values
are byte-identical**. And because the collision is between two *module
arguments*, not two *flake inputs*, no `inputs.<x>.follows` pin can rescue
it — `follows` only ever collapses which upstream flake gets fetched, never
what name a module publishes into the shared argument namespace.

**The shape that works: partial application.** Close over the value in your
own `flake.nix`, before the module system ever runs — `import
./modules/your-module.nix { nixfsCatalogue = nixfs.lib.catalogue; }` — so the
file returns the fully-applied `{ config, lib, pkgs, ... }:` function the
module system actually expects. The outer `{ nixfsCatalogue }:` layer is
called once, by you, and is gone by the time anything merges module
arguments; `nixfsCatalogue` never becomes a name in that namespace at all, so
a sibling flake making the identical choice about the identical fact cannot
collide with you, regardless of which argument name it happens to pick.
`nixnas` (`modules/default.nix`) and `nixvault` (`flake.nix`) both fixed the
same collision this way, independently, and converged on the identical
shape — see either file's own header for the in-repo version of this note.

The rule generalises past this one fact: **a flake must never publish a fact
it consumes through `_module.args`.** Any shared value from any sibling —
this catalogue, a future one from `nixram` or `nixiam`, anything — gets
closed over as a plain function argument before your module file is handed
to `imports`, never threaded through as a module argument for consumers to
pick up implicitly.

## Tests

```
nix flake check
```

43 eval-time tests, no VM: the channel resolution against fixtures covering
shapes the real catalogue does not happen to have yet (an AUR entry, a
diverging arch/nixpkgs name), the real catalogue against both backends'
option surfaces, the defaults are what the module claims, turning off one
group removes exactly that group's packages, both backends agree on WHAT is
wanted, and — the property this project exists for — neither backend ever
installs the same entry twice: an Arch host installs a selected entry from
nixpkgs if and only if Arch has no package for it at all.

## Scope

nixfs installs tools. It does not mount anything, export anything, scrub
anything, or watch anything: mounting is native `fileSystems`, sharing belongs to
the NFS/CIFS layer, and periodic scrubs belong to whatever owns the pool. This is
the userland you need in your hands, and nothing else.
