EMACS ?= emacs
# Handle the mess when inside Emacs.
unexport INSIDE_EMACS
ifeq ($(EMACS), t)
EMACS = emacs
endif

emacs = $(EMACS)

CARGO ?= cargo

.PHONY: all build bytecompile byteclean clean distclean

all: build

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

distclean: clean
