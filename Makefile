# Convenience wrapper over the scripts. See README.md.
.PHONY: all build install setup refresh uninstall test test-glyph-path vendor-cache verify check pointer-safety-check clean distclean

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
	./scripts/test-live-options.sh
	./scripts/test-desktop-integration.sh
	./scripts/test-installer-lifecycle.sh
	./scripts/test-pipeasio-installer.sh

test-glyph-path:              ## assert a built runtime's dwrite glyph path (RUNTIME=<root>)
	./scripts/test-dwrite-glyph-path.sh $(RUNTIME)

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
	tools/.pointer-safety-invariants.tmp

clean:                        ## remove build outputs
	rm -rf dist

distclean: clean              ## also drop the container image
	-$${ENGINE:-podman} rmi ableton-wine-build:22.04
