.PHONY: test test-unit test-integration test-slow lint

# Full suite. Unit specs first: they are seconds, and if a config module is
# broken there is no point waiting on the integration specs to say so again.
test:
	tests/run.sh all

test-unit:
	tests/run.sh unit

test-integration:
	tests/run.sh integration

# Also runs the specs gated on real language servers (jdtls, ts_ls), which need
# mason packages installed and take minutes.
test-slow:
	NVIM_IDE_TEST_SLOW=1 tests/run.sh all

# Every Lua file must at least parse. Catches the class of mistake that makes
# nvim unusable at startup without needing a spec per file.
lint:
	@fail=0; \
	for f in $$(find . -name '*.lua' -not -path './.git/*'); do \
	  nvim --headless --clean -c "lua local ok, err = loadfile('$$f'); if not ok then io.stderr:write('$$f: '..err..'\n'); vim.cmd('1cq') end" -c 'qa!' || fail=1; \
	done; \
	[ $$fail -eq 0 ] && echo "all Lua files parse"
