test: deps
	@echo Testing...
ifdef FILE
	nvim --headless --noplugin -u ./assets/minimal.lua -c "lua MiniTest.run_file('$(FILE)')"
else
	nvim --headless --noplugin -u ./assets/minimal.lua -c "lua MiniTest.run()"
endif

deps: deps/mini.nvim
	@echo Pulling...

deps/mini.nvim:
	@mkdir -p deps
	git clone --filter=blob:none https://github.com/echasnovski/mini.nvim $@

# Documentation
DOCS_MD := $(wildcard docs/*.md docs/*/*.md)

doc/sia.md: $(DOCS_MD) scripts/build-doc.sh
	@bash scripts/build-doc.sh

doc/sia.txt: doc/sia.md
	@TMPDIR=$$(mktemp -d) && \
	git clone --quiet --depth 1 https://github.com/kdheepak/panvimdoc.git "$$TMPDIR/panvimdoc" && \
	"$$TMPDIR/panvimdoc/panvimdoc.sh" \
		--project-name sia \
		--input-file doc/sia.md \
		--vim-version "Neovim >= 0.11" \
		--toc true \
		--treesitter true \
		--dedup-subheadings true \
		--ignore-rawblocks true && \
	rm -rf "$$TMPDIR"
	@echo "Generated doc/sia.txt"

doc: doc/sia.txt

.PHONY: test doc
