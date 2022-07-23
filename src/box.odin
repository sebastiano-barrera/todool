package src

import "core:unicode"
import "core:unicode/utf8"
import "core:mem"
import "core:log"
import "core:strings"
import "core:intrinsics"
import "core:time"
import "../cutf8"
import "../fontstash"

//////////////////////////////////////////////
// normal text box
//////////////////////////////////////////////

// box undo grouping
// 		if we leave the box or task_head it will force group the changes
// 		if timeout of 500ms happens
// 		if shortcut by undo / redo invoke

// NOTE: undo / redo storage of box items could be optimized in memory storage
// e.g. store only one item box header, store commands that happen internally in the byte array

BOX_CHANGE_TIMEOUT :: time.Millisecond * 300

Box :: struct {
	builder: strings.Builder, // actual data
	wrapped_lines: [dynamic]string, // wrapped content
	head, tail: int,
	ds: cutf8.Decode_State,
	
	// word selection state
	word_selection_started: bool,
	word_start: int,
	word_end: int,

	// line selection state
	line_selection_started: bool,
	line_selection_start: int,
	line_selection_end: int,
	line_selection_start_y: f32,

	// when the latest change happened
	change_start: time.Tick,
}

// Text_Box :: struct {
// 	using element: Element,
// 	using box: Box,
// 	scroll: f32,
// }

Task_Box :: struct {
	using element: Element,
	using box: Box,
	text_color: Color,
}

Undo_Item_Box_Rune_Append :: struct {
	box: ^Box,
	codepoint: rune,
}

Undo_Item_Box_Rune_Pop :: struct {
	box: ^Box,
	// just jump back to saved pos instead of calc rune size
	head: int,
	tail: int,
}

undo_box_rune_append :: proc(manager: ^Undo_Manager, item: rawptr) {
	data := cast(^Undo_Item_Box_Rune_Append) item
	strings.write_rune(&data.box.builder, data.codepoint)
	item := Undo_Item_Box_Rune_Pop { data.box, data.box.head, data.box.head }
	data.box.head += 1
	data.box.tail += 1
	undo_push(manager, undo_box_rune_pop, &item, size_of(Undo_Item_Box_Rune_Pop))
}

undo_box_rune_pop :: proc(manager: ^Undo_Manager, item: rawptr) {
	data := cast(^Undo_Item_Box_Rune_Pop) item
	r, width := strings.pop_rune(&data.box.builder)
	data.box.head = data.head
	data.box.tail = data.tail
	item := Undo_Item_Box_Rune_Append {
		box = data.box,
		codepoint = r,
	}
	undo_push(manager, undo_box_rune_append, &item, size_of(Undo_Item_Box_Rune_Append))
}

Undo_Item_Box_Rune_Insert_At :: struct {
	box: ^Box,
	index: int,
	codepoint: rune,
}

Undo_Item_Box_Rune_Remove_At :: struct {
	box: ^Box,
	index: int,
}

undo_box_rune_insert_at :: proc(manager: ^Undo_Manager, item: rawptr) {
	data := cast(^Undo_Item_Box_Rune_Insert_At) item

	// reset and convert to runes for ease
	runes := cutf8.ds_to_runes(&data.box.ds, strings.to_string(data.box.builder))
	b := &data.box.builder
	strings.builder_reset(b)
	
	// step through runes 1 by 1 and insert wanted one
	for i in 0..<len(runes) {
		if i == data.index {
			builder_append_rune(b, data.codepoint)
		}

		builder_append_rune(b, runes[i])
	}
	
	if data.index >= len(runes) {
		builder_append_rune(b, data.codepoint)
	}

	// increase head & tail always
	data.box.head += 1
	data.box.tail += 1

	// create reversal remove at
	item := Undo_Item_Box_Rune_Remove_At {
		box = data.box,
		index = data.index,
	}
	undo_push(manager, undo_box_rune_remove_at, &item, size_of(Undo_Item_Box_Rune_Remove_At))
}

undo_box_rune_remove_at :: proc(manager: ^Undo_Manager, item: rawptr) {
	data := cast(^Undo_Item_Box_Rune_Remove_At) item

	// reset and convert to runes for ease
	runes := cutf8.ds_to_runes(&data.box.ds, strings.to_string(data.box.builder))
	b := &data.box.builder
	strings.builder_reset(b)
	removed_codepoint: rune

	// step through runes 1 by 1 and remove the wanted index
	for i in 0..<len(runes) {
		if i == data.index {
			removed_codepoint = runes[i]
		} else {
			builder_append_rune(b, runes[i])
		}
	}

	// set the head and tail to the removed location
	data.box.head = data.index
	data.box.tail = data.index

	// create reversal to insert at
	item := Undo_Item_Box_Rune_Insert_At {
		box = data.box,
		index = data.index,
		codepoint = removed_codepoint,
	}
	undo_push(manager, undo_box_rune_insert_at, &item, size_of(Undo_Item_Box_Rune_Insert_At))
}

Undo_Item_Box_Remove_Selection :: struct {
	box: ^Box,
	head: int,
	tail: int,
	forced_selection: int, // determines how head & tail are set
}

undo_box_remove_selection :: proc(manager: ^Undo_Manager, item: rawptr) {
	data := cast(^Undo_Item_Box_Remove_Selection) item

	b := &data.box.builder
	runes := cutf8.ds_to_runes(&data.box.ds, strings.to_string(b^))
	strings.builder_reset(b)

	low := min(data.head, data.tail)
	high := max(data.head, data.tail)
	removed_rune_amount := high - low

	// create insert already	
	item := Undo_Item_Box_Insert_Runes {
		data.box,
		data.head,
		data.tail,
		data.forced_selection,
		removed_rune_amount,
	}

	// push upfront to instantly write to the popped runes section
	bytes := undo_push(
		manager, 
		undo_box_insert_runes, 
		&item,
		size_of(Undo_Item_Box_Insert_Runes) + removed_rune_amount * size_of(rune),
	)

	// get runes byte location
	runes_root := cast(^rune) &bytes[size_of(Undo_Item_Box_Insert_Runes)]
	popped_runes := mem.slice_ptr(runes_root, removed_rune_amount)
	pop_index: int

	// pop of runes that are not wanted
	for i in 0..<len(runes) {
		if low <= i && i < high {
			popped_runes[pop_index] = runes[i]
			pop_index += 1
		} else {
			builder_append_rune(b, runes[i])
		}
	}	

	// set to new location
	data.box.head = low
	data.box.tail = low
}

Undo_Item_Box_Insert_Runes :: struct {
	box: ^Box,
	head: int,
	tail: int,
	// determines how head & tail are set
	// 0 = not forced
	// 1 = forced from right
	// 0 = forced from left
	forced_selection: int,
	rune_amount: int, // upcoming runes to read
}

undo_box_insert_runes :: proc(manager: ^Undo_Manager, item: rawptr) {
	data := cast(^Undo_Item_Box_Insert_Runes) item

	b := &data.box.builder
	runes := cutf8.ds_to_runes(&data.box.ds, strings.to_string(b^))
	strings.builder_reset(b)

	low := min(data.head, data.tail)
	high := max(data.head, data.tail)

	// set based on forced selection 
	if data.forced_selection != 0 {
		set := data.forced_selection == 1 ? low : high
		data.box.head = set
		data.box.tail = set
	} else {
		data.box.head = data.head
		data.box.tail = data.tail
	}

	runes_root := cast(^rune) (uintptr(item) + size_of(Undo_Item_Box_Insert_Runes))
	popped_runes := mem.slice_ptr(runes_root, data.rune_amount)
	// log.info("popped rune", runes_root, popped_runes, data.rune_amount, data.head, data.tail)

	for i in 0..<len(runes) {
		// insert popped content back to head location
		if i == low {
			for j in 0..<data.rune_amount {
				builder_append_rune(b, popped_runes[j])
			}
		}

		builder_append_rune(b, runes[i])
	}

	// append to end of string
	if low >= len(runes) {
		for j in 0..<data.rune_amount {
			builder_append_rune(b, popped_runes[j])
		}
	}

	item := Undo_Item_Box_Remove_Selection { 
		data.box,
		data.head,
		data.tail,
		data.forced_selection,
	}
	undo_push(manager, undo_box_remove_selection, &item, size_of(Undo_Item_Box_Remove_Selection))
}

// text_box_message :: proc(element: ^Element, msg: Message, di: int, dp: rawptr) -> int {
// 	box := cast(^Text_Box) element
// 	scale := element.window.scale

// 	#partial switch msg {
// 		case .Left_Down: {
// 			// select caret once
// 			if element_focus(element) {
// 				// TODO unicode
// 				box.head = len(box.builder.buf)
// 				box.tail = box.head
// 			} else {
// 				// old_head := box.head
// 				// old_tail := box.tail
// 				// clicks := di

// 				// // TODO unicode
// 				// w := element.window
// 				// length := len(box.builder.buf)
// 				// text_bounds := element.bounds
// 				// // text_bounds.l += OFF
// 				// text_bounds.r = text_bounds.l + length * GLYPH_WIDTH
// 				// pos := f32(w.cursor_x - text_bounds.l) / f32(rect_width(text_bounds))
// 				// pos = clamp(pos, 0, 1)

// 				// if clicks < 2 {
// 				// 	box.head = int(pos * f32(length))
// 				// 	box.tail = box.head
// 				// } else {
// 				// 	box.head = length
// 				// 	box.tail = 0
// 				// }

// 				// // repaint on changed head
// 				// if old_head != box.head || old_tail != box.tail {
// 				// 	element_repaint(element)
// 				// }
// 			}
// 		}

// 		// case .Animate: {
// 		// 	now := time.tick_now()
// 		// 	diff := time.tick_diff(box.last_tick, now)
// 		// 	dt := time.duration_milliseconds(diff)
// 		// 	box.last_tick = now
// 		// 	box.offset = int(math.sin(dt) * 100)
// 		// 	log.info("animating", dt, box.offset)
// 		// 	element_refresh(element)
// 		// }

// 		case .Mouse_Drag: {
// 			// // selection dragging
// 			// if element.window.focused == element {
// 			// 	old_head := box.head
// 			// 	// TODO unicode
// 			// 	length := len(box.builder.buf)
// 			// 	text_bounds := element.bounds
// 			// 	// text_bounds.l += OFF
// 			// 	text_bounds.r = text_bounds.l + f32(length * GLYPH_WIDTH)
// 			// 	pos := f32(element.window.cursor_x - text_bounds.l) / f32(rect_width(text_bounds))
// 			// 	pos = clamp(pos, 0, 1)
// 			// 	box.head = int(pos * f32(length))

// 			// 	// repaint on changed head
// 			// 	if old_head != box.head {
// 			// 		element_repaint(element)
// 			// 	}
// 			// }
// 		}

// 		case .Get_Cursor: {
// 			return int(Cursor.IBeam)
// 		}

// 		case .Paint_Recursive: {
// 			target := element.window.target
// 			window := element.window
			
// 			outline := window.focused == element ? RED : BLACK
// 			render_rect(target, element.bounds, WHITE)
// 			render_rect_outline(target, element.bounds, outline)
// 			focused := window.focused == element
// 			text := strings.to_string(box.builder)
// 			MARGIN :: 2
// 			scaled_margin := scale * MARGIN
// 			// TODO unicode
// 			text_width := estring_width(element, text) + scaled_margin * 2
// 			text_bounds := rect_add(element.bounds, rect_one_inv(scaled_margin))
// 			caret_x: f32

// 			// handle scrolling
// 			{
// 				// TODO review with scaling
// 				// clamp scroll(?)
// 				if box.scroll > text_width - rect_width(text_bounds) {
// 					box.scroll = text_width - rect_width(text_bounds)
// 				}

// 				if box.scroll < 0 {
// 					box.scroll = 0
// 				}

// 				caret_x = estring_width(element, text[:box.head]) - box.scroll

// 				// check caret x
// 				if caret_x < 0 {
// 					box.scroll = caret_x + box.scroll
// 				} else if caret_x > rect_width(text_bounds) {
// 					box.scroll = caret_x - rect_width(text_bounds) + box.scroll + 1
// 				}
// 			}

// 			// selection
// 			if focused && box.head != box.tail {
// 				selection := text_bounds
// 				selection.l = selection.l - box.scroll
// 				selection.r = selection.l
// 				low, high := box_low_and_high(box)
// 				selection.l += estring_width(element, text[:low])
// 				selection.r += estring_width(element, text[:high])
// 				render_rect(target, selection, GREEN)
// 			} 
			
// 			// text
// 			text_rect := text_bounds
// 			text_rect.l = text_rect.l - box.scroll
// 			erender_string_aligned(element, text, text_rect, BLACK, .Left, .Middle)

// 			// cursor
// 			if focused {
// 				cursor := text_bounds
// 				cursor.l += (estring_width(element, text[:box.head]) - box.scroll)
// 				cursor.r = cursor.l + scale * 2
// 				render_rect(target, cursor, RED)
// 			}
// 		}

// 		case .Key_Combination: {
// 			combo := (cast(^string) dp)^
// 			shift := element.window.shift
// 			ctrl := element.window.ctrl
// 			handled := box_evaluate_combo(box, combo, ctrl, shift)

// 			if handled {
// 				element_repaint(element)
// 			}

// 			return int(handled)
// 		}

// 		case .Unicode_Insertion: {
// 			codepoint := (cast(^rune) dp)^
// 			box_insert(box, codepoint)
// 			element_repaint(element)
// 		}

// 		case .Update: {
// 			element_repaint(element)	
// 		}

// 		case .Get_Width: {
// 			return int(scale * 200)
// 		}

// 		case .Get_Height: {
// 			return int(efont_size(element))
// 		}

// 		case .Deallocate_Recursive: {
// 			delete(box.builder.buf)
// 		}

// 		case .Box_Set_Caret: {
// 			box_set_caret(box, di, dp)
// 		}
// 	}

// 	return 0
// }

// text_box_init :: proc(
// 	parent: ^Element, 
// 	flags: Element_Flags, 
// 	text := "",
// 	index_at := -1,
// ) -> (res: ^Text_Box) {
// 	res = element_init(Text_Box, parent, flags, text_box_message, index_at)
// 	res.builder = strings.builder_make(0, 32)
// 	strings.write_string(&res.builder, text)
// 	// TODO unicode
// 	length := len(res.builder.buf)
// 	res.head = length
// 	res.tail = length
// 	return	
// }

//////////////////////////////////////////////
// Task Box
//////////////////////////////////////////////

task_box_message :: proc(element: ^Element, msg: Message, di: int, dp: rawptr) -> int {
	task_box := cast(^Task_Box) element
	scale := element.window.scale

	#partial switch msg {
		case .Get_Cursor: {
			return int(Cursor.IBeam)
		}

		case .Box_Text_Color: {
			color := cast(^Color) dp
			color^ = theme.text[.Normal]
		}

		case .Paint_Recursive: {
			focused := element.window.focused == element
			target := element.window.target
			font, size := element_retrieve_font_options(element)
			scaled_size := size * scale

			color: Color
			element_message(element, .Box_Text_Color, 0, &color)

			// draw each wrapped line
			y: f32
			for wrap_line, i in task_box.wrapped_lines {
				render_string(
					target,
					font,
					wrap_line,
					element.bounds.l,
					element.bounds.t + y,
					color,
					scaled_size,
				)
				y += scaled_size
			}
		}

		case .Key_Combination: {
			combo := (cast(^string) dp)^
			shift := element.window.shift
			ctrl := element.window.ctrl
			handled := box_evaluate_combo(task_box, &task_box.box, combo, ctrl, shift)

			if handled {
				element_repaint(element)
			}

			return int(handled)
		}

		case .Deallocate_Recursive: {
			delete(task_box.builder.buf)
		}

		case .Update: {
			element_repaint(element)	
		}

		case .Unicode_Insertion: {
			codepoint := (cast(^rune) dp)^
			box_insert(element, task_box, codepoint)
			element_repaint(element)
			return 1
		}

		case .Box_Set_Caret: {
			box_set_caret(task_box, di, dp)
		}
	}

	return 0
}

task_box_init :: proc(
	parent: ^Element, 
	flags: Element_Flags, 
	text := "", 
	index_at := -1,
) -> (res: ^Task_Box) {
	res = element_init(Task_Box, parent, flags, task_box_message, index_at)
	res.builder = strings.builder_make(0, 32)
	strings.write_string(&res.builder, text)

	box_move_end(&res.box, false)
	return
}

//////////////////////////////////////////////
// Box input
//////////////////////////////////////////////

box_evaluate_combo :: proc(
	element: ^Element,
	box: ^Box,
	combo: string, 
	ctrl, shift: bool,
) -> (handled: bool) {
	handled = true

	// TODO could use some form of mapping
	switch combo {
		case "ctrl+shift+left", "ctrl+left", "shift+left", "left": {
			box_move_left(box, ctrl, shift)
		}

		case "ctrl+shift+right", "ctrl+right", "shift+right", "right": {
			box_move_right(box, ctrl, shift)
		}

		case "shift+home", "home": {
			box_move_home(box, shift)
		}
		
		case "shift+end", "end": {
			box_move_end(box, shift)
		}

		case "ctrl+backspace", "shift+backspace", "backspace": {
			handled = box_backspace(element, box, ctrl, shift)
		}

		case "ctrl+delete", "delete": {
			handled = box_delete(element, box, ctrl, shift)
		}

		case "ctrl+a": {
			box_select_all(box)
		}

		case: {
			handled = false
		}
	}

	return
}

box_move_left :: proc(box: ^Box, ctrl, shift: bool) {
	box_move_caret(box, true, ctrl, shift)
	box_check_shift(box, shift)
}

box_move_right :: proc(box: ^Box, ctrl, shift: bool) {
	box_move_caret(box, false, ctrl, shift)
	box_check_shift(box, shift)
}

box_move_home :: proc(box: ^Box, shift: bool) {
	box.head = 0
	box_check_shift(box, shift)
}

box_move_end :: proc(box: ^Box, shift: bool) {
	length := cutf8.ds_recount(&box.ds, strings.to_string(box.builder))
	box.head = length
	box_check_shift(box, shift)
}

box_backspace :: proc(element: ^Element, box: ^Box, ctrl, shift: bool) -> bool {
	old_head := box.head
	old_tail := box.tail

	// skip none
	if box.head == 0 && box.tail == 0 {
		return false
	}

	forced_selection: int
	if box.head == box.tail {
		box_move_caret(box, true, ctrl, shift)
		forced_selection = -1
	}

	box_replace(element, box, "", forced_selection, true)

	// if nothing changes, dont handle
	if box.head == old_head && box.tail == old_tail {
		return false
	}

	return true
}

box_delete :: proc(element: ^Element, box: ^Box, ctrl, shift: bool) -> bool {
	forced_selection: int
	if box.head == box.tail {
		box_move_caret(box, false, ctrl, shift)
		forced_selection = 1
	}

	box_replace(element, box, "", forced_selection, true)
	return true
}

box_select_all :: proc(box: ^Box) {
	length := cutf8.ds_recount(&box.ds, strings.to_string(box.builder))
	box.head = length
	box.tail = 0
}

// commit and reset changes if any
box_force_changes :: proc(manager: ^Undo_Manager, box: ^Box) {
	if box.change_start != {} {
		box.change_start = {}
		undo_group_end(manager)
	}
}

//  check if changes are above timeout limit and commit 
box_check_changes :: proc(manager: ^Undo_Manager, box: ^Box) {
	if box.change_start != {} {
		diff := time.tick_since(box.change_start)

		if diff > BOX_CHANGE_TIMEOUT {
			undo_group_end(manager)
		}
	} 

	box.change_start = time.tick_now()		
}

box_insert :: proc(element: ^Element, box: ^Box, codepoint: rune) {
	if box.head != box.tail {
		box_replace(element, box, "", 0, true)
	}
	
	builder := &box.builder
	count := cutf8.ds_recount(&box.ds, strings.to_string(box.builder))
	manager := mode_panel_manager_begin()

	box_check_changes(manager, box)
	task_head_tail_push(manager)

	// push at end
	if box.head == count {
		item := Undo_Item_Box_Rune_Append {
			box = box,
			codepoint = codepoint,
		}
		undo_box_rune_append(manager, &item)
	} else {
		item := Undo_Item_Box_Rune_Insert_At {
			box = box,
			codepoint = codepoint,
			index = box.head,
		}
		undo_box_rune_insert_at(manager, &item)
	}

	element_message(element, .Value_Changed)
}

// utf8 based removal of selection & replacing selection with text
box_replace :: proc(
	element: ^Element,
	box: ^Box, 
	text: string, 
	forced_selection: int, 
	send_changed_message: bool,
) {
	manager := mode_panel_manager_begin()
	box_check_changes(manager, box)
	task_head_tail_push(manager)

	// remove selection
	if box.head != box.tail {
		low, high := box_low_and_high(box)

		// on single removal just do remove at
		if high - low == 1 {
			item := Undo_Item_Box_Rune_Remove_At { 
				box,
				low,
			}

			undo_box_rune_remove_at(manager, &item)
			// log.info("remove selection ONE")
		} else {
			item := Undo_Item_Box_Remove_Selection { 
				box,
				box.head,
				box.tail,
				forced_selection,
			}
			undo_box_remove_selection(manager, &item)
			// log.info("remove selection", high - low)
		}
	
		if send_changed_message {
			element_message(element, .Value_Changed)
		}
	} else {
		if len(text) != 0 {
			log.info("INSERT RUNES")
			// item := Undo_Item_Box_Insert_Runes {
			// 	box = box,
			// 	head = box.head,
			// 	tail = box.head,
			// 	rune_amount = len()
			// }
		} 
	}

}

box_clear :: proc(box: ^Box, send_changed_message: bool) {
	strings.builder_reset(&box.builder)
	box.head = 0
	box.tail = 0
}

box_check_shift :: proc(box: ^Box, shift: bool) {
	if !shift {
		box.tail = box.head
	}
}

box_move_caret :: proc(box: ^Box, backward: bool, word: bool, shift: bool) {
	// TODO unicode handling
	if !shift && box.head != box.tail {
		if box.head < box.tail {
			if backward {
				box.tail = box.head
			} else {
				box.head = box.tail
			}
		} else {
			if backward {
				box.head = box.tail
			} else {
				box.tail = box.head
			}
		}

		return
	}

	runes := cutf8.ds_to_runes(&box.ds, strings.to_string(box.builder))
	
	for {
		// box ahead of 0 and backward allowed
		if box.head > 0 && backward {
			box.head -= 1
		} else if box.head < len(runes) && !backward {
			// box not in the end and forward 
			box.head += 1
		} else {
			return
		}

		if !word {
			return
		} else if box.head != len(runes) && box.head != 0 {
			c1 := runes[box.head - 1]
			c2 := runes[box.head]
			
			if unicode.is_alpha(c1) != unicode.is_alpha(c2) {
				return
			}
		}
	}
}

box_set_caret :: proc(box: ^Box, di: int, dp: rawptr) {
	switch di {
		case 0: {
			goal := cast(^int) dp
			box.head = goal^
			box.tail = goal^
		}

		case BOX_START: {
			box.head = 0
			box.tail = 0
		}

		case BOX_END: {
			length := cutf8.ds_recount(&box.ds, strings.to_string(box.builder))
			box.head = length
			box.tail = box.head
		}

		case: {
			log.info("UI: text box unsupported caret setting")
		}
	}
}

builder_append_rune :: proc(builder: ^strings.Builder, r: rune) {
	bytes, size := utf8.encode_rune(r)
	
	if size == 1 {
		append(&builder.buf, bytes[0])
	} else {
		for i in 0..<size {
			append(&builder.buf, bytes[i])
		}
	}
}

box_low_and_high :: proc(box: ^Box) -> (low, high: int) {
	low = min(box.head, box.tail)
	high = max(box.head, box.tail)
	return
}

//////////////////////////////////////////////
// Box render
//////////////////////////////////////////////

box_render_caret :: proc(
	target: ^Render_Target, 
	box: ^Box,
	font: ^Font,
	scaled_size: f32,
	x, y: f32,
) {
	// wrapped line based caret
	wanted_line, index_start := fontstash.codepoint_index_to_line(
		box.wrapped_lines[:], 
		box.head,
	)

	goal := box.head - index_start
	text := box.wrapped_lines[wanted_line]
	low_width: f32
	scale := fontstash.scale_for_pixel_height(font, scaled_size)
	xadvance, lsb: i32

	// iter tilloin
	ds: cutf8.Decode_State
	for codepoint, i in cutf8.ds_iter(&ds, text) {
		if i >= goal {
			break
		}

		low_width += fontstash.codepoint_xadvance(font, codepoint, scale)
	}

	caret_rect := rect_wh(
		x + low_width,
		y + f32(wanted_line) * scaled_size,
		2,
		scaled_size,
	)

	render_rect(target, caret_rect, theme.caret)
}

Wrap_State :: struct {
	// font option
	font: ^Font,
	scaled_size: f32,
	
	// text lines
	lines: []string,

	// result
	rect_valid: bool,
	rect: Rect,

	// increasing state
	line_index: int,
	codepoint_offset: int,
	y_offset: f32,
}

wrap_state_init :: proc(lines: []string, font: ^Font, scaled_size: f32) -> Wrap_State {
	return Wrap_State {
		lines = lines,
		font = font,
		scaled_size = scaled_size,
	}
}

wrap_state_iter :: proc(
	using wrap_state: ^Wrap_State,
	index_from: int,
	index_to: int,
) -> bool {
	if line_index > len(lines) - 1 {
		return false
	}

	text := lines[line_index]
	line_index += 1
	rect_valid = false
	
	text_width: f32
	x_from_start: f32 = -1
	x_from_end: f32
	ds: cutf8.Decode_State
	scale := fontstash.scale_for_pixel_height(font, scaled_size)

	// iterate string line
	for codepoint, i in cutf8.ds_iter(&ds, text) {
		width_codepoint := fontstash.codepoint_xadvance(font, codepoint, scale)

		if index_from <= i + codepoint_offset && i + codepoint_offset <= index_to {
			if x_from_start == -1 {
				x_from_start = text_width
			}

			x_from_end = text_width
		}

		text_width += width_codepoint
	}

	// last character
	if index_to == codepoint_offset + ds.codepoint_count {
		x_from_end = text_width
	}

	codepoint_offset += ds.codepoint_count

	if x_from_start != -1 {
		y := y_offset * scaled_size

		rect = Rect {
			x_from_start,
			x_from_end,
			y,
			y + scaled_size,
		}

		rect_valid = true
	}

	y_offset += 1
	return true
}

box_render_selection :: proc(
	target: ^Render_Target, 
	box: ^Box,
	font: ^Font,
	scaled_size: f32,
	x, y: f32,	
) {
	if box.head == box.tail {
		return
	}

	low, high := box_low_and_high(box)
	state := wrap_state_init(box.wrapped_lines[:], font, scaled_size)

	for wrap_state_iter(&state, low, high) {
		if state.rect_valid {
			rect := state.rect
			translated := rect_add(rect, rect_xxyy(x, y))
			render_rect(target, translated, theme.caret_selection)
		}
	}
}