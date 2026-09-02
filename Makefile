PROJECT = Aipicam.xcodeproj
SCHEME  = Aipicam

.PHONY: generate open build clean

generate:
	xcodegen generate

open: generate
	open $(PROJECT)

# Builds for the simulator with code signing disabled -- enough to catch
# compile errors without needing a real signing identity/provisioning
# profile. Pick a real device destination + signing team in Xcode to run
# on hardware (required for CoreBluetooth against real peripherals; the
# Simulator has no Bluetooth radio).
build: generate
	xcodebuild -project $(PROJECT) -scheme $(SCHEME) \
		-destination 'generic/platform=iOS Simulator' \
		CODE_SIGNING_ALLOWED=NO build

clean:
	rm -rf $(PROJECT) .build DerivedData
