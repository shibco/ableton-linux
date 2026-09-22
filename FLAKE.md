# Ableton Live Nix Flake

This project contains a nix flake to support common NixOS configurations, as well as any other Linux system using Nix.

Since NixOS does not allow dynamic library linking out of the box, the standard installer will fail.

Please read through this whole document before using the flake, as there are many options available.

## Installation

*Flakes are experimental and must be [enabled](https://wiki.nixos.org/wiki/Flakes#Setup).*

First, set up the wine prefix. This also builds and patches wine: 

```
nix run github:shibco/ableton-linux#setup-prefix
```

Note that building wine can take a considerable amount of time; you can mitigate this by maintaining a build with less frequent updates. More info is detailed [here](#pinning-solutions).


### Installing Live

Once the prefix is set up, you will be prompted to install Ableton Live. You can copy the command displayed, adding the path to your Ableton Live installer exe. You can also use the `#wine` option, which sets the wine prefix and uses the patched wine binary.

```
nix run github:shibco/ableton-linux#wine /path/to/ableton-live-installer.exe
```

You can also choose to auto-install Live while setting up the prefix. With a valid Live installer zip file in `~/Proprietary`, run:

```
nix run github:shibco/ableton-linux#setup-prefix --set-env-var ABLETON_LIVE_AUTOINSTALL 1
```

Or with your Live installer in any other directory run:

```
nix run github:shibco/ableton-linux#setup-prefix --set-env-var ABLETON_LIVE_AUTOINSTALL 1 --set-env-var LIVE_AUTOINSTALL_DIR /path/to/dir
```

### Adding the Flake to your System Config

You can use the default flake as a flake input and add it to your system config. You still need to run `#setup-prefix` manually one time to create the prefix.

With the flake provided as an input, you can add ableton-linux to your system packages (where `inputs.ableton-linux` is the flake input)

```
inputs.ableton-linux.packages.${pkgs.stdenv.hostPlatform.system}.default
```

This will add the `ableton-live` command and an Ableton Live desktop entry, both for launching Live. This also adds the `ableton-wine` command, which is a shortcut for setting the wine prefix to `~/.wine-ableton` and running the patched wine, the same as `nix run github:shibco/ableton-linux#wine`.

#### Basic Example

This example uses the basic flake on the [NixOS Wiki](https://wiki.nixos.org/wiki/NixOS_system_configuration#Accessing_flake_inputs), and allows the continued use of an already setup `configuration.nix`.

in your `flake.nix`:
```nix
{
  inputs.nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
  inputs.ableton-linux.url = "github:shibco/ableton-linux";

  outputs = { self, nixpkgs, ... }@inputs: {
    # replace nixos with your hostname
    nixosConfigurations.nixos = nixpkgs.lib.nixosSystem {
      specialArgs = { inherit inputs; };
      modules = [ ./configuration.nix ];
    };
  };
}
```

Then in your `configuration.nix` add `inputs` to the arguments:
```
{ config, pkgs, inputs, ... }:
```

Then add to your system packages:

```
environment.systemPackages = with pkgs; [
  inputs.ableton-linux.packages.${pkgs.stdenv.hostPlatform.system}.default
];
```

## Running Live

With the prefix setup and Live installed, you can run it with the default flake.

```
nix run github:shibco/ableton-linux
```

If the system package is installed, you can run it with `ableton-live` or through a program launcher using the desktop entry.

## Pinning Solutions 

Although `github:shibco/ableton-linux` is a convenient flake location, running Live with `nix run github:shibco/ableton-linux` will result in downloading the commit tarball (>100MB) for every new commit to `main` in the github repo, and rebuilding wine any time there is a change to the wine version or patches.

There are [several other ways](https://nix.dev/manual/nix/2.34/command-ref/new-cli/nix3-flake.html#flake-references) to reference the flake. In each case, replace `github:shibco/ableton-linux` with the alternative reference in any commands or config files.

To pin a specific commit, either to avoid updating, or to test a particular version or pull request, add the commit ID, eg. `github:shibco/ableton-linux/c2092f702531712950649c4f957caff8203b2199`.

To follow a specific branch, add the branch name, eg. `github:shibco/ableton-linux/main`.

To use a local copy, clone the repository and use the path to the local repo: either with the absolute path: `/path/to/flake/dir`, or for a relative path: `./relative/path/flake/dir`. Use just `.` if the repo is the current directory.

## Updating

If you are using `nix run`, the flake will automatically rebuild when the flake reference has updated. If used as a flake input, use `nix flake update`.

After an update, or to cause an update, it is recommended to run `#setup-prefix` with the `--refresh` flag.
```
nix run github:shibco/ableton-linux#setup-prefix -- --refresh
```
This applies any new changes to the wine prefix. This is an idempotent command, and can be run anytime and repeatedly, even without `-- --refresh`, which just skips steps which are unnecessary for updating an existing prefix.

## Uninstalling

There is no dedicated uninstaller. If using `nix run`, clearing your nix store cache will remove build artifacts. If using flake inputs, simply remove the flake from your config.

Dangling directories at `~/.local/share/ableton-wine` (contains a symlink), and `~/.local/state/ableton-wine` (contains logs) can be removed. For a complete uninstallation, you can also delete the prefix at `~/.wine-ableton`, but note that will delete Ableton Live and anything else installed in the prefix.

## Additional Options

You can also view all the possible flake options in [flake.nix](flake.nix).

### Default

Runs Live with the patched wine.

### Wine

`#wine` - runs the patched wine runtime in the `.wine-ableton` prefix. Use this for installing plugins, eg. `nix run github:shibco/ableton-linux#wine plugin-installer.exe`

If the system package is installed, `ableton-wine` does the same thing, eg. `ableton-wine plugin-installer.exe`.

### Setup Prefix

`#setup-prefix` - creates and prepares the wine prefix. Updates existing prefix. Can be run with `-- --refresh` to update the prefix.

### Check NTSync

`#check-ntsync` - runs the `check-ntsync.sh` script to check if the NTSync kernel module is enabled and working. 

### Audio Report
`#audio-report` - runs the `audio-report.sh` script, for troubleshooting audio issues. Prints the read-only audio diagnostic snapshot an issue report is expected to carry.

### Setup Realtime
`#setup-realtime` - Install the distribution-canon pro-audio profile (rtprio, swappiness, governor, asks for sudo)

### Setup Link
`#setup-link` - Set up Ableton Link networking (firewall port 20808) and enable the ableton-linkd user service

Commands include `enable`, `disable`, and `status`, eg `nix run github:shibco/ableton-linux#setup-link status`.

`enable` also supports setting the mode to `session` or `always`, eg `nix run github:shibco/ableton-linux#setup-link enable -- --mode=session`
