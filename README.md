# nixfs

The storage toolchain as a declared fact per host — resolved from nixpkgs on
NixOS and non-NixOS hosts alike, so the tools you reach for when a disk is
failing are pinned and identical everywhere.

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
  filesystems = [ "btrfs" "vfat" "exfat" "ntfs" ];
};
```

That host gets userland for those four formats plus the whole generic toolkit.
`enable = true` on its own is also a complete answer: the toolkit, and no
filesystem userland.

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
- `omit` — escape hatch, by nixpkgs attribute name. Always warns; see below.
- `packageNames` — read-only. What this host resolved to, without instantiating
  anything.

## Deliberate decisions

**One catalogue column, not two.** The sibling toolbox module resolves each tool
to both a nixpkgs attribute and a distro package, because dev tooling is fine —
often better — coming from whatever the host distro ships. Recovery tooling is
the opposite case. You reach for it when something is already broken, under time
pressure, usually on media you cannot re-read. That is the worst possible moment
to discover this machine's `ddrescue` is two years older than the one you
learned the flags on, or that `testdisk` is simply absent because nobody thought
to install it here. So nixfs resolves to nixpkgs on every host regardless of
distro, and accepts the duplicate copy as the price of the toolchain being
identical.

**One module file, both backends.** `nixosModules.default` and
`systemManagerModules.default` are the same file. That is not a convenience — it
is the whole point, and it is only possible *because* of the decision above:
resolving to nixpkgs everywhere leaves nothing platform-specific to write. CI
evaluates both backends on three different configurations and fails if they
disagree.

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

24 eval-time tests, no VM: the catalogue still resolves against nixpkgs, the
defaults are what the module claims, turning off one group removes exactly that
group's packages, the two backends agree, and the failure modes actually fail.

## Scope

nixfs installs tools. It does not mount anything, export anything, scrub
anything, or watch anything: mounting is native `fileSystems`, sharing belongs to
the NFS/CIFS layer, and periodic scrubs belong to whatever owns the pool. This is
the userland you need in your hands, and nothing else.
