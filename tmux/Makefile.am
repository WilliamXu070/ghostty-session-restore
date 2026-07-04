# Obvious program stuff.
bin_PROGRAMS = tmux
CLEANFILES = tmux.1.mdoc tmux.1.man commands/cmd-parse.c

# Distribution tarball options.
EXTRA_DIST = \
	CHANGES README README.ja COPYING example_tmux.conf \
	platform/osdep-*.c mdoc2man.awk tmux.1
dist_EXTRA_tmux_SOURCES = compat/*.[ch]

# Preprocessor flags.
AM_CPPFLAGS += @XOPEN_DEFINES@ \
	-DTMUX_VERSION='"@VERSION@"' \
	-DTMUX_CONF='"$(sysconfdir)/tmux.conf:~/.tmux.conf:$$XDG_CONFIG_HOME/tmux/tmux.conf:~/.config/tmux/tmux.conf"' \
	-DTMUX_LOCK_CMD='"@DEFAULT_LOCK_CMD@"' \
	-DTMUX_TERM='"@DEFAULT_TERM@"'

# Additional object files.
LDADD = $(LIBOBJS)

# Set flags for gcc.
if IS_GCC
AM_CFLAGS += -std=gnu99
if IS_OPTIMIZED
AM_CFLAGS += -O2
else
AM_CFLAGS += -O0
endif
if IS_DEBUG
AM_CFLAGS += -g3 -ggdb
AM_CFLAGS += -Wno-long-long -Wall -W -Wformat=2 -Wno-use-after-free
AM_CFLAGS += -Wmissing-prototypes -Wstrict-prototypes -Wmissing-declarations
AM_CFLAGS += -Wwrite-strings -Wshadow -Wpointer-arith -Wsign-compare
AM_CFLAGS += -Wundef -Wbad-function-cast -Winline -Wno-cast-align
AM_CFLAGS += -Wdeclaration-after-statement -Wno-pointer-sign -Wno-attributes
AM_CFLAGS += -Wno-unused-result -Wno-format-y2k -Wno-unknown-warning-option
AM_CFLAGS += -Wno-maybe-uninitialized
if IS_DARWIN
AM_CFLAGS += -Wno-deprecated-declarations -Wno-macro-redefined
endif
AM_CPPFLAGS += -DDEBUG
endif
AM_CPPFLAGS += -iquote.
if IS_ASAN
AM_CFLAGS += -fsanitize=address
AM_LDFLAGS += -fsanitize=address
endif
endif

# Set flags for Solaris.
if IS_SUNOS
if IS_GCC
AM_CPPFLAGS += -D_XPG6
else
AM_CPPFLAGS += -D_XPG4_2
endif
endif

# Set flags for Sun CC.
if IS_SUNCC
AM_CFLAGS += -erroff=E_EMPTY_DECLARATION
endif

# Set _LINUX_SOURCE_COMPAT for AIX for malloc(0).
if IS_AIX
AM_CPPFLAGS += -D_LINUX_SOURCE_COMPAT=1
endif

# Set flags for NetBSD.
if IS_NETBSD
AM_CPPFLAGS += -D_OPENBSD_SOURCE
endif

# Set flags for Haiku.
if IS_HAIKU
AM_CPPFLAGS += -D_BSD_SOURCE
endif

# Set flags for Cygwin.
if IS_CYGWIN
AM_CPPFLAGS += -DTMUX_SOCK_PERM=0
endif

# List of sources.
dist_tmux_SOURCES = \
	commands/cmd-attach-session.c \
	commands/cmd-bind-key.c \
	commands/cmd-break-pane.c \
	commands/cmd-capture-pane.c \
	commands/cmd-choose-tree.c \
	commands/cmd-command-prompt.c \
	commands/cmd-confirm-before.c \
	commands/cmd-copy-mode.c \
	commands/cmd-detach-client.c \
	commands/cmd-display-menu.c \
	commands/cmd-display-message.c \
	commands/cmd-display-panes.c \
	commands/cmd-find-window.c \
	commands/cmd-find.c \
	commands/cmd-if-shell.c \
	commands/cmd-join-pane.c \
	commands/cmd-kill-pane.c \
	commands/cmd-kill-server.c \
	commands/cmd-kill-session.c \
	commands/cmd-kill-window.c \
	commands/cmd-list-buffers.c \
	commands/cmd-list-clients.c \
	commands/cmd-list-commands.c \
	commands/cmd-list-keys.c \
	commands/cmd-list-panes.c \
	commands/cmd-list-sessions.c \
	commands/cmd-list-windows.c \
	commands/cmd-load-buffer.c \
	commands/cmd-lock-server.c \
	commands/cmd-move-window.c \
	commands/cmd-new-session.c \
	commands/cmd-newmux-recovery.c \
	commands/cmd-new-window.c \
	commands/cmd-parse.y \
	commands/cmd-paste-buffer.c \
	commands/cmd-pipe-pane.c \
	commands/cmd-queue.c \
	commands/cmd-refresh-client.c \
	commands/cmd-rename-session.c \
	commands/cmd-rename-window.c \
	commands/cmd-resize-pane.c \
	commands/cmd-resize-window.c \
	commands/cmd-respawn-pane.c \
	commands/cmd-respawn-window.c \
	commands/cmd-rotate-window.c \
	commands/cmd-run-shell.c \
	commands/cmd-save-buffer.c \
	commands/cmd-select-layout.c \
	commands/cmd-select-pane.c \
	commands/cmd-select-window.c \
	commands/cmd-send-keys.c \
	commands/cmd-server-access.c \
	commands/cmd-set-buffer.c \
	commands/cmd-set-environment.c \
	commands/cmd-set-option.c \
	commands/cmd-show-environment.c \
	commands/cmd-show-messages.c \
	commands/cmd-show-options.c \
	commands/cmd-show-prompt-history.c \
	commands/cmd-source-file.c \
	commands/cmd-split-window.c \
	commands/cmd-swap-pane.c \
	commands/cmd-swap-window.c \
	commands/cmd-switch-client.c \
	commands/cmd-unbind-key.c \
	commands/cmd-wait-for.c \
	commands/cmd.c \
	compat.h \
	core/arguments.c \
	core/attributes.c \
	core/cfg.c \
	core/file.c \
	core/job.c \
	core/log.c \
	core/regsub.c \
	core/sort.c \
	core/tmux.c \
	core/xmalloc.c \
	options/environ.c \
	options/options-table.c \
	options/options.c \
	screen/format-draw.c \
	screen/format.c \
	screen/grid-reader.c \
	screen/grid-view.c \
	screen/grid.c \
	screen/screen-redraw.c \
	screen/screen-write.c \
	screen/screen.c \
	server/client.c \
	server/control-notify.c \
	server/control.c \
	server/proc.c \
	server/server-acl.c \
	server/server-client.c \
	server/server-fn.c \
	server/server.c \
	terminal/colour.c \
	terminal/hyperlinks.c \
	terminal/input-keys.c \
	terminal/input.c \
	terminal/key-bindings.c \
	terminal/key-string.c \
	terminal/style.c \
	terminal/tty-acs.c \
	terminal/tty-draw.c \
	terminal/tty-features.c \
	terminal/tty-keys.c \
	terminal/tty-term.c \
	terminal/tty.c \
	terminal/utf8-combined.c \
	terminal/utf8.c \
	ui/menu.c \
	ui/mode-tree.c \
	ui/paste.c \
	ui/popup.c \
	ui/status.c \
	tmux.h \
	tmux-protocol.h \
	windows/alerts.c \
	windows/layout-custom.c \
	windows/layout-set.c \
	windows/layout.c \
	windows/names.c \
	windows/notify.c \
	windows/resize.c \
	windows/session.c \
	windows/spawn.c \
	windows/window-buffer.c \
	windows/window-client.c \
	windows/window-clock.c \
	windows/window-copy.c \
	windows/window-customize.c \
	windows/window-tree.c \
	windows/window.c \
	xmalloc.h
nodist_tmux_SOURCES = platform/osdep-@PLATFORM@.c

# Add compat file for forkpty.
if NEED_FORKPTY
nodist_tmux_SOURCES += compat/forkpty-@PLATFORM@.c
endif

# Add compat file for systemd.
if HAVE_SYSTEMD
nodist_tmux_SOURCES += compat/systemd.c
endif

# Add compat file for utf8proc.
if HAVE_UTF8PROC
nodist_tmux_SOURCES += compat/utf8proc.c
endif

# Enable sixel support.
if ENABLE_SIXEL
dist_tmux_SOURCES += terminal/image.c terminal/image-sixel.c
endif

# Add bits for fuzzing if enabled.
if NEED_FUZZING
check_PROGRAMS = \
	fuzz/input-fuzzer \
	fuzz/cmd-parse-fuzzer \
	fuzz/format-fuzzer \
	fuzz/style-fuzzer
fuzz_input_fuzzer_LDFLAGS = $(FUZZING_LIBS)
fuzz_input_fuzzer_LDADD = $(LDADD) $(tmux_OBJECTS)
fuzz_cmd_parse_fuzzer_LDFLAGS = $(FUZZING_LIBS)
fuzz_cmd_parse_fuzzer_LDADD = $(LDADD) $(tmux_OBJECTS)
fuzz_format_fuzzer_LDFLAGS = $(FUZZING_LIBS)
fuzz_format_fuzzer_LDADD = $(LDADD) $(tmux_OBJECTS)
fuzz_style_fuzzer_LDFLAGS = $(FUZZING_LIBS)
fuzz_style_fuzzer_LDADD = $(LDADD) $(tmux_OBJECTS)
endif

# Install tmux.1 in the right format.
install-exec-hook:
	if test x@MANFORMAT@ = xmdoc; then \
		sed -e "s|@SYSCONFDIR@|$(sysconfdir)|g" $(srcdir)/tmux.1 \
			>$(srcdir)/tmux.1.mdoc; \
	else \
		sed -e "s|@SYSCONFDIR@|$(sysconfdir)|g" $(srcdir)/tmux.1| \
			$(AWK) -f $(srcdir)/mdoc2man.awk >$(srcdir)/tmux.1.man; \
	fi
	$(mkdir_p) $(DESTDIR)$(mandir)/man1
	$(INSTALL_DATA) $(srcdir)/tmux.1.@MANFORMAT@ \
		$(DESTDIR)$(mandir)/man1/tmux.1

# And uninstall it.
uninstall-hook:
	rm -f $(DESTDIR)$(mandir)/man1/tmux.1
