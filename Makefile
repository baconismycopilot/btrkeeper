BIN        := btrkeeper
PREFIX     := $(HOME)/.local
SYSPREFIX  := /usr/local
HOOKDIR    := /etc/boot/hooks/post.d
UNITDIR    := /etc/systemd/system
HOOKS      := 95-esp-backup 96-esp2-sync
UNITS      := btrkeeper-scrub btrkeeper-boot-audit

.DEFAULT_GOAL := help

.PHONY: help
help:
	@echo "Usage: $(MAKE) <install | check | hooks | timers | audit>"
	@echo ""
	@echo "  install          install $(BIN) to $(PREFIX)/bin"
	@echo "  install-system   install to $(SYSPREFIX)/bin, where the units expect it"
	@echo "  uninstall        remove both copies"
	@echo ""
	@echo "  test             run the smoke suite against a mocked sudo"
	@echo "  lint             parse-check the script, the hooks and the units"
	@echo "  check            lint, then test -- run this before committing"
	@echo ""
	@echo "  hooks            install the ESP backup and mirror-sync boot hooks"
	@echo "  timers           install and enable the scrub and audit timers"
	@echo "  timers-status    when each timer next fires"
	@echo "  logs             follow the timers' journal"
	@echo ""
	@echo "  status           filesystem layout, usage and error counters"
	@echo "  audit            check every member disk can still boot"

# --- installing --------------------------------------------------------
# Two locations on purpose. The everyday copy lives in $(PREFIX)/bin, but the
# systemd units run as root and must not execute a binary out of a home
# directory: anything able to write there would be running as root.

.PHONY: install
install:
	install -Dm755 $(BIN) $(PREFIX)/bin/$(BIN)
	@echo "installed $(PREFIX)/bin/$(BIN)"

.PHONY: install-system
install-system:
	sudo install -Dm755 $(BIN) $(SYSPREFIX)/bin/$(BIN)
	@echo "installed $(SYSPREFIX)/bin/$(BIN)"

.PHONY: uninstall
uninstall:
	rm -f $(PREFIX)/bin/$(BIN)
	sudo rm -f $(SYSPREFIX)/bin/$(BIN)

# --- checks ------------------------------------------------------------
# zsh -n only parses. It cannot see a call to a function that no longer
# exists, which is exactly how the SMART colouriser went missing once -- so
# `check` is lint *and* test, and test actually runs every command.

.PHONY: lint
lint:
	@zsh -n $(BIN) && echo "ok    $(BIN) parses"
	@for h in $(HOOKS); do bash -n contrib/$$h && echo "ok    contrib/$$h parses"; done
	@systemd-analyze verify contrib/systemd/*.service contrib/systemd/*.timer \
	    && echo "ok    systemd units verify"
	@command -v shellcheck >/dev/null 2>&1 \
	    && shellcheck -S warning contrib/$(firstword $(HOOKS)) contrib/96-esp2-sync \
	    || echo "skip  shellcheck not installed"

.PHONY: test
test:
	@./tests/smoke.sh

.PHONY: check
check: lint test

# --- system integration ------------------------------------------------
# These touch the running system, so each one is a deliberate target rather
# than something `install` does behind your back.

.PHONY: hooks
hooks:
	@for h in $(HOOKS); do sudo install -Dm755 contrib/$$h $(HOOKDIR)/$$h; done
	@echo "installed: $(HOOKS)"
	@echo "run them once now with: sudo $(HOOKDIR)/95-esp-backup"

.PHONY: timers
timers: install-system
	sudo install -Dm644 contrib/systemd/*.service contrib/systemd/*.timer $(UNITDIR)/
	sudo systemctl daemon-reload
	sudo systemctl enable --now $(addsuffix .timer,$(UNITS))
	@$(MAKE) --no-print-directory timers-status

.PHONY: timers-status
timers-status:
	@systemctl list-timers 'btrkeeper*' --no-pager

.PHONY: logs
logs:
	journalctl -u btrkeeper-scrub.service -u btrkeeper-boot-audit.service -f

# --- operating ---------------------------------------------------------

.PHONY: status
status:
	@$(PREFIX)/bin/$(BIN) status

# Run as root so it compares ESP contents rather than only their sizes.
.PHONY: audit
audit:
	@sudo $(PREFIX)/bin/$(BIN) boot
