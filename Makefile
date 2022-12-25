VIMDIR = $(HOME)/.vim
XDG_CONFIG_HOME ?= $(HOME)/.config
NEOVIMDIR = $(XDG_CONFIG_HOME)/nvim

default: install

install:
	@echo 'Run make install-vim or make install-neovim'

uninstall:
	@echo 'Run make uninstall-vim or make uninstall-neovim'

install-vim:
	mkdir -p $(VIMDIR)/doc
	mkdir -p $(VIMDIR)/syntax
	mkdir -p $(VIMDIR)/plugin
	cp -f doc/filemanager.txt $(VIMDIR)/doc
	cp -f syntax/filemanager.vim $(VIMDIR)/syntax
	cp -f plugin/filemanager.vim $(VIMDIR)/plugin
	vim --cmd 'helptags $(VIMDIR)/doc' --cmd 'quit'

install-neovim:
	mkdir -p $(NEOVIMDIR)/doc
	mkdir -p $(NEOVIMDIR)/syntax
	mkdir -p $(NEOVIMDIR)/plugin
	cp -f doc/filemanager.txt $(NEOVIMDIR)/doc
	cp -f syntax/filemanager.vim $(NEOVIMDIR)/syntax
	cp -f plugin/filemanager.vim $(NEOVIMDIR)/plugin
	nvim --cmd 'helptags $(NEOVIMDIR)/doc' --cmd 'quit'

uninstall-vim:
	rm -f $(VIMDIR)/doc/filemanager.txt
	rm -f $(VIMDIR)/syntax/filemanager.vim
	rm -f $(VIMDIR)/plugin/filemanager.vim

uninstall-neovim:
	rm -f $(NEOVIMDIR)/doc/filemanager.txt
	rm -f $(NEOVIMDIR)/syntax/filemanager.vim
	rm -f $(NEOVIMDIR)/plugin/filemanager.vim

vim-install: install-vim

neovim-install: install-neovim

nvim-install: install-neovim

install-nvim: install-neovim

vim-uninstall: uninstall-vim

neovim-uninstall: uninstall-neovim

nvim-uninstall: uninstall-neovim

uninstall-nvim: uninstall-neovim

.PHONY: default install install-vim vim-install uninstall uninstall-vim vim-uninstall

.PHONY: install-neovim install-nvim neovim-install nvim-install

.PHONY: uninstall-neovim uninstall-nvim neovim-uninstall nvim-uninstall
