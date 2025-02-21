package src

import "core:runtime"
import "core:hash"
import "core:mem"
import "core:fmt"
import "core:strings"
import dll "core:container/intrusive/list"

Command :: proc(u32)
COMBO_MAX :: 48
LUT_SIZE :: 512

Combo_Conflict :: struct {
	using node: dll.Node,
	color: Color,

	// conflicting string to check for
	combo: [COMBO_MAX]u8,
	combo_index: u8,

	count: u16,
}

Conflict_Node :: dll.Node

// named version of an executable command
Keymap_Command :: struct {
	name: string, // ptr to keymap.command_names
	comment: string, // ptr to global keymap.command_comments
	color: Color, // keymap editor color
	call: Command, 

	hash_current: u32,
	index_next: int, // next hash
}

// NOTE heap is easier for now
Keymap :: struct {
	// NOTE set once
	// string storage of all commands
	command_names: strings.Builder,
	
	// NOTE set once
	// string storage of all command comments
	command_comments: strings.Builder,
	
	// NOTE DOESNT CHANGE AT RUNTIME
	commands: [dynamic]Keymap_Command,

	// look up table to go from string hash to command
	command_lut: []int,

	// storage of combos
	combos: [dynamic]Combo_Node,

	// last used combo
	combo_last: ^Combo_Node,
	
	// list of conflicts
	conflict_list: dll.List,
}

keymap_init :: proc(keymap: ^Keymap, commands_cap: int, combos_cap: int) {
	keymap.command_names = strings.builder_make(0, 2056)
	keymap.command_comments = strings.builder_make(0, 2056)
	keymap.commands = make([dynamic]Keymap_Command, 0, commands_cap)
	keymap.combos = make([dynamic]Combo_Node, 0, combos_cap)
	keymap.command_lut = make([]int, LUT_SIZE)

	// set to default
	for i in 0..<len(keymap.command_lut) {
		keymap.command_lut[i] = -1
	}
}

keymap_destroy :: proc(keymap: ^Keymap) {
	// free all nodes
	iter := dll.iterator_head(keymap.conflict_list, Combo_Conflict, "node")
	for node in dll.iterate_next(&iter) {
		free(node)
	}

	delete(keymap.command_comments.buf)
	delete(keymap.command_names.buf)
	delete(keymap.commands)
	delete(keymap.command_lut)
	delete(keymap.combos)
}

keymap_print_commands :: proc(keymap: ^Keymap) {
	fmt.eprintln("KEYMAP\t", len(keymap.commands), cap(keymap.commands))

	for cmd in keymap.commands {
		fmt.eprintf("\tname = %s\tnext = %d\n", cmd.name, cmd.index_next)
	}
}

Combo_Node :: struct {
	combo: [COMBO_MAX]u8,
	combo_index: u8,

	// index into commands
	command_index: int,

	du: u32,
	conflict: ^Combo_Conflict,
}

// combo extension flags
COMBO_EMPTY :: 0x00
COMBO_FALSE :: COMBO_EMPTY
COMBO_CTRL :: 0x01
COMBO_SHIFT :: 0x02
COMBO_TRUE :: 0x04
COMBO_NEGATIVE :: 0x08
COMBO_POSITIVE :: 0x10
COMBO_VALUE :: 0x20

// reinterpret data uint to proper data
du_bool :: proc(du: u32) -> bool {
	return du == COMBO_TRUE
}
du_shift :: proc(du: u32) -> bool {
	return du == COMBO_SHIFT
}
du_pos_neg :: proc(du: u32) -> int {
	return du == COMBO_NEGATIVE ? -1 : du == COMBO_POSITIVE ? 1 : 0
}
du_ctrl :: proc(du: u32) -> bool {
	return du == COMBO_CTRL
}
du_ctrl_shift :: proc(du: u32) -> (bool, bool) {
	return du & COMBO_CTRL == COMBO_CTRL, du & COMBO_SHIFT == COMBO_SHIFT
}
du_value :: proc(du: u32) -> (value: u32, ok: bool) {
	ok = (du - COMBO_VALUE) >= 0
	value = du - COMBO_VALUE
	return
}
// convert du to string for output
du_to_string :: proc(index: int) -> string {
	switch index {
		case 0: return "CTRL"
		case 1: return "SHIFT"
		case 2: return "TRUE"
		case 3: return "NEGATIVE"
		case 4: return "POSITIVE"
		case 5: return "VALUE"
	}

	return ""
}
du_from_string :: proc(text: string) -> u32 {
	switch text {
		case "CTRL": return COMBO_CTRL
		case "SHIFT": return COMBO_SHIFT
		case "TRUE": return COMBO_TRUE
		case "NEGATIVE": return COMBO_NEGATIVE
		case "POSITIVE": return COMBO_POSITIVE
	}

	return COMBO_EMPTY		
}

// find a combo by its desired command string & matching du
keymap_command_find_combo :: proc(
	keymap: ^Keymap, 
	command_index: int,
	du: u32 = COMBO_EMPTY,
) -> (res: ^Combo_Node) {
	if command_index != -1 {
		for node in &keymap.combos {
			if command_index == node.command_index && node.du == du {
				res = &node
				return
			}
		}	
	}

	return
}

// check if a combo node matches to a combo string
keymap_combo_match :: proc(
	keymap: ^Keymap, 
	node: ^Combo_Node, 
	combo: string,
) -> (res: Command, ok: bool) {
	c1 := string(node.combo[:node.combo_index])
	
	if node.command_index != -1 && combo == c1 {
		cmd := keymap_get_command(keymap, node.command_index)
		res = cmd.call
		ok = true
	}

	return
}

// execute a command by combo from a keymap
keymap_combo_execute :: proc(keymap: ^Keymap, combo: string) -> bool {
	// // lookup last used for speedup
	// if keymap.combo_last != nil {
	// 	if cmd, ok := keymap_combo_match(keymap, keymap.combo_last, combo); ok {
	// 		cmd(keymap.combo_last.du)
	// 		return true
	// 	}
	// }

	// lookup linear
	for node in &keymap.combos {
		if cmd, ok := keymap_combo_match(keymap, &node, combo); ok {
			cmd(node.du)
			return true
		}
	}

	return false
}

keymap_get_command :: proc(
	keymap: ^Keymap, 
	command_index: int, 
	loc := #caller_location,
) -> ^Keymap_Command #no_bounds_check {
	runtime.bounds_check_error_loc(loc, command_index, len(keymap.commands))
	return &keymap.commands[command_index]
}

// find a command by its string hash
keymap_find_command :: proc(keymap: ^Keymap, command: string) -> int #no_bounds_check {
	h := hash.fnv32(transmute([]byte) command) & (LUT_SIZE - 1)
	index := keymap.command_lut[h]

	for index != -1 {
		cmd := keymap.commands[index]
		// use hash check?

		if cmd.hash_current == h {
			return index
		}

		index = cmd.index_next
	}

	return -1
}

// push a single command & call to a keymap
keymap_push_command :: proc(
	keymap: ^Keymap,
	command: string,
	call: Command,
	comment: string,
) {
	res := string_list_push_ptr(&keymap.command_names, command)
	h := hash.fnv32(transmute([]byte) command) & (LUT_SIZE - 1)

	assert(keymap.command_lut[h] == -1, command)

	append(&keymap.commands, Keymap_Command {
		name = res,
		comment = comment,
		call = call,
		hash_current = h,
		index_next = keymap.command_lut[h],
	})

	// set this slot to the index
	keymap.command_lut[h] = len(keymap.commands) - 1
}

// set a combo internal values
keymap_combo_set :: proc(
	keymap: ^Keymap,
	node: ^Combo_Node,
	combo: string,
	command: string,
	du: u32,
) {
	combo_index := min(len(node.combo), len(combo))
	mem.copy(&node.combo[0], raw_data(combo), combo_index)
	node.combo_index = u8(combo_index)

	node.command_index = keymap_find_command(keymap, command)
	node.du = du
}

// force push a combo 
keymap_push_combo :: proc(
	keymap: ^Keymap, 
	combo: string,
	command: string,
	du: u32,
) {
	append(&keymap.combos, Combo_Node {})
	node := &keymap.combos[len(keymap.combos) - 1]
	keymap_combo_set(keymap, node, combo, command, du)
}

// optionally push combo if it doesnt exist yet
keymap_push_combo_opt :: proc(
	keymap: ^Keymap, 
	combo: string,
	command: string,
	du: u32,
) {
	command_index := keymap_find_command(keymap, command)
	res := keymap_command_find_combo(keymap, command_index, du)
	
	if res != nil {
		c1 := string(res.combo[:res.combo_index])
		real_cmd := keymap_get_command(keymap, command_index)
		return
	}

	append(&keymap.combos, Combo_Node {})
	node := &keymap.combos[len(keymap.combos) - 1]
	keymap_combo_set(keymap, node, combo, command, du)
}

// free all nodes
keymap_clear_combos :: proc(keymap: ^Keymap) {
	clear(&keymap.combos)
}

__keymap_push: ^Keymap
CP1 :: #force_inline proc(command: string, call: Command, comment: string) {
	keymap_push_command(__keymap_push, command, call, comment)
}
CP2 :: #force_inline proc(combo: string, command: string, du: u32 = 0x00) {
	keymap_push_combo(__keymap_push, combo, command, du)
}
CP4 :: #force_inline proc(combo: string, command: string, du: u32 = 0x00) {
	keymap_push_combo_opt(__keymap_push, combo, command, du)
}

keymap_push_box_commands :: proc(keymap: ^Keymap) {
	__keymap_push = keymap
	CP1("box_move_left", kbox_move_left, "moves the caret to the left | SHIFT for selection | CTRL for extended moves")
	CP1("box_move_right", kbox_move_right, "moves the caret to the right | SHIFT for selection | CTRL for extended moves")
	CP1("box_move_home", kbox_move_home, "moves the caret to the start | SHIFT for selection")
	CP1("box_move_end", kbox_move_end, "moves the caret to the end | SHIFT for selection")
	CP1("box_select_all", kbox_select_all, "selects all characters")
	
	CP1("box_backspace", kbox_backspace, "deletes the character to the left | CTRL for word based")
	CP1("box_delete", kbox_delete, "deletes the character to the right | CTRL for word based")
	
	CP1("box_copy", kbox_copy, "pushes selection to the copy buffer")
	CP1("box_cut", kbox_cut, "cuts selection and pushes to the copy buffer")
	CP1("box_paste", kbox_paste, "pastes text from copy buffer")

	CP1("box_undo", kbox_undo, "undos local changes")
	CP1("box_redo", kbox_redo, "redos local changes")
}

keymap_push_box_combos :: proc(keymap: ^Keymap) {
	__keymap_push = keymap
	CP2("left", "box_move_left")
	CP2("shift left", "box_move_left", COMBO_SHIFT)
	CP2("ctrl left", "box_move_left", COMBO_CTRL)
	CP2("ctrl shift left", "box_move_left", COMBO_CTRL | COMBO_SHIFT)

	CP2("right", "box_move_right")
	CP2("shift right", "box_move_right", COMBO_SHIFT)
	CP2("ctrl right", "box_move_right", COMBO_CTRL)
	CP2("ctrl shift right", "box_move_right", COMBO_CTRL | COMBO_SHIFT)

	CP2("home", "box_move_home")
	CP2("shift home", "box_move_home", COMBO_SHIFT)
	CP2("end", "box_move_end")
	CP2("shift end", "box_move_end", COMBO_SHIFT)

	CP2("backspace", "box_backspace")
	CP2("shift backspace", "box_backspace")
	CP2("ctrl backspace", "box_backspace", COMBO_CTRL)

	CP2("delete", "box_delete")
	CP2("shift delete", "box_delete")
	CP2("ctrl delete", "box_delete", COMBO_CTRL)

	CP2("ctrl a", "box_select_all")
	CP2("ctrl c", "box_copy")
	CP2("ctrl x", "box_cut")
	CP2("ctrl v", "box_paste")

	CP2("ctrl z", "box_undo")
	CP2("ctrl y", "box_redo")
	CP2("ctrl shift z", "box_redo")
}

keymap_push_todool_commands :: proc(keymap: ^Keymap) {
	__keymap_push = keymap
	CP1("move_up", todool_move_up, "move to the upper visible task | SHIFT for selection")
	CP1("move_down", todool_move_down, "move to the lower visible task | SHIFT for selection")
	CP1("bookmark_jump", todool_bookmark_jump, "cycle jump to the previous bookmark")
	CP1("delete_on_empty", todool_delete_on_empty, "deletes the task on no text content")
	CP1("delete_tasks", todool_delete_tasks, "deletes the selected tasks")
	CP1("selection_stop", todool_selection_stop, "stops task selection")
	CP1("change_task_state", todool_change_task_state, "cycles through the task states forwards/backwards")
	CP1("toggle_folding", todool_toggle_folding, "toggle the task folding")
	CP1("toggle_bookmark", todool_toggle_bookmark, "toggle the task bookmark")
	CP1("toggle_tag", todool_toggle_tag, "toggle the task tag bit")
	
	// misc	
	CP1("undo", todool_undo, "undo the last set of actions")
	CP1("redo", todool_redo, "redo the last set of actions")

	CP1("copy_tasks", todool_copy_tasks, "deep copy the selected tasks to the copy buffer")
	CP1("duplicate_line", todool_duplicate_line, "duplicates the selected lines")
	CP1("cut_tasks", todool_cut_tasks, "cut the selected tasks to the copy buffer")
	CP1("paste_tasks", todool_paste_tasks, "paste the content from the copy buffer")

	CP1("center", todool_center, "center the camera vertically")

	// ALL SHARED, usual default bindings
	CP1("indent_jump_low_prev", todool_indent_jump_low_prev, "jump through tasks at indentation 0 backwards | SHIFT for selection")
	CP1("indent_jump_low_next", todool_indent_jump_low_next, "jump through tasks at indentation 0 forwards | SHIFT for selection")
	CP1("indent_jump_same_prev", todool_indent_jump_same_prev, "jump through tasks at the same indentation backwards | SHIFT for selection")
	CP1("indent_jump_same_next", todool_indent_jump_same_next, "jump through tasks at the same indentation forwards | SHIFT for selection")
	CP1("indent_jump_scope", todool_indent_jump_scope, "cycle jump between the start/end task of the parents children")
	CP1("jump_nearby", todool_jump_nearby, "jump to nearest task with different state | SHIFT for backwards")
	CP1("select_all", todool_select_all, "select all visible tasks")

	// shifts
	CP1("indentation_shift", todool_indentation_shift, "shift the selected tasks to the left/right")
	CP1("shift_down", todool_shift_down, "shift the selected tasks down while keeping the same indentation")
	CP1("shift_up", todool_shift_up, "shift the selected tasks up while keeping the same indentation")

	// pomodoro
	CP1("pomodoro_toggle", pomodoro_stopwatch_hot_toggle, "toggle the pomodoro work/short break/long break timer")

	// modes	
	CP1("mode_list", todool_mode_list, "change to the list mode")
	CP1("mode_kanban", todool_mode_kanban, "change to the kanban mode")

	// windows
	CP1("theme_editor", theme_editor_spawn, "spawn the theme editor window")
	CP1("changelog", changelog_spawn, "spawn the changelog generator window")
	CP1("keymap_editor", keymap_editor_spawn, "spawn the keymap editor window")

	// file
	CP1("save", todool_save, "save everything - will use last task save location if set | TRUE to force prompt")
	CP1("load", todool_load, "load task content through file prompt")
	CP1("new_file", todool_new_file, "empty the task content - will try to save before")
	CP1("escape", todool_escape, "escape out of prompts or focused elements")

	// drops
	CP1("goto", todool_goto, "spawn the goto prompt")
	CP1("search", todool_search, "spawn the search prompt")

	CP1("scale_tasks", todool_scale, "scales the tasks up, TRUE for down")
	CP1("fullscreen_toggle", todool_fullscreen_toggle, "toggle between (fake) fullscren and windowed")
	CP1("toggle_progressbars", todool_toggle_progressbars, "toggle progressbars from rendering")

	// movement
	CP1("tasks_to_uppercase", todool_tasks_to_uppercase, "uppercase the starting letters of each word for the selected tasks")
	CP1("tasks_to_lowercase", todool_tasks_to_lowercase, "lowercase all the content for the selected tasks")

	// copy/paste	
	CP1("copy_tasks_to_clipboard", todool_copy_tasks_to_clipboard, "copy the selected tasks STRING content to the clipboard")
	CP1("paste_tasks_from_clipboard", todool_paste_tasks_from_clipboard, "paste the clipboard content based on the indentation")

	// insertion
	CP1("insert_sibling", todool_insert_sibling, "insert a task with the same indentation | SHIFT for above")
	CP1("insert_child", todool_insert_child, "insert a task below with increased indentation")

	// v021
	CP1("select_children", todool_select_children, "select parents children, cycles through start/end on repeat")
	// v022
	CP1("sort_locals", todool_sort_locals, "sorts the local children based on task state")
	// v030
	CP1("toggle_timestamp", todool_toggle_timestamp, "toggle timestamp the selected tasks")

	// v040
	CP1("move_start", todool_move_start, "move to the start of the list")
	CP1("move_end", todool_move_end, "move to the end of the list")
	CP1("toggle_highlight", todool_toggle_highlight, "toggle highlight the selected tasks")
	CP1("toggle_separator", todool_toggle_separator, "toggle separators on the selected tasks")
	CP1("focus_parent", todool_focus_parent, "focus parent WIP")
}

keymap_push_todool_combos :: proc(keymap: ^Keymap) {
	__keymap_push = keymap
	
	// commands
	CP2("ctrl tab", "bookmark_jump")
	CP2("ctrl shift tab", "bookmark_jump", COMBO_SHIFT)
	CP2("ctrl shift j", "tasks_to_uppercase")
	CP2("ctrl shift l", "tasks_to_lowercase")

	// deletion
	CP2("backspace", "delete_on_empty")
	CP2("ctrl backspace", "delete_on_empty")
	CP2("ctrl d", "delete_tasks")
	CP2("ctrl shift k", "delete_tasks")

	// copy/paste raw text
	CP2("ctrl alt c", "copy_tasks_to_clipboard")
	CP2("ctrl shift c", "copy_tasks_to_clipboard")
	CP2("ctrl shift alt c", "copy_tasks_to_clipboard")
	CP2("alt c", "copy_tasks_to_clipboard")
	CP2("ctrl shift v", "paste_tasks_from_clipboard")

	// copy/paste
	CP2("ctrl c", "copy_tasks")
	CP2("ctrl l", "duplicate_line")
	CP2("ctrl x", "cut_tasks")
	CP2("ctrl v", "paste_tasks")

	// misc
	CP2("ctrl q", "change_task_state")
	CP2("ctrl shift q", "change_task_state", COMBO_SHIFT)
	CP2("ctrl j", "toggle_folding")
	CP2("ctrl b", "toggle_bookmark")

	// tags
	CP2("ctrl 1", "toggle_tag", COMBO_VALUE + 0x01)
	CP2("ctrl 2", "toggle_tag", COMBO_VALUE + 0x02)
	CP2("ctrl 3", "toggle_tag", COMBO_VALUE + 0x04)
	CP2("ctrl 4", "toggle_tag", COMBO_VALUE + 0x08)
	CP2("ctrl 5", "toggle_tag", COMBO_VALUE + 0x10)
	CP2("ctrl 6", "toggle_tag", COMBO_VALUE + 0x20)
	CP2("ctrl 7", "toggle_tag", COMBO_VALUE + 0x40)
	CP2("ctrl 8", "toggle_tag", COMBO_VALUE + 0x80)

	// insertion
	CP2_INSERTION()

	// misc
	CP2("ctrl z", "undo")
	CP2("ctrl y", "redo")

	// v021
	CP2("ctrl h", "select_children")

	// v030
	CP2("ctrl r", "toggle_timestamp")

	// v022
	CP2_CROSS()
}

CP2_INSERTION :: proc() {
	// insertion
	CP2("return", "insert_sibling")
	CP2("shift return", "insert_sibling", COMBO_SHIFT)
	CP2("ctrl shift return", "insert_sibling", COMBO_SHIFT)
	CP2("ctrl return", "insert_child")
}	

keymap_push_vim_normal_commands :: proc(keymap: ^Keymap) {
	__keymap_push = keymap
	CP1("insert_mode", vim_insert_mode_set, "enter insert mode")	
	CP1("insert_mode_beginning", vim_insert_mode_beginning, "enter insert mode and move to start of line")
	CP1("insert_above", vim_insert_above, "insert a task above the current line")
	CP1("insert_below", vim_insert_below, "insert a task below the current line")

	CP1("visual_move_left", vim_visual_move_left, "move to the closest task to the left visually")
	CP1("visual_move_right", vim_visual_move_right, "move to the closest task to the right visually")
}

keymap_push_vim_normal_combos :: proc(keymap: ^Keymap) {
	__keymap_push = keymap

	// traditional movement & task based
	CP2("j", "move_down")
	CP2("shift j", "move_down", COMBO_SHIFT)
	CP2("ctrl j", "indent_jump_same_next")
	CP2("ctrl shift j", "indent_jump_same_next")
	CP2("k", "move_up")
	CP2("shift k", "move_up", COMBO_SHIFT)
	CP2("ctrl k", "indent_jump_same_prev")
	CP2("ctrl shift k", "indent_jump_same_prev")
	CP2("d", "delete_tasks")
	CP2("h", "visual_move_left")
	CP2("l", "visual_move_right")
	CP2("left", "visual_move_left")
	CP2("right", "visual_move_right")
	CP2("space", "toggle_folding")

	// inserts
	CP2("i", "insert_mode")
	CP2("shift i", "insert_mode_beginning")
	CP2("o", "insert_below")
	CP2("shift o", "insert_above")
	CP2("ctrl shift o", "insert_child")

	// simplified
	CP2("x", "cut_tasks")
	CP2("c", "copy_tasks")
	CP2("v", "paste_tasks")
	CP2("p", "paste_tasks")
	CP2("y", "duplicate_line")

	// copy/paste raw text
	CP2("shift c", "copy_tasks_to_clipboard")
	CP2("shift v", "paste_tasks_from_clipboard")

	// state sets
	CP2("n", "toggle_folding")
	CP2("b", "toggle_bookmark")
	CP2("q", "change_task_state")
	CP2("shift q", "change_task_state", COMBO_SHIFT)
	CP2("1", "toggle_tag", COMBO_VALUE + 0x01)
	CP2("2", "toggle_tag", COMBO_VALUE + 0x02)
	CP2("3", "toggle_tag", COMBO_VALUE + 0x04)
	CP2("4", "toggle_tag", COMBO_VALUE + 0x08)
	CP2("5", "toggle_tag", COMBO_VALUE + 0x10)
	CP2("6", "toggle_tag", COMBO_VALUE + 0x20)
	CP2("7", "toggle_tag", COMBO_VALUE + 0x40)
	CP2("8", "toggle_tag", COMBO_VALUE + 0x80)

	// custom shifts
	CP2("alt j", "shift_down")
	CP2("alt k", "shift_up")

	// undo/redo
	CP2("u", "undo")
	CP2("ctrl r", "redo")

	CP2_CROSS()
}

// combos that vim & todool need
CP2_CROSS :: proc() {
	CP2("left", "selection_stop")
	CP2("right", "selection_stop")
	CP2("alt right", "jump_nearby")
	CP2("shift alt right", "jump_nearby", COMBO_SHIFT)
	CP2("alt left", "jump_nearby", COMBO_CTRL)
	CP2("shift alt left", "jump_nearby", COMBO_CTRL |COMBO_SHIFT)

	// movement & selection variants
	CP2("up", "move_up")
	CP2("shift up", "move_up", COMBO_SHIFT)
	CP2("down", "move_down")
	CP2("shift down", "move_down", COMBO_SHIFT)

	// shifts
	CP2("tab", "indentation_shift", COMBO_POSITIVE)
	CP2("shift tab", "indentation_shift", COMBO_NEGATIVE)
	CP2("alt down", "shift_down")
	CP2("alt up", "shift_up")
	CP2("escape", "escape")

	// modes
	CP2("alt q", "mode_list")
	CP2("alt w", "mode_kanban")

	// windows
	CP2("alt e", "theme_editor")
	CP2("alt x", "changelog")

	// file
	CP2("ctrl o", "load")
	CP2("ctrl s", "save")
	CP2("ctrl shift s", "save", COMBO_TRUE)
	CP2("ctrl n", "new_file")

	// drops
	CP2("ctrl g", "goto")
	CP2("ctrl f", "search")

	// advanced movement
	CP2("ctrl ,", "indent_jump_low_prev")
	CP2("ctrl shift ,", "indent_jump_low_prev", COMBO_SHIFT)
	CP2("ctrl .", "indent_jump_low_next")
	CP2("ctrl shift .", "indent_jump_low_next", COMBO_SHIFT)
	
	CP2("ctrl up", "indent_jump_same_prev")
	CP2("ctrl shift up", "indent_jump_same_prev", COMBO_SHIFT)
	CP2("ctrl down", "indent_jump_same_next")
	CP2("ctrl shift down", "indent_jump_same_next", COMBO_SHIFT)

	CP2("ctrl m", "indent_jump_scope")
	CP2("ctrl shift m", "indent_jump_scope", COMBO_SHIFT)
	CP2("ctrl shift a", "select_all")

	// newer
	CP2("ctrl -", "scale_tasks", COMBO_NEGATIVE)
	CP2("ctrl +", "scale_tasks", COMBO_POSITIVE)
	CP2("f1", "toggle_progressbars")
	CP2("f11", "fullscreen_toggle")
	CP2("ctrl e", "center")

	CP2("alt a", "sort_locals")

	CP2("alt 1", "pomodoro_toggle", COMBO_VALUE + 0x00)
	CP2("alt 2", "pomodoro_toggle", COMBO_VALUE + 0x01)
	CP2("alt 3", "pomodoro_toggle", COMBO_VALUE + 0x02)

	// v040
	CP2("ctrl home", "move_start")
	CP2("ctrl shift home", "move_start", COMBO_SHIFT)
	CP2("ctrl end", "move_end")
	CP2("ctrl shift end", "move_end", COMBO_SHIFT)
}

keymap_push_vim_insert_commands :: proc(keymap: ^Keymap) {
	__keymap_push = keymap
	CP1("normal_mode", vim_normal_mode_set, "enter normal mode")
	CP1("delete_on_empty", todool_delete_on_empty, "deletes the task on no text content")

		// insertion
	CP1("insert_sibling", todool_insert_sibling, "insert a task with the same indentation | SHIFT for above")
	CP1("insert_child", todool_insert_child, "insert a task below with increased indentation")
}

keymap_push_vim_insert_combos :: proc(keymap: ^Keymap) {
	__keymap_push = keymap

	CP2("escape", "normal_mode")
	CP2("backspace", "delete_on_empty")
	CP2("ctrl backspace", "delete_on_empty")
	
	CP2_INSERTION()
}

keymap_force_push_latest :: proc(keymap: ^Keymap) {
	__keymap_push = keymap
	CP4("alt a", "sort_locals")
	CP4("ctrl r", "toggle_timestamp")

	CP4("ctrl home", "move_start")
	CP4("ctrl shift home", "move_start", COMBO_SHIFT)
	CP4("ctrl end", "move_end")
	CP4("ctrl shift end", "move_end", COMBO_SHIFT)	
	
	CP4("alt j", "toggle_highlight")
	CP4("alt k", "toggle_separator")
	CP4("alt h", "focus_parent")
}
