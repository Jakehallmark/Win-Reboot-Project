.PHONY: help check deps fetch trim grub reboot clean clean-all interactive status test

help:
	@echo "Win-Reboot-Project - Make targets"
	@echo ""
	@echo "  make status      - Show project status"
	@echo "  make check       - Check dependencies"
	@echo "  make fetch       - Download Windows 11 ISO"
	@echo "  make trim        - Apply Tiny11 trimming (requires ISO)"
	@echo "  make grub        - Add GRUB entry (requires sudo)"
	@echo "  make reboot      - Reboot to installer (requires sudo)"
	@echo "  make interactive - Run full interactive setup"
	@echo "  make test        - Run test suite"
	@echo "  make clean       - Clean tmp/ directory"
	@echo "  make clean-all   - Remove everything (tmp/, out/, GRUB)"
	@echo ""
	@echo "Quick flow: make check && make fetch && make trim && sudo make grub"

status:
	@./scripts/status.sh

test:
	@./scripts/test.sh

check:
	@./scripts/check_deps.sh

deps: check

fetch:
	@./scripts/fetch_iso.sh

trim:
	@if [ ! -f out/win11.iso ]; then \
		echo "[!] Error: out/win11.iso not found. Run 'make fetch' first."; \
		exit 1; \
	fi
	@./scripts/tiny11.sh out/win11.iso --preset minimal

grub:
	@if [ ! -f out/win11.iso ] && [ ! -f out/win11-tiny.iso ]; then \
		echo "[!] Error: No ISO found in out/. Run 'make fetch' first."; \
		exit 1; \
	fi
	@if [ -f out/win11-tiny.iso ]; then \
		./scripts/grub_entry.sh out/win11-tiny.iso; \
	else \
		./scripts/grub_entry.sh out/win11.iso; \
	fi

reboot:
	@./scripts/reboot_to_installer.sh

interactive:
	@./scripts/interactive_setup.sh

clean:
	@./scripts/cleanup.sh

clean-all:
	@sudo ./scripts/cleanup.sh --all
