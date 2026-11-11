EMACS ?= emacs
# Handle the mess when inside Emacs.
unexport INSIDE_EMACS
ifeq ($(EMACS), t)
EMACS = emacs
endif

emacs = $(EMACS)

CARGO ?= cargo
rust_sources = $(shell find server-rs/src -name '*.rs')
server_target = server-rs/target/release/epdfinfo
server_bin = server-rs/epdfinfo

.PHONY: all build bytecompile byteclean clean distclean

all: build

# Build the Rust epdfinfo server and place it next to its sources, where
# `pdf-info-epdfinfo-program' looks when running from the git repo.
build: $(server_bin)

$(server_bin): server-rs/Cargo.toml server-rs/Cargo.lock server-rs/build.rs \
		$(wildcard server-rs/synctex/*) $(rust_sources)
	$(CARGO) build --release --manifest-path server-rs/Cargo.toml
	cp $(server_target) $@

# Compile the Lisp sources.  Dependencies such as `tablist' must be
# installed in the Emacs package directory.
bytecompile:
	$(emacs) --batch -L lisp -f batch-byte-compile lisp/*.el

# Clean bytecompiled sources
byteclean:
	rm -f -- lisp/*.elc
	rm -f -- lisp/*.eln

# Various clean targets
clean: byteclean
	rm -f -- $(server_bin)

distclean: clean
	$(CARGO) clean --manifest-path server-rs/Cargo.toml
