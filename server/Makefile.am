bin_PROGRAMS = epdfinfo-c
epdfinfo_c_CFLAGS = -Wall $(glib_CFLAGS) $(poppler_glib_CFLAGS) $(poppler_CFLAGS) \
			$(png_CFLAGS)
# Need -lm to link libm.so.6
epdfinfo_c_LDADD =  $(glib_LIBS) $(poppler_glib_LIBS) $(poppler_LIBS) \
			$(png_LIBS) libsynctex.a $(zlib_LIBS) -lm
epdfinfo_c_SOURCES = epdfinfo.c epdfinfo.h

# The Rust rewrite is the default server: `make` builds it as `epdfinfo`, while the
# C implementation stays available as `epdfinfo-c`.
CARGO ?= cargo
RUST_DIR = $(top_srcdir)/../server-rs
RUST_BIN = $(RUST_DIR)/target/release/epdfinfo$(EXEEXT)

all-local: epdfinfo$(EXEEXT)

epdfinfo$(EXEEXT): FORCE
	cd $(RUST_DIR) && $(CARGO) build --release
	cp $(RUST_BIN) $@

.PHONY: FORCE
FORCE:

install-exec-hook:
	$(MKDIR_P) $(DESTDIR)$(bindir)
	$(INSTALL_PROGRAM) epdfinfo$(EXEEXT) $(DESTDIR)$(bindir)/epdfinfo$(EXEEXT)

uninstall-hook:
	rm -f $(DESTDIR)$(bindir)/epdfinfo$(EXEEXT)

clean-local:
	rm -f epdfinfo$(EXEEXT)

noinst_LIBRARIES = libsynctex.a
libsynctex_a_SOURCES = synctex_parser.c synctex_parser_utils.c synctex_parser.h	\
			synctex_parser_local.h synctex_parser_utils.h
libsynctex_a_CFLAGS = -w $(zlib_CFLAGS) -DSYNCTEX_USE_LOCAL_HEADER

if HAVE_W32
epdfinfo_c_LDADD += -lshlwapi
endif

SYNCTEX_UPSTREAM = svn://tug.org/texlive/trunk/Build/source/texk/web2c/synctexdir
SYNCTEX_FILES = synctex_parser.c		\
		synctex_parser.h		\
		synctex_parser_readme.txt	\
		synctex_parser_utils.c		\
		synctex_parser_utils.h		\
		synctex_parser_version.txt      \
		synctex_version.h		\
		synctex_parser_advanced.h


check-local:
	@if $(MAKE) --version 2>&1 | grep -q GNU; then \
		cd test && $(MAKE) $(AM_MAKEFLAGS); \
	else \
		echo "Skipping tests in server/test (requires GNU make)"; \
	fi

synctex-pull:
	@if [ -n "$$(git status --porcelain)" ]; then \
		git status; \
		echo "Not checking-out files into a dirty work-directory"; \
		false; \
	fi
	for file in $(SYNCTEX_FILES); do \
		svn export --force $(SYNCTEX_UPSTREAM)/$$file; \
	done
