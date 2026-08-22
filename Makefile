# Convenience wrapper over the scripts. See README.md.
.PHONY: all build install setup refresh uninstall test vendor-cache verify check pointer-safety-check clean distclean

all: build

build:                        ## build runtime and Link helper with Podman -> dist/
	./build.sh

install:                      ## install the built Wine tree + launcher (end user)
	./scripts/installer.sh install --skip-live-install

setup:                        ## create the Wine prefix (end user)
	./scripts/installer.sh prefix create

refresh:                      ## refresh the existing Wine prefix (end user)
	./scripts/installer.sh prefix update

uninstall:                    ## remove installed Wine tree + launcher
	./scripts/installer.sh uninstall --keep-prefix

test:                         ## run installer and launcher lifecycle gates
	./scripts/test-tsan-policy.sh
	./scripts/test-release-policy.sh
	./scripts/test-shortcut-hold.sh
	./scripts/test-desktop-integration.sh
	./scripts/test-nix-packaging.sh
	./scripts/test-installer-lifecycle.sh
	./scripts/test-pipeasio-installer.sh

vendor-cache:                 ## populate vendor/winetricks-cache for offline setup
	./scripts/vendor-winetricks-cache.sh

verify: pointer-safety-check  ## check vendored inputs and pointer safety rules
	cd vendor && sha256sum -c wine-base.sha256 pipeasio.sha256 pipewire-sdk.sha256 ntsync-uapi.sha256 link.sha256 cabextract.sha256 bitstream-vera.sha256 llvm-apt-key.sha256

check: pointer-safety-check   ## run deterministic pointer safety checks

pointer-safety-check:
	@set -eu; \
	trap 'rm -f -- tools/.pointer-safety-invariants.tmp' EXIT HUP INT TERM; \
	$(CC) -std=c11 -O2 -Wall -Wextra -Werror \
		tools/pointer-safety-invariants.c -lm -o tools/.pointer-safety-invariants.tmp; \
	tools/.pointer-safety-invariants.tmp \
		patches/0090-winex11-preserve-precision-scrolling-from-XInput2-scroll-.patch \
		patches/0091-winex11-coast-scrolling-and-thrown-middle-drags-after-rel.patch \
		patches/0074-winex11-server-report-a-touchpad-pinch-as-Ctrl-tagged-whe.patch \
		patches/0072-winex11-registry-pointer-settings-and-middle-button-dra.patch \
		patches/0092-winex11-bound-and-isolate-pointer-gesture-output.patch \
		patches/0093-winex11-release-stale-cursor-clipping-state-when-X-f.patch \
		patches/0094-winex11-emulate-only-observed-failed-pointer-warps-o.patch \
		patches/0095-winex11-separate-pointer-coast-sources.patch \
		patches/0097-winex11-restore-pointer-inertia-and-ignore-held-scroll.patch \
		patches/0098-winex11-suspend-XI-scroll-selection-during-core-drags.patch

clean:                        ## remove build outputs
	rm -rf dist

distclean: clean              ## also drop the container image
	-$${ENGINE:-podman} rmi ableton-wine-build:22.04
