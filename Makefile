.PHONY: build run test install uninstall clean release reset-accessibility restart

build:
	swift build

run: build
	.build/debug/zwm-server

test:
	./run-tests.sh

release:
	./build-release.sh

reset-accessibility:
	tccutil reset Accessibility com.zwm.app || true
	@echo "Reset Accessibility grant for ZWM. You will be re-prompted on next launch."

install: release reset-accessibility
	cp -r .release/ZWM.app /Applications/
	sudo cp .release/zwm /usr/local/bin/
	@if [ ! -f ~/.zwm.toml ] && [ ! -f ~/.config/zwm/zwm.toml ]; then \
		cp resources/default-config.toml ~/.zwm.toml; \
		echo "Installed default config to ~/.zwm.toml"; \
	fi
	@echo "Installed."

restart: install
	@pkill -x zwm-server 2>/dev/null; sleep 0.5; open /Applications/ZWM.app
	@echo "ZWM restarted."

uninstall:
	rm -rf /Applications/ZWM.app
	sudo rm -f /usr/local/bin/zwm
	@echo "Uninstalled. Config files (~/.zwm.toml) left in place."

clean:
	swift package clean
	rm -rf .release
