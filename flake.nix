{
  description = "Ableton Live on Linux — patched Wine + PipeASIO";

  inputs.nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";

  outputs = { self, nixpkgs }: let
    system = "x86_64-linux";
    pkgs = nixpkgs.legacyPackages.${system};
  in {
    packages.${system} = rec {
      # The patched Wine 11.11 tree (D2D1-DCOMP + NSPA fixes, ntsync)
      wine-d2d1-nspa = pkgs.callPackage ./nix/wine.nix {
        wineSrc = ./vendor/wine-base-7ea0c8b7.tar.zst;
        patchesDir = ./patches;
        ntsyncUapi = ./vendor/ntsync-uapi;
      };

      # PipeASIO 1.2.2 (native PipeWire ASIO driver) compiled against the patched Wine
      pipeasio = pkgs.callPackage ./nix/pipeasio.nix {
        wine = wine-d2d1-nspa;
        pipeasioSrc = ./vendor/pipeasio-1.2.2.tar.gz;
        pipeasioPatches = ./patches/pipeasio;
      };

      # Combined runtime: Wine + PipeASIO + launcher scripts
      ableton-wine = pkgs.callPackage ./nix/ableton-wine.nix {
        wine = wine-d2d1-nspa;
        inherit pipeasio;
      };

      default = ableton-wine;
    };

    apps.${system} = {
      default = {
        type = "app";
        program = "${self.packages.${system}.ableton-wine}/bin/ableton-live";
        meta.description = "Launch Ableton Live through the patched Wine";
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
        meta.description = "Set up Ableton Link networking (multicast route + firewall) and enable the jack_link bridge";
      };
    };
  };
}
