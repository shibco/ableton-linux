{
  description = "Ableton Live on Linux — patched Wine + PipeASIO";

  inputs.nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";

  outputs = { self, nixpkgs }: let
    system = "x86_64-linux";
    pkgs = nixpkgs.legacyPackages.${system};
  in {
    packages.${system} = rec {
      # The patched Wine 11.13 tree (D2D1-DCOMP + NSPA fixes, ntsync)
      wine-d2d1-nspa = pkgs.callPackage ./nix/wine.nix {
        wineSrc = ./vendor/wine-base-5c23dd1c.tar.zst;
        patchesDir = ./patches;
        ntsyncUapi = ./vendor/ntsync-uapi;
      };

      # PipeASIO 1.5.0 (native PipeWire ASIO driver) compiled against the patched Wine
      pipeasio = pkgs.callPackage ./nix/pipeasio.nix {
        wine = wine-d2d1-nspa;
        pipeasioSrc = ./vendor/pipeasio-1.5.0.tar.gz;
        patchesDir = ./patches;
      };

      # The Ableton Link session anchor the launcher and setup-link.sh drive
      ableton-linkd = pkgs.callPackage ./nix/ableton-linkd.nix {
        daemonSrc = ./tools/ableton-linkd.cpp;
        linkSrc = ./vendor/link-4.0.tar.zst;
        linkSha256 = ./vendor/link.sha256;
      };

      # Combined runtime: Wine + PipeASIO + Link anchor + launcher scripts
      ableton-wine = pkgs.callPackage ./nix/ableton-wine.nix {
        wine = wine-d2d1-nspa;
        inherit pipeasio ableton-linkd;
        patchesDir = ./patches;
      };

      default = ableton-wine;
    };

    apps.${system} = {
      default = {
        type = "app";
        program = "${self.packages.${system}.ableton-wine}/bin/ableton-live";
        meta.description = "Launch Ableton Live through the patched Wine";
      };
      wine = {
        type = "app";
        program = "${self.packages.${system}.ableton-wine}/bin/ableton-wine";
        meta.description = "Run a Windows executable (plugin installer, updater, copy-protection tool) in the Ableton prefix on this runtime";
      };
      check-ntsync = {
        type = "app";
        program = "${self.packages.${system}.ableton-wine}/share/ableton-wine/scripts/check-ntsync.sh";
        meta.description = "Verify this runtime uses /dev/ntsync and that NT sync semantics hold (needs a prefix no wineserver is serving)";
      };
      setup-prefix = {
        type = "app";
        program = "${self.packages.${system}.ableton-wine}/share/ableton-wine/scripts/setup-prefix.sh";
        meta.description = "Create or refresh the Ableton Wine prefix (ABLETON_LIVE_AUTOINSTALL=1 also installs Live from ~/Proprietary)";
      };
      setup-realtime = {
        type = "app";
        program = "${self.packages.${system}.ableton-wine}/share/ableton-wine/scripts/setup-realtime.sh";
        meta.description = "Install the distribution-canon pro-audio profile (rtprio, swappiness, governor; needs sudo)";
      };
      setup-link = {
        type = "app";
        program = "${self.packages.${system}.ableton-wine}/share/ableton-wine/scripts/setup-link.sh";
        meta.description = "Set up Ableton Link networking (firewall port 20808) and enable the ableton-linkd user service";
      };
    };
  };
}
