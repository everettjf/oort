# openorb — common tasks
.PHONY: build gui guest fmt lint verify verify-fast clean

# Build the host engine (release) and codesign with the virtualization entitlement.
build:
	swift build -c release
	codesign --force --sign - --entitlements openorb.entitlements \
		"$$(swift build -c release --show-bin-path)/openorb"

# Build the native menu-bar GUI.
gui:
	swift build -c release

# Cross-compile the guest agent for linux/arm64.
guest:
	cd guest-agent && GOOS=linux GOARCH=arm64 CGO_ENABLED=0 go build -ldflags="-s -w" -o ../share/openorb-guest .

# Static checks that don't need a VM (CI-friendly): builds + shellcheck + go vet.
lint:
	swift build -c release >/dev/null
	cd guest-agent && go vet ./...
	@command -v shellcheck >/dev/null && shellcheck -S warning orb tests/e2e.sh make-image.sh || echo "shellcheck not installed; skipping"

# Full end-to-end suite on a real VM (needs an Apple-silicon host with VZ).
verify:
	./tests/e2e.sh

# e2e reusing the current disk (skip the slow build-image).
verify-fast:
	FRESH=0 ./tests/e2e.sh

clean:
	rm -rf .build
