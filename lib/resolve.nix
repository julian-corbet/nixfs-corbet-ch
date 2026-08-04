#
# The channel resolution: pure functions from a list of selected catalogue entries to the
# per-channel outputs a platform backend consumes.
#
# WHY THESE ARE NOT INLINE IN modules/nixfs.nix, the same reasoning as the sibling nixoffice's
# version of this file: inline, the only input they could ever be tested against is the REAL
# catalogue in ../lib/catalogue.nix, which is a table of what happens to be selected today, not a
# set of fixtures chosen to exercise every branch. ../lib/catalogue.nix does have a live `aur = true`
# entry today (`hfsprogs`), but it has no live `arch = null` entry -- every catalogue member has a
# real Arch source, official repo or AUR -- so ../checks/default.nix still drives that branch with
# a fixture rather than a real one.
#
# ONLY TWO CHANNELS HERE, unlike nixoffice's three: nixfs has no Flatpak-equivalent third delivery
# path, so there is no `flatpakApps` to write. Every entry in ../lib/catalogue.nix carries a
# `nixpkgs` name (nixfs has no channel-less entry, unlike nixoffice's DieBahn), so there is also no
# `unavailableOnNixos` here -- the direction that matters for THIS catalogue is the other one: which
# entries have no Arch package at all (official repo OR AUR), and must come from nixpkgs even on a
# non-NixOS host.
#
# EVERY ARCH FIELD IS INDEPENDENTLY NULLABLE, which is the rule the functions below are written
# around: an entry may have a pacman name, or none at all (`arch = null`) where Arch offers nothing.
# So the entry's own catalogue key -- `name`, attached by ../modules/nixfs.nix before calling these
# -- is what anything REPORTING about an entry reports it BY, never one of the channel names
# themselves. For nixfs specifically that key is always the entry's own `nixpkgs` attribute name
# (see ../lib/catalogue.nix), but the functions here do not depend on that coincidence.
{ lib }:
rec {
  # Official-repo pacman names. `aur = true` entries are held back for aurPackages: `pacman -S`
  # cannot resolve an AUR name and fails the WHOLE transaction on "target not found", taking every
  # other package in the same converge with it.
  archPackages = selected:
    lib.unique (map (t: t.arch)
      (lib.filter (t: (t.arch or null) != null && !(t.aur or false)) selected));

  aurPackages = selected:
    lib.unique (map (t: t.arch)
      (lib.filter (t: (t.arch or null) != null && (t.aur or false)) selected));

  # Entries with no Arch package at all -- the ones a non-NixOS host can only ever get from nixpkgs,
  # because there is nothing else to reach for. Gated on the missing `arch` field and NOTHING else,
  # the same discipline as nixoffice's `unavailableOnNixos`: which other channels an entry happens
  # to carry says nothing about whether Arch can install it.
  unavailableOnArch = selected:
    lib.unique (map (t: t.name) (lib.filter (t: (t.arch or null) == null) selected));
}
