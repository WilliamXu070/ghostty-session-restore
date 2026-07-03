/* $OpenBSD$ */

/*
 * Newmux live pane recovery.
 *
 * A soft-deleted pane is not killed. It is moved into an internal recovery
 * session and later moved back into its original window. This keeps the PTY,
 * child process, screen, scrollback, colours, alternate screen, and terminal
 * state alive.
 */

#include <sys/types.h>

#include <stdlib.h>
#include <string.h>

#include "tmux.h"

#define NEWMUX_RECOVERY_MAX_ITEMS 32
#define NEWMUX_RECOVERY_SESSION "__newmux-recovery"

enum newmux_closed_type {
	NEWMUX_CLOSED_PANE,
	NEWMUX_CLOSED_WINDOW,
	NEWMUX_CLOSED_SESSION
};

struct newmux_closed_item {
	enum newmux_closed_type	 type;
	u_int			 sequence;
	struct timeval		 closed_at;

	u_int			 session_id;
	char			*session_name;
	u_int			 window_id;
	char			*window_name;
	int			 window_index;
	int			 window_position;
	int			 left_window_id;
	int			 right_window_id;
	char			*window_layout;
	u_int			 pane_id;
	u_int			 pane_index;
	u_int			 active_pane_index;

	u_int			 recovery_session_id;
	u_int			 recovery_window_id;

	TAILQ_ENTRY(newmux_closed_item) entry;
};
TAILQ_HEAD(newmux_closed_items, newmux_closed_item);

struct newmux_pane_history_snapshot {
	u_int			 pane_id;
	u_int			 hsize;
	struct grid		*grid;

	TAILQ_ENTRY(newmux_pane_history_snapshot) entry;
};
TAILQ_HEAD(newmux_pane_history_snapshots, newmux_pane_history_snapshot);

static struct newmux_closed_items newmux_closed_stack =
    TAILQ_HEAD_INITIALIZER(newmux_closed_stack);
static struct newmux_closed_items newmux_reserved_stack =
    TAILQ_HEAD_INITIALIZER(newmux_reserved_stack);
static u_int newmux_closed_next_sequence;
static u_int newmux_closed_count;

static enum cmd_retval	cmd_newmux_soft_delete_pane_exec(struct cmd *,
			    struct cmdq_item *);
static enum cmd_retval	cmd_newmux_soft_delete_window_exec(struct cmd *,
			    struct cmdq_item *);
static enum cmd_retval	cmd_newmux_soft_delete_session_exec(struct cmd *,
			    struct cmdq_item *);
static enum cmd_retval	cmd_newmux_create_window_exec(struct cmd *,
			    struct cmdq_item *);
static enum cmd_retval	cmd_newmux_delete_window_exec(struct cmd *,
			    struct cmdq_item *);
static enum cmd_retval	cmd_newmux_reopen_latest_closed_exec(struct cmd *,
			    struct cmdq_item *);
static enum cmd_retval	cmd_newmux_reserve_latest_closed_exec(struct cmd *,
			    struct cmdq_item *);
static enum cmd_retval	cmd_newmux_claim_reserved_closed_exec(struct cmd *,
			    struct cmdq_item *);
static enum cmd_retval	cmd_newmux_list_recently_closed_exec(struct cmd *,
			    struct cmdq_item *);
static enum cmd_retval	cmd_newmux_clear_recently_closed_exec(struct cmd *,
			    struct cmdq_item *);

const struct cmd_entry cmd_newmux_soft_delete_pane_entry = {
	.name = "newmux-soft-delete-pane",
	.alias = NULL,

	.args = { "t:", 0, 0, NULL },
	.usage = CMD_TARGET_PANE_USAGE,

	.target = { 't', CMD_FIND_PANE, 0 },

	.flags = 0,
	.exec = cmd_newmux_soft_delete_pane_exec
};

const struct cmd_entry cmd_newmux_soft_delete_window_entry = {
	.name = "newmux-soft-delete-window",
	.alias = NULL,

	.args = { "t:", 0, 0, NULL },
	.usage = CMD_TARGET_WINDOW_USAGE,

	.target = { 't', CMD_FIND_WINDOW, 0 },

	.flags = 0,
	.exec = cmd_newmux_soft_delete_window_exec
};

const struct cmd_entry cmd_newmux_soft_delete_session_entry = {
	.name = "newmux-soft-delete-session",
	.alias = NULL,

	.args = { "t:", 0, 0, NULL },
	.usage = CMD_TARGET_SESSION_USAGE,

	.target = { 't', CMD_FIND_SESSION, 0 },

	.flags = 0,
	.exec = cmd_newmux_soft_delete_session_exec
};

const struct cmd_entry cmd_newmux_create_window_entry = {
	.name = "newmux-create-window",
	.alias = NULL,

	.args = { "Ps:t:", 0, 0, NULL },
	.usage = "[-P] [-s primary-session] " CMD_TARGET_PANE_USAGE,

	.target = { 't', CMD_FIND_PANE, 0 },

	.flags = 0,
	.exec = cmd_newmux_create_window_exec
};

const struct cmd_entry cmd_newmux_delete_window_entry = {
	.name = "newmux-delete-window",
	.alias = NULL,

	.args = { "Ps:t:", 0, 0, NULL },
	.usage = "[-P] [-s primary-session] " CMD_TARGET_WINDOW_USAGE,

	.target = { 't', CMD_FIND_WINDOW, 0 },

	.flags = 0,
	.exec = cmd_newmux_delete_window_exec
};

const struct cmd_entry cmd_newmux_reopen_latest_closed_entry = {
	.name = "newmux-reopen-latest-closed",
	.alias = NULL,

	.args = { "Pt:", 0, 0, NULL },
	.usage = "[-P] " CMD_TARGET_WINDOW_USAGE,

	.target = { 't', CMD_FIND_WINDOW, CMD_FIND_CANFAIL },

	.flags = 0,
	.exec = cmd_newmux_reopen_latest_closed_exec
};

const struct cmd_entry cmd_newmux_reserve_latest_closed_entry = {
	.name = "newmux-reserve-latest-closed",
	.alias = NULL,

	.args = { "P", 0, 0, NULL },
	.usage = "[-P]",

	.flags = 0,
	.exec = cmd_newmux_reserve_latest_closed_exec
};

const struct cmd_entry cmd_newmux_claim_reserved_closed_entry = {
	.name = "newmux-claim-reserved-closed",
	.alias = NULL,

	.args = { "PS:t:", 0, 0, NULL },
	.usage = "[-P] -S sequence " CMD_TARGET_WINDOW_USAGE,

	.target = { 't', CMD_FIND_WINDOW, CMD_FIND_CANFAIL },

	.flags = 0,
	.exec = cmd_newmux_claim_reserved_closed_exec
};

const struct cmd_entry cmd_newmux_list_recently_closed_entry = {
	.name = "newmux-list-recently-closed",
	.alias = NULL,

	.args = { "", 0, 0, NULL },
	.usage = "",

	.flags = 0,
	.exec = cmd_newmux_list_recently_closed_exec
};

const struct cmd_entry cmd_newmux_clear_recently_closed_entry = {
	.name = "newmux-clear-recently-closed",
	.alias = NULL,

	.args = { "", 0, 0, NULL },
	.usage = "",

	.flags = 0,
	.exec = cmd_newmux_clear_recently_closed_exec
};

static const char *
newmux_closed_type_string(enum newmux_closed_type type)
{
	switch (type) {
	case NEWMUX_CLOSED_PANE:
		return ("pane");
	case NEWMUX_CLOSED_WINDOW:
		return ("window");
	case NEWMUX_CLOSED_SESSION:
		return ("session");
	}
	return ("unknown");
}

static struct session *
newmux_primary_session_from_args(struct cmdq_item *cmdq_item,
    struct args *args, struct session *fallback)
{
	const char	*name;
	struct session	*s;

	name = args_get(args, 's');
	if (name == NULL || *name == '\0')
		return (fallback);

	s = session_find(name);
	if (s == NULL)
		cmdq_error(cmdq_item, "newmux session missing: %s", name);
	return (s);
}

static u_int
newmux_window_position(struct session *s, struct window *w)
{
	struct winlink	*wl;
	u_int		 position = 0;

	RB_FOREACH(wl, winlinks, &s->windows) {
		if (wl->window == w)
			return (position);
		position++;
	}
	return (position);
}

static struct winlink *
newmux_winlink_at_position(struct session *s, u_int position)
{
	struct winlink	*wl;
	u_int		 current = 0;

	RB_FOREACH(wl, winlinks, &s->windows) {
		if (current == position)
			return (wl);
		current++;
	}
	return (NULL);
}

static void
newmux_item_set_window_order(struct newmux_closed_item *item,
    struct session *s, struct winlink *wl)
{
	struct winlink	*left, *right;

	item->window_position = (int)newmux_window_position(s, wl->window);
	left = RB_PREV(winlinks, &s->windows, wl);
	right = RB_NEXT(winlinks, &s->windows, wl);
	item->left_window_id = left != NULL ? (int)left->window->id : -1;
	item->right_window_id = right != NULL ? (int)right->window->id : -1;
}

static char *
newmux_window_order_string(struct newmux_closed_item *item)
{
	char	*left, *right, *result;

	if (item->left_window_id >= 0)
		xasprintf(&left, "@%u", (u_int)item->left_window_id);
	else
		left = xstrdup("none");
	if (item->right_window_id >= 0)
		xasprintf(&right, "@%u", (u_int)item->right_window_id);
	else
		right = xstrdup("none");
	xasprintf(&result, "target_position=%d left_window_id=%s "
	    "right_window_id=%s", item->window_position, left, right);
	free(left);
	free(right);
	return (result);
}

static void
newmux_print_window_result(struct cmdq_item *cmdq_item, const char *action,
    struct session *s, struct winlink *wl, struct window *w,
    const char *extra)
{
	int	window_index = -1;
	u_int	target_index = 0;

	if (wl != NULL)
		window_index = wl->idx;
	if (s != NULL && w != NULL)
		target_index = newmux_window_position(s, w);

	cmdq_print(cmdq_item,
	    "ok=1 action=%s kind=window window=@%u window_id=@%u "
	    "window_index=%d target_index=%u%s%s",
	    action, w != NULL ? w->id : 0, w != NULL ? w->id : 0,
	    window_index, target_index, extra != NULL ? " " : "",
	    extra != NULL ? extra : "");
}

static char *
newmux_dump_window_layout(struct window *w)
{
	if (w->saved_layout_root != NULL)
		return (layout_dump(w, w->saved_layout_root));
	return (layout_dump(w, w->layout_root));
}

static int
newmux_grid_line_equal(struct grid *gd1, u_int py1, struct grid *gd2, u_int py2)
{
	const struct grid_line	*gl1, *gl2;
	struct grid_cell	 gc1, gc2;
	u_int			 xx, sx;

	gl1 = grid_peek_line(gd1, py1);
	gl2 = grid_peek_line(gd2, py2);
	if (gl1 == NULL || gl2 == NULL)
		return (0);
	if (gl1->cellused != gl2->cellused || gl1->flags != gl2->flags)
		return (0);

	sx = gd1->sx;
	if (gd2->sx > sx)
		sx = gd2->sx;
	for (xx = 0; xx < sx; xx++) {
		grid_get_cell(gd1, xx, py1, &gc1);
		grid_get_cell(gd2, xx, py2, &gc2);
		if (!grid_cells_equal(&gc1, &gc2))
			return (0);
	}
	return (1);
}

static int
newmux_alternate_saved_grid_in_history(struct screen *s)
{
	struct grid	*gd = s->grid, *saved = s->saved_grid;
	u_int		 yy, start;

	if (saved == NULL || saved->sy == 0 || gd->hsize < saved->sy)
		return (0);

	start = gd->hsize - saved->sy;
	for (yy = 0; yy < saved->sy; yy++) {
		if (!newmux_grid_line_equal(gd, start + yy, saved, yy))
			return (0);
	}
	return (1);
}

static int
newmux_visible_grid_in_history(struct screen *s)
{
	struct grid	*gd = s->grid;
	u_int		 yy, start;

	if (gd->sy == 0 || gd->hsize < gd->sy)
		return (0);

	start = gd->hsize - gd->sy;
	for (yy = 0; yy < gd->sy; yy++) {
		if (!newmux_grid_line_equal(gd, start + yy, gd,
		    gd->hsize + yy))
			return (0);
	}
	return (1);
}

static void
newmux_grid_insert_history_line(struct grid *gd, struct grid *src, u_int src_y)
{
	struct grid_line	*old_linedata, *new_linedata;
	u_int			 old_total, hscrolled;

	old_total = gd->hsize + gd->sy;
	hscrolled = gd->hscrolled;
	old_linedata = gd->linedata;
	new_linedata = xcalloc(old_total + 1, sizeof *new_linedata);

	memcpy(new_linedata, old_linedata, gd->hsize * sizeof *new_linedata);
	memcpy(&new_linedata[gd->hsize + 1], &old_linedata[gd->hsize],
	    gd->sy * sizeof *new_linedata);
	free(old_linedata);

	gd->linedata = new_linedata;
	gd->hsize++;
	gd->hscrolled = hscrolled;
	grid_duplicate_lines(gd, gd->hsize - 1, src, src_y, 1);
}

static void
newmux_preserve_visible_grid(struct window_pane *wp)
{
	struct screen	*s = &wp->base;
	struct grid	*gd = s->grid, *snapshot;
	u_int		 yy;

	if (gd->sy == 0 || newmux_visible_grid_in_history(s))
		return;

	snapshot = grid_create(gd->sx, gd->sy, 0);
	grid_duplicate_lines(snapshot, 0, gd, gd->hsize, gd->sy);
	for (yy = 0; yy < snapshot->sy; yy++)
		newmux_grid_insert_history_line(gd, snapshot, yy);
	grid_destroy(snapshot);
	grid_collect_history(gd, 1);
}

static void
newmux_preserve_alternate_saved_grid(struct window_pane *wp)
{
	struct screen	*s = &wp->base;
	struct grid	*saved = s->saved_grid;
	u_int		 yy;

	if (saved == NULL || newmux_alternate_saved_grid_in_history(s))
		return;

	for (yy = 0; yy < saved->sy; yy++)
		newmux_grid_insert_history_line(s->grid, saved, yy);
	grid_collect_history(s->grid, 1);
}

static void
newmux_preserve_pane_history(struct window_pane *wp)
{
	newmux_preserve_visible_grid(wp);
	newmux_preserve_alternate_saved_grid(wp);
}

static void
newmux_protect_pane_history_on_next_clear(struct window_pane *wp)
{
	wp->flags |= PANE_NEWMUX_HISTORY_PROTECTED;
}

static void
newmux_protect_window_history_on_next_clear(struct window *w)
{
	struct window_pane	*wp;

	TAILQ_FOREACH(wp, &w->panes, entry)
		newmux_protect_pane_history_on_next_clear(wp);
}

static void
newmux_history_snapshots_take(struct window *w,
    struct newmux_pane_history_snapshots *snapshots)
{
	struct newmux_pane_history_snapshot	*snapshot;
	struct window_pane			*wp;
	struct grid				*gd;

	TAILQ_INIT(snapshots);
	TAILQ_FOREACH(wp, &w->panes, entry) {
		gd = wp->base.grid;
		if (gd->hsize == 0)
			continue;

		snapshot = xcalloc(1, sizeof *snapshot);
		snapshot->pane_id = wp->id;
		snapshot->hsize = gd->hsize;
		snapshot->grid = grid_create(gd->sx, gd->hsize, 0);
		grid_duplicate_lines(snapshot->grid, 0, gd, 0, gd->hsize);
		TAILQ_INSERT_TAIL(snapshots, snapshot, entry);
	}
}

static int
newmux_grid_history_matches_snapshot(struct grid *gd, struct grid *snapshot)
{
	u_int	yy;

	if (snapshot->hsize == 0)
		return (gd->hsize == 0);
	if (gd->hsize != snapshot->hsize)
		return (0);
	for (yy = 0; yy < snapshot->hsize; yy++) {
		if (!newmux_grid_line_equal(gd, yy, snapshot, yy))
			return (0);
	}
	return (1);
}

static void
newmux_history_snapshots_free(struct newmux_pane_history_snapshots *snapshots)
{
	struct newmux_pane_history_snapshot	*snapshot;

	while ((snapshot = TAILQ_FIRST(snapshots)) != NULL) {
		TAILQ_REMOVE(snapshots, snapshot, entry);
		grid_destroy(snapshot->grid);
		free(snapshot);
	}
}

static void
newmux_history_snapshots_restore_if_shrunk(
    struct newmux_pane_history_snapshots *snapshots)
{
	struct newmux_pane_history_snapshot	*snapshot;
	struct window_pane			*wp;
	struct grid				*gd;
	u_int					 yy;

	while ((snapshot = TAILQ_FIRST(snapshots)) != NULL) {
		TAILQ_REMOVE(snapshots, snapshot, entry);
		wp = window_pane_find_by_id(snapshot->pane_id);
		if (wp != NULL) {
			gd = wp->base.grid;
			if (!newmux_grid_history_matches_snapshot(gd, snapshot->grid)) {
				grid_clear_history(gd);
				for (yy = 0; yy < snapshot->hsize; yy++)
					newmux_grid_insert_history_line(gd,
					    snapshot->grid, yy);
				grid_collect_history(gd, 1);
			}
		}
		grid_destroy(snapshot->grid);
		free(snapshot);
	}
}

static void
newmux_free_item(struct newmux_closed_item *item)
{
	free(item->session_name);
	free(item->window_name);
	free(item->window_layout);
	free(item);
}

static void
newmux_stack_clear(void)
{
	struct newmux_closed_item	*item;

	while ((item = TAILQ_FIRST(&newmux_closed_stack)) != NULL) {
		TAILQ_REMOVE(&newmux_closed_stack, item, entry);
		newmux_free_item(item);
	}
	while ((item = TAILQ_FIRST(&newmux_reserved_stack)) != NULL) {
		TAILQ_REMOVE(&newmux_reserved_stack, item, entry);
		newmux_free_item(item);
	}
	newmux_closed_count = 0;
	newmux_closed_next_sequence = 0;
}

static void
newmux_recovery_clear(void)
{
	struct session	*s;

	s = session_find(NEWMUX_RECOVERY_SESSION);
	if (s != NULL) {
		server_destroy_session(s);
		session_destroy(s, 1, __func__);
	}
	newmux_stack_clear();
	recalculate_sizes();
}

static void
newmux_stack_push(struct newmux_closed_item *item)
{
	struct newmux_closed_item	*old;

	TAILQ_INSERT_HEAD(&newmux_closed_stack, item, entry);
	newmux_closed_count++;
	while (newmux_closed_count > NEWMUX_RECOVERY_MAX_ITEMS) {
		old = TAILQ_LAST(&newmux_closed_stack, newmux_closed_items);
		TAILQ_REMOVE(&newmux_closed_stack, old, entry);
		newmux_closed_count--;
		newmux_free_item(old);
	}
}

static struct newmux_closed_item *
newmux_stack_pop(void)
{
	struct newmux_closed_item	*item;

	item = TAILQ_FIRST(&newmux_closed_stack);
	if (item == NULL)
		return (NULL);
	TAILQ_REMOVE(&newmux_closed_stack, item, entry);
	newmux_closed_count--;
	return (item);
}

static void
newmux_reserved_push(struct newmux_closed_item *item)
{
	TAILQ_INSERT_TAIL(&newmux_reserved_stack, item, entry);
}

static struct newmux_closed_item *
newmux_reserved_pop_by_sequence(u_int sequence)
{
	struct newmux_closed_item	*item;

	TAILQ_FOREACH(item, &newmux_reserved_stack, entry) {
		if (item->sequence == sequence) {
			TAILQ_REMOVE(&newmux_reserved_stack, item, entry);
			return (item);
		}
	}
	return (NULL);
}

static int
newmux_session_detach_silent(struct session *s, struct winlink *wl)
{
	struct winlink	*next;

	if (s->curw == wl) {
		next = RB_NEXT(winlinks, &s->windows, wl);
		if (next == NULL)
			next = RB_PREV(winlinks, &s->windows, wl);
		if (next != NULL)
			session_set_current(s, next);
		else
			s->curw = NULL;
	}

	wl->flags &= ~WINLINK_ALERTFLAGS;
	winlink_stack_remove(&s->lastw, wl);
	winlink_remove(&s->windows, wl);
	session_group_synchronize_from(s);

	return (RB_EMPTY(&s->windows));
}

static struct winlink *
newmux_session_attach_silent(struct session *s, struct window *w, int idx,
    char **cause)
{
	struct winlink	*wl;

	if ((wl = winlink_add(&s->windows, idx)) == NULL) {
		xasprintf(cause, "index in use: %d", idx);
		return (NULL);
	}
	wl->session = s;
	winlink_set_window(wl, w);
	if (s->curw == NULL)
		session_set_current(s, wl);
	session_group_synchronize_from(s);
	return (wl);
}

static struct winlink *
newmux_session_attach_at_original_index(struct session *s, struct window *w,
    int idx, char **cause)
{
	struct winlink	*wl;

	if (idx < 0)
		return (newmux_session_attach_silent(s, w, -1, cause));

	wl = winlink_find_by_index(&s->windows, idx);
	if (wl != NULL && winlink_shuffle_up(s, wl, 1) == -1) {
		xasprintf(cause, "index in use: %d", idx);
		return (NULL);
	}
	return (newmux_session_attach_silent(s, w, idx, cause));
}

static struct winlink *
newmux_session_attach_at_saved_position(struct session *s, struct window *w,
    struct newmux_closed_item *item, char **cause)
{
	struct window	*neighbor_w;
	struct winlink	*neighbor_wl;
	int		 idx;

	if (item->left_window_id >= 0) {
		neighbor_w = window_find_by_id((u_int)item->left_window_id);
		neighbor_wl = neighbor_w != NULL ?
		    winlink_find_by_window(&s->windows, neighbor_w) : NULL;
		if (neighbor_wl != NULL) {
			idx = winlink_shuffle_up(s, neighbor_wl, 0);
			if (idx == -1) {
				xasprintf(cause, "index in use after window: @%u",
				    (u_int)item->left_window_id);
				return (NULL);
			}
			return (newmux_session_attach_silent(s, w, idx, cause));
		}
	}

	if (item->right_window_id >= 0) {
		neighbor_w = window_find_by_id((u_int)item->right_window_id);
		neighbor_wl = neighbor_w != NULL ?
		    winlink_find_by_window(&s->windows, neighbor_w) : NULL;
		if (neighbor_wl != NULL) {
			idx = winlink_shuffle_up(s, neighbor_wl, 1);
			if (idx == -1) {
				xasprintf(cause, "index in use before window: @%u",
				    (u_int)item->right_window_id);
				return (NULL);
			}
			return (newmux_session_attach_silent(s, w, idx, cause));
		}
	}

	if (item->window_position >= 0) {
		neighbor_wl = newmux_winlink_at_position(s,
		    (u_int)item->window_position);
		if (neighbor_wl == NULL)
			return (newmux_session_attach_silent(s, w, -1, cause));
		idx = winlink_shuffle_up(s, neighbor_wl, 1);
		if (idx == -1) {
			xasprintf(cause, "index in use at position: %d",
			    item->window_position);
			return (NULL);
		}
		return (newmux_session_attach_silent(s, w, idx, cause));
	}

	return (newmux_session_attach_at_original_index(s, w,
	    item->window_index, cause));
}

static int
newmux_pane_current_command_is_shell(struct window_pane *wp)
{
	char	*cmd, *base;
	int	 result = 0;

	cmd = osdep_get_name(wp->fd, wp->tty);
	if (cmd == NULL || *cmd == '\0') {
		free(cmd);
		cmd = cmd_stringify_argv(wp->argc, wp->argv);
	}
	if (cmd == NULL || *cmd == '\0') {
		free(cmd);
		cmd = xstrdup(wp->shell != NULL ? wp->shell : "");
	}

	base = strrchr(cmd, '/');
	if (base != NULL)
		base++;
	else
		base = cmd;
	if (*base == '-')
		base++;

	if (strcmp(base, "zsh") == 0 || strcmp(base, "bash") == 0 ||
	    strcmp(base, "fish") == 0 || strcmp(base, "sh") == 0)
		result = 1;

	free(cmd);
	return (result);
}

static int
newmux_pane_looks_fresh(struct window_pane *wp)
{
	struct screen		*s = &wp->base;
	struct grid		*gd = s->grid;
	const struct grid_line	*gl;
	u_int			 yy, used = 0;

	if (wp->fd == -1 || !TAILQ_EMPTY(&wp->modes))
		return (0);
	if (wp->argc != 0)
		return (0);
	if (!newmux_pane_current_command_is_shell(wp))
		return (0);
	if (s->saved_grid != NULL || gd->hsize != 0)
		return (0);

	for (yy = 0; yy < gd->sy; yy++) {
		gl = grid_peek_line(gd, gd->hsize + yy);
		if (gl != NULL && gl->cellused != 0)
			used++;
	}
	return (used <= 1);
}

static int
newmux_window_looks_fresh(struct window *w)
{
	struct window_pane	*wp;

	if (window_count_panes(w, 1) != 1)
		return (0);
	wp = TAILQ_FIRST(&w->panes);
	if (wp == NULL)
		return (0);
	return (newmux_pane_looks_fresh(wp));
}

static int
newmux_pane_is_dirty(struct window_pane *wp)
{
	struct options_entry	*o;
	char			*value;
	int			 dirty = 0;

	if (wp == NULL)
		return (0);
	o = options_get_only(wp->options, "@newmux-dirty");
	if (o == NULL || !options_is_string(o))
		return (0);
	value = options_to_string(o, -1, 0);
	if (value != NULL && *value != '\0' && strcmp(value, "0") != 0)
		dirty = 1;
	free(value);
	return (dirty);
}

static int
newmux_window_is_dirty(struct window *w)
{
	struct window_pane	*wp;

	if (w == NULL)
		return (0);
	TAILQ_FOREACH(wp, &w->panes, entry) {
		if (newmux_pane_is_dirty(wp))
			return (1);
	}
	return (0);
}

static char *
newmux_pane_current_path(struct window_pane *wp)
{
	char	*cwd;

	if (wp == NULL)
		return (NULL);
	cwd = osdep_get_cwd(wp->fd);
	if (cwd != NULL)
		return (xstrdup(cwd));
	if (wp->cwd != NULL)
		return (xstrdup(wp->cwd));
	return (NULL);
}

static struct session *
newmux_recovery_session_get(__unused struct cmdq_item *item, struct client *tc,
    const char *cwd)
{
	struct session	*s;
	struct environ	*env;
	struct options	*oo;

	s = session_find(NEWMUX_RECOVERY_SESSION);
	if (s != NULL)
		return (s);

	env = environ_create();
	if (tc != NULL)
		environ_update(global_s_options, tc->environ, env);
	oo = options_create(global_s_options);
	s = session_create(NULL, NEWMUX_RECOVERY_SESSION,
	    cwd != NULL ? cwd : "/", env, oo, NULL);
	return (s);
}

static struct newmux_closed_item *
newmux_item_from_pane(struct session *s, struct winlink *wl,
    struct window_pane *wp)
{
	struct newmux_closed_item	*item;

	item = xcalloc(1, sizeof *item);
	item->type = NEWMUX_CLOSED_PANE;
	item->sequence = ++newmux_closed_next_sequence;
	gettimeofday(&item->closed_at, NULL);

	item->session_id = s->id;
	item->session_name = xstrdup(s->name);
	item->window_id = wl->window->id;
	item->window_name = xstrdup(wl->window->name);
	item->window_index = wl->idx;
	newmux_item_set_window_order(item, s, wl);
	item->window_layout = newmux_dump_window_layout(wl->window);
	item->pane_id = wp->id;
	if (window_pane_index(wp, &item->pane_index) != 0)
		item->pane_index = 0;
	if (window_pane_index(wl->window->active,
	    &item->active_pane_index) != 0)
		item->active_pane_index = item->pane_index;
	return (item);
}

static struct newmux_closed_item *
newmux_item_from_window(struct session *s, struct winlink *wl)
{
	struct newmux_closed_item	*item;

	item = xcalloc(1, sizeof *item);
	item->type = NEWMUX_CLOSED_WINDOW;
	item->sequence = ++newmux_closed_next_sequence;
	gettimeofday(&item->closed_at, NULL);

	item->session_id = s->id;
	item->session_name = xstrdup(s->name);
	item->window_id = wl->window->id;
	item->window_name = xstrdup(wl->window->name);
	item->window_index = wl->idx;
	newmux_item_set_window_order(item, s, wl);
	item->window_layout = newmux_dump_window_layout(wl->window);
	if (window_pane_index(wl->window->active,
	    &item->active_pane_index) != 0)
		item->active_pane_index = 0;
	return (item);
}

static int
newmux_break_live_pane(struct cmdq_item *cmdq_item, struct client *tc,
    struct newmux_closed_item *item, struct session *src_s,
    struct winlink *src_wl, struct window_pane *wp)
{
	struct session	*dst_s;
	struct window	*src_w = src_wl->window, *dst_w;
	struct winlink	*dst_wl;
	char		*cause = NULL, *name;

	dst_s = newmux_recovery_session_get(cmdq_item, tc, src_s->cwd);
	server_unzoom_window(src_w);
	newmux_preserve_pane_history(wp);

	TAILQ_REMOVE(&src_w->panes, wp, entry);
	TAILQ_REMOVE(&src_w->z_index, wp, zentry);
	server_client_remove_pane(wp);
	window_lost_pane(src_w, wp);
	layout_close_pane(wp);

	dst_w = wp->window = window_create(wp->sx, wp->sy,
	    src_w->xpixel, src_w->ypixel);
	options_set_parent(wp->options, dst_w->options);
	wp->flags |= (PANE_STYLECHANGED|PANE_THEMECHANGED|PANE_CHANGED);
	TAILQ_INSERT_HEAD(&dst_w->panes, wp, entry);
	TAILQ_INSERT_HEAD(&dst_w->z_index, wp, zentry);
	dst_w->active = wp;
	dst_w->latest = tc;

	xasprintf(&name, "newmux-recovery-%u", item->sequence);
	window_set_name(dst_w, name);
	free(name);
	options_set_number(dst_w->options, "automatic-rename", 0);

	layout_init(dst_w, wp);
	colour_palette_from_option(&wp->palette, wp->options);

	dst_wl = session_attach(dst_s, dst_w, -1, &cause);
	if (dst_wl == NULL) {
		cmdq_error(cmdq_item, "%s", cause);
		free(cause);
		return (-1);
	}
	if (dst_s->curw == NULL)
		session_select(dst_s, dst_wl->idx);

	item->recovery_session_id = dst_s->id;
	item->recovery_window_id = dst_w->id;

	recalculate_sizes();
	server_redraw_session(src_s);
	server_status_session_group(src_s);
	return (0);
}

static int
newmux_break_live_window(struct cmdq_item *cmdq_item, struct client *tc,
    struct newmux_closed_item *item, struct session *src_s,
    struct winlink *src_wl)
{
	struct session	*dst_s;
	struct winlink	*dst_wl;
	struct window_pane *wp;
	char		*cause = NULL;

	dst_s = newmux_recovery_session_get(cmdq_item, tc, src_s->cwd);
	server_unzoom_window(src_wl->window);
	TAILQ_FOREACH(wp, &src_wl->window->panes, entry)
		newmux_preserve_pane_history(wp);

	dst_wl = newmux_session_attach_silent(dst_s, src_wl->window, -1,
	    &cause);
	if (dst_wl == NULL) {
		cmdq_error(cmdq_item, "%s", cause);
		free(cause);
		return (-1);
	}

	item->recovery_session_id = dst_s->id;
	item->recovery_window_id = src_wl->window->id;

	if (newmux_session_detach_silent(src_s, src_wl)) {
		cmdq_error(cmdq_item,
		    "newmux recovery failed: source session became empty");
		return (-1);
	}
	recalculate_sizes();
	server_redraw_session(src_s);
	server_status_session_group(src_s);
	return (0);
}

static void
newmux_insert_pane_at_index(struct window *w, struct window_pane *wp,
    u_int idx)
{
	struct window_pane	*at;

	at = window_pane_at_index(w, idx);
	if (at != NULL) {
		TAILQ_INSERT_BEFORE(at, wp, entry);
		TAILQ_INSERT_BEFORE(at, wp, zentry);
		return;
	}
	TAILQ_INSERT_TAIL(&w->panes, wp, entry);
	TAILQ_INSERT_TAIL(&w->z_index, wp, zentry);
}

static void
newmux_select_pane_index(struct window *w, u_int idx)
{
	struct window_pane	*wp;

	wp = window_pane_at_index(w, idx);
	if (wp == NULL)
		return;
	window_set_active_pane(w, wp, 1);
	server_redraw_window(w);
}

static struct session *
newmux_restore_destination_session(struct cmdq_item *cmdq_item,
    struct newmux_closed_item *item)
{
	struct cmd_find_state	*target = cmdq_get_target(cmdq_item);
	struct session		*s;

	s = session_find_by_id(item->session_id);
	if (s != NULL)
		return (s);

	if (item->session_name != NULL &&
	    strncmp(item->session_name, "newmux-tab-", 11) == 0) {
		s = session_find("newmux");
		if (s != NULL)
			return (s);
	}

	if (target != NULL && target->s != NULL &&
	    strcmp(target->s->name, NEWMUX_RECOVERY_SESSION) != 0)
		return (target->s);

	return (NULL);
}

static int
newmux_restore_live_pane(struct cmdq_item *cmdq_item,
    struct newmux_closed_item *item)
{
	struct cmd_find_state	*target = cmdq_get_target(cmdq_item);
	struct cmd_find_state	*current = cmdq_get_current(cmdq_item);
	struct session		*dst_s, *recovery_s;
	struct winlink		*dst_wl, *recovery_wl;
	struct window		*dst_w, *recovery_w;
	struct window_pane	*src_wp;
	char			*cause = NULL;

	dst_s = newmux_restore_destination_session(cmdq_item, item);
	if (dst_s == NULL) {
		cmdq_error(cmdq_item, "newmux restore failed: original session missing");
		return (-1);
	}
	dst_w = window_find_by_id(item->window_id);
	if (dst_w == NULL || (dst_wl = winlink_find_by_window(&dst_s->windows,
	    dst_w)) == NULL) {
		cmdq_error(cmdq_item, "newmux restore failed: original window missing");
		return (-1);
	}
	recovery_s = session_find_by_id(item->recovery_session_id);
	recovery_w = window_find_by_id(item->recovery_window_id);
	src_wp = window_pane_find_by_id(item->pane_id);
	if (recovery_s == NULL || recovery_w == NULL || src_wp == NULL) {
		cmdq_error(cmdq_item, "newmux restore failed: live pane missing");
		return (-1);
	}
	recovery_wl = winlink_find_by_window(&recovery_s->windows, recovery_w);
	if (recovery_wl == NULL) {
		cmdq_error(cmdq_item, "newmux restore failed: recovery window missing");
		return (-1);
	}

	server_unzoom_window(dst_w);
	server_unzoom_window(recovery_w);

	layout_close_pane(src_wp);
	server_client_remove_pane(src_wp);
	window_lost_pane(recovery_w, src_wp);
	TAILQ_REMOVE(&recovery_w->panes, src_wp, entry);
	TAILQ_REMOVE(&recovery_w->z_index, src_wp, zentry);

	src_wp->window = dst_w;
	options_set_parent(src_wp->options, dst_w->options);
	src_wp->flags |= (PANE_STYLECHANGED|PANE_THEMECHANGED|PANE_CHANGED);
	newmux_insert_pane_at_index(dst_w, src_wp, item->pane_index);
	colour_palette_from_option(&src_wp->palette, src_wp->options);

	if (item->window_layout != NULL) {
		if (layout_parse(dst_w, item->window_layout, &cause) == -1) {
			cmdq_error(cmdq_item, "newmux restore layout failed: %s",
			    cause);
			free(cause);
			return (-1);
		}
	}
	recalculate_sizes();
	newmux_select_pane_index(dst_w, item->active_pane_index);
	newmux_protect_pane_history_on_next_clear(src_wp);
	session_select(dst_s, dst_wl->idx);
	cmd_find_from_session(current, dst_s, 0);

	server_redraw_window(dst_w);
	server_redraw_session(dst_s);
	server_status_session(dst_s);

	if (window_count_panes(recovery_w, 1) == 0)
		server_kill_window(recovery_w, 1);
	else
		notify_window("window-layout-changed", recovery_w);
	notify_window("window-layout-changed", dst_w);
	(void)target;
	return (0);
}

static int
newmux_restore_live_window(struct cmdq_item *cmdq_item,
    struct newmux_closed_item *item)
{
	struct cmd_find_state	*current = cmdq_get_current(cmdq_item);
	struct session		*dst_s, *recovery_s;
	struct winlink		*dst_wl, *recovery_wl;
	struct window		*w;
	struct newmux_pane_history_snapshots snapshots;
	char			*cause = NULL;

	dst_s = newmux_restore_destination_session(cmdq_item, item);
	if (dst_s == NULL) {
		cmdq_error(cmdq_item, "newmux restore failed: original session missing");
		return (-1);
	}
	recovery_s = session_find_by_id(item->recovery_session_id);
	w = window_find_by_id(item->window_id);
	if (recovery_s == NULL || w == NULL) {
		cmdq_error(cmdq_item, "newmux restore failed: live window missing");
		return (-1);
	}
	recovery_wl = winlink_find_by_window(&recovery_s->windows, w);
	if (recovery_wl == NULL) {
		cmdq_error(cmdq_item, "newmux restore failed: recovery window missing");
		return (-1);
	}

	newmux_history_snapshots_take(w, &snapshots);
	dst_wl = newmux_session_attach_at_saved_position(dst_s, w, item,
	    &cause);
	if (dst_wl == NULL) {
		cmdq_error(cmdq_item, "%s", cause);
		free(cause);
		newmux_history_snapshots_free(&snapshots);
		return (-1);
	}

	server_unlink_window(recovery_s, recovery_wl);
	session_select(dst_s, dst_wl->idx);
	cmd_find_from_session(current, dst_s, 0);

	recalculate_sizes();
	newmux_history_snapshots_restore_if_shrunk(&snapshots);
	newmux_protect_window_history_on_next_clear(w);
	server_redraw_window(w);
	server_redraw_session(dst_s);
	server_status_session(dst_s);
	notify_window("window-linked", w);
	return (0);
}

static enum cmd_retval
cmd_newmux_soft_delete_pane_exec(__unused struct cmd *self,
    struct cmdq_item *cmdq_item)
{
	struct cmd_find_state		*target = cmdq_get_target(cmdq_item);
	struct session			*s = target->s;
	struct winlink			*wl = target->wl;
	struct window_pane		*wp = target->wp;
	struct newmux_closed_item	*item;
	struct client			*tc = cmdq_get_target_client(cmdq_item);

	if (wp == NULL)
		return (CMD_RETURN_ERROR);
	if (window_count_panes(wl->window, 1) == 1) {
		cmdq_error(cmdq_item,
		    "newmux live pane recovery does not delete the last pane yet");
		return (CMD_RETURN_ERROR);
	}

	item = newmux_item_from_pane(s, wl, wp);
	if (newmux_break_live_pane(cmdq_item, tc, item, s, wl, wp) != 0) {
		newmux_free_item(item);
		return (CMD_RETURN_ERROR);
	}
	newmux_stack_push(item);
	return (CMD_RETURN_NORMAL);
}

static enum cmd_retval
cmd_newmux_soft_delete_window_exec(__unused struct cmd *self,
    struct cmdq_item *cmdq_item)
{
	struct cmd_find_state		*target = cmdq_get_target(cmdq_item);
	struct session			*s = target->s;
	struct winlink			*wl = target->wl;
	struct newmux_closed_item	*item;
	struct client			*tc = cmdq_get_target_client(cmdq_item);

	if (wl == NULL)
		return (CMD_RETURN_ERROR);
	if (RB_NEXT(winlinks, &s->windows, wl) == NULL &&
	    RB_PREV(winlinks, &s->windows, wl) == NULL) {
		cmdq_error(cmdq_item,
		    "newmux live tab recovery does not delete the last tab yet");
		return (CMD_RETURN_ERROR);
	}

	if (newmux_window_looks_fresh(wl->window)) {
		server_kill_window(wl->window, 1);
		return (CMD_RETURN_NORMAL);
	}

	item = newmux_item_from_window(s, wl);
	if (newmux_break_live_window(cmdq_item, tc, item, s, wl) != 0) {
		newmux_free_item(item);
		return (CMD_RETURN_ERROR);
	}
	newmux_stack_push(item);
	return (CMD_RETURN_NORMAL);
}

static enum cmd_retval
cmd_newmux_soft_delete_session_exec(__unused struct cmd *self,
    struct cmdq_item *cmdq_item)
{
	cmdq_error(cmdq_item,
	    "newmux live session recovery is not implemented yet");
	return (CMD_RETURN_ERROR);
}

static enum cmd_retval
cmd_newmux_create_window_exec(struct cmd *self, struct cmdq_item *cmdq_item)
{
	struct args		*args = cmd_get_args(self);
	struct cmd_find_state	*target = cmdq_get_target(cmdq_item);
	struct spawn_context	 sc = { 0 };
	struct client		*tc = cmdq_get_target_client(cmdq_item);
	struct session		*s;
	struct winlink		*target_wl = target->wl;
	int			 insertion_idx = -1;
	struct winlink		*new_wl;
	char			*cause = NULL, *cwd = NULL;

	s = newmux_primary_session_from_args(cmdq_item, args, target->s);
	if (s == NULL)
		return (CMD_RETURN_ERROR);

	cwd = newmux_pane_current_path(target->wp);
	if (cwd == NULL)
		cwd = xstrdup(server_client_get_cwd(tc, s));

	if (target_wl == NULL || target_wl->session != s) {
		target_wl = s->curw;
	}
	if (target_wl != NULL) {
		insertion_idx = winlink_shuffle_up(s, target_wl, 0);
	}

	sc.item = cmdq_item;
	sc.s = s;
	sc.tc = tc;
	sc.environ = environ_create();
	sc.idx = insertion_idx;
	sc.cwd = cwd;
	sc.flags = SPAWN_DETACHED;

	new_wl = spawn_window(&sc, &cause);
	if (new_wl == NULL) {
		cmdq_error(cmdq_item, "newmux create window failed: %s", cause);
		free(cause);
		environ_free(sc.environ);
		free(cwd);
		return (CMD_RETURN_ERROR);
	}

	server_status_session_group(s);
	if (args_has(args, 'P'))
		newmux_print_window_result(cmdq_item, "create", s, new_wl,
		    new_wl->window, NULL);

	environ_free(sc.environ);
	free(cwd);
	return (CMD_RETURN_NORMAL);
}

static enum cmd_retval
cmd_newmux_delete_window_exec(struct cmd *self, struct cmdq_item *cmdq_item)
{
	struct args			*args = cmd_get_args(self);
	struct cmd_find_state		*target = cmdq_get_target(cmdq_item);
	struct session			*s;
	struct winlink			*wl;
	struct window			*w;
	struct newmux_closed_item	*item;
	struct client			*tc = cmdq_get_target_client(cmdq_item);
	char				*order;
	int				 print = args_has(args, 'P');

	if (target->wl == NULL)
		return (CMD_RETURN_ERROR);

	w = target->wl->window;
	s = newmux_primary_session_from_args(cmdq_item, args, target->s);
	if (s == NULL)
		return (CMD_RETURN_ERROR);
	wl = winlink_find_by_window(&s->windows, w);
	if (wl == NULL) {
		s = target->s;
		wl = target->wl;
	}

	if (RB_NEXT(winlinks, &s->windows, wl) == NULL &&
	    RB_PREV(winlinks, &s->windows, wl) == NULL) {
		cmdq_error(cmdq_item,
		    "newmux live tab recovery does not delete the last tab yet");
		return (CMD_RETURN_ERROR);
	}

	if (!newmux_window_is_dirty(w)) {
		if (print)
			newmux_print_window_result(cmdq_item, "delete", s, wl,
			    w, "mode=hard soft=0");
		server_kill_window(w, 1);
		return (CMD_RETURN_NORMAL);
	}

	item = newmux_item_from_window(s, wl);
	if (newmux_break_live_window(cmdq_item, tc, item, s, wl) != 0) {
		newmux_free_item(item);
		return (CMD_RETURN_ERROR);
	}
	newmux_stack_push(item);
	if (print) {
		order = newmux_window_order_string(item);
		cmdq_print(cmdq_item,
		    "ok=1 action=delete kind=window mode=soft soft=1 "
		    "sequence=%u window=@%u window_id=@%u "
		    "window_index=%d target_index=%d %s live=1",
		    item->sequence, item->window_id, item->window_id,
		    item->window_index, item->window_position, order);
		free(order);
	}
	return (CMD_RETURN_NORMAL);
}

static void
newmux_print_closed_item(struct cmdq_item *cmdq_item,
    struct newmux_closed_item *item, int reserved)
{
	const char	*reserved_field, *restored_field;
	struct session	*s;
	struct window	*w;
	struct winlink	*wl = NULL;
	char		*order;
	int		 window_index;
	int		 target_index;

	reserved_field = reserved ? " reserved=1" : "";
	restored_field = reserved ? " restored=0" : " restored=1";
	window_index = item->window_index;
	target_index = item->window_position;
	s = session_find_by_id(item->session_id);
	w = window_find_by_id(item->window_id);
	if (s != NULL && w != NULL) {
		wl = winlink_find_by_window(&s->windows, w);
		if (wl != NULL) {
			window_index = wl->idx;
			target_index = newmux_window_position(s, w);
		}
	}
	order = newmux_window_order_string(item);

	if (item->type == NEWMUX_CLOSED_PANE) {
		cmdq_print(cmdq_item,
		    "ok=1 kind=pane sequence=%u window=@%u "
		    "window_id=@%u pane_id=%%%u window_index=%d "
		    "target_index=%d %s live=1%s%s",
		    item->sequence, item->window_id, item->window_id,
		    item->pane_id, window_index, target_index,
		    order, reserved_field, restored_field);
	} else if (item->type == NEWMUX_CLOSED_WINDOW) {
		cmdq_print(cmdq_item,
		    "ok=1 kind=window sequence=%u window=@%u "
		    "window_id=@%u window_index=%d target_index=%d %s "
		    "live=1%s%s",
		    item->sequence, item->window_id, item->window_id,
		    window_index, target_index, order, reserved_field,
		    restored_field);
	} else {
		cmdq_print(cmdq_item,
		    "ok=1 kind=session sequence=%u live=1%s%s",
		    item->sequence, reserved_field, restored_field);
	}
	free(order);
}

static int
newmux_restore_closed_item(struct cmdq_item *cmdq_item,
    struct newmux_closed_item *item)
{
	if (item->type == NEWMUX_CLOSED_PANE)
		return (newmux_restore_live_pane(cmdq_item, item));
	if (item->type == NEWMUX_CLOSED_WINDOW)
		return (newmux_restore_live_window(cmdq_item, item));

	cmdq_error(cmdq_item, "newmux restore failed: unsupported item type");
	return (-1);
}

static enum cmd_retval
cmd_newmux_reopen_latest_closed_exec(struct cmd *self,
    struct cmdq_item *cmdq_item)
{
	struct newmux_closed_item	*item;
	struct args			*args = cmd_get_args(self);
	int				 print = args_has(args, 'P');

	item = newmux_stack_pop();
	if (item == NULL) {
		if (print)
			cmdq_print(cmdq_item,
			    "ok=1 action=restore restored=0 reason=empty_stack");
		return (CMD_RETURN_NORMAL);
	}

	if (newmux_restore_closed_item(cmdq_item, item) != 0) {
		newmux_stack_push(item);
		return (CMD_RETURN_ERROR);
	}
	if (print)
		newmux_print_closed_item(cmdq_item, item, 0);

	newmux_free_item(item);
	return (CMD_RETURN_NORMAL);
}

static enum cmd_retval
cmd_newmux_reserve_latest_closed_exec(struct cmd *self,
    struct cmdq_item *cmdq_item)
{
	struct newmux_closed_item	*item;
	struct args			*args = cmd_get_args(self);
	int				 print = args_has(args, 'P');

	item = newmux_stack_pop();
	if (item == NULL)
		return (CMD_RETURN_NORMAL);

	if (print)
		newmux_print_closed_item(cmdq_item, item, 1);
	newmux_reserved_push(item);
	return (CMD_RETURN_NORMAL);
}

static enum cmd_retval
cmd_newmux_claim_reserved_closed_exec(struct cmd *self,
    struct cmdq_item *cmdq_item)
{
	struct newmux_closed_item	*item;
	struct args			*args = cmd_get_args(self);
	const char			*value, *errstr;
	long long			 n;
	u_int				 sequence;
	int				 print = args_has(args, 'P');

	value = args_get(args, 'S');
	if (value == NULL) {
		cmdq_error(cmdq_item, "missing reserved sequence");
		return (CMD_RETURN_ERROR);
	}
	n = strtonum(value, 1, UINT_MAX, &errstr);
	if (errstr != NULL) {
		cmdq_error(cmdq_item, "invalid reserved sequence: %s", value);
		return (CMD_RETURN_ERROR);
	}
	sequence = n;

	item = newmux_reserved_pop_by_sequence(sequence);
	if (item == NULL)
		return (CMD_RETURN_NORMAL);

	if (newmux_restore_closed_item(cmdq_item, item) != 0) {
		newmux_stack_push(item);
		return (CMD_RETURN_ERROR);
	}
	if (print)
		newmux_print_closed_item(cmdq_item, item, 0);

	newmux_free_item(item);
	return (CMD_RETURN_NORMAL);
}

static enum cmd_retval
cmd_newmux_list_recently_closed_exec(__unused struct cmd *self,
    struct cmdq_item *cmdq_item)
{
	struct newmux_closed_item	*item;

	TAILQ_FOREACH(item, &newmux_closed_stack, entry) {
		if (item->type == NEWMUX_CLOSED_PANE) {
			cmdq_print(cmdq_item,
			    "%u %s session=%s window=%s pane=%%%u live=1",
			    item->sequence, newmux_closed_type_string(item->type),
			    item->session_name, item->window_name, item->pane_id);
		} else {
			cmdq_print(cmdq_item,
			    "%u %s session=%s window=%s live=1",
			    item->sequence, newmux_closed_type_string(item->type),
			    item->session_name, item->window_name);
		}
	}
	return (CMD_RETURN_NORMAL);
}

static enum cmd_retval
cmd_newmux_clear_recently_closed_exec(__unused struct cmd *self,
    __unused struct cmdq_item *cmdq_item)
{
	newmux_recovery_clear();
	return (CMD_RETURN_NORMAL);
}
