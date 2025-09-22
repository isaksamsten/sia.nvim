test: deps
	@echo Testing...
	nvim --headless --noplugin -u ./assets/minimal.lua -c "lua MiniTest.run()"

deps: deps/mini.nvim
	@echo Pulling...

deps/mini.nvim:
	@mkdir -p deps
	git clone --filter=blob:none https://github.com/echasnovski/mini.nvim $@
