package src

import "core:fmt"
import "core:mem"
import "core:math"
import "core:strings"

//changelog generator output window
//	descritiption what this window does
//	button to update to task tree content (in case the window is kept alive)
//	display supposed generated output
//	checkboxes to decide where to output (Terminal, File, Clipboard)
//	checkbox to remove content from task tree or not
//	allow changing numbering scheme or inserting stars at the start of each textual line

//LATER
//	skip folded

Changelog :: struct {
	window: ^Window,
	panel: ^Panel,
	td: ^Changelog_Text_Display,

	checkbox_skip_folded: ^Checkbox,
	checkbox_include_canceled: ^Checkbox,
}
changelog: Changelog

changelog_window_message :: proc(element: ^Element, msg: Message, di: int, dp: rawptr) -> int {
	window := cast(^Window) element

	#partial switch msg {
		case .Destroy: {
			changelog = {}
		}
	}

	return 0
}

Changelog_Text_Display :: struct {
	using element: Element,
	builder: strings.Builder,
	vscrollbar: ^Scrollbar,
	hscrollbar: ^Scrollbar,
}

changelog_text_display_message :: proc(element: ^Element, msg: Message, di: int, dp: rawptr) -> int {
	td := cast(^Changelog_Text_Display) element
	margin_scaled := math.round(5 * SCALE)
	tab_scaled := math.round(50 * SCALE)

	#partial switch msg {
		case .Layout: {
			bounds := element.bounds
			bottom, right := scrollbars_layout_prior(&bounds, td.hscrollbar, td.vscrollbar)
			
			// measure max string width and lines
			iter := strings.to_string(td.builder)
			width: f32
			line_count: int
			scaled_size := fcs_element(element)
			for line in strings.split_lines_iterator(&iter) {
				tabs := tabs_count(line)
				width = max(width, string_width(line) + f32(tabs) * tab_scaled)
				line_count += 1
			}

			scrollbar_layout_post(td.hscrollbar, bottom, width)
			scrollbar_layout_post(td.vscrollbar, right, f32(line_count) * scaled_size)
		}

		case .Paint_Recursive: {
			target := element.window.target
			render_rect(target, element.bounds, theme.background[1], ROUNDNESS)
			bounds := rect_margin(element.bounds, margin_scaled)
			
			text := strings.to_string(td.builder)
			scaled_size := fcs_element(element)

			if len(text) == 0 {
				fcs_color(theme.text_blank)
				fcs_ahv()
				render_string_rect(target, bounds, "no changes found")
			} else {
				// render each line, increasingly
				fcs_color(theme.text_default)
				fcs_ahv(.Left, .Top)
				x := bounds.l - td.hscrollbar.position
				y := bounds.t - td.vscrollbar.position

				iter := text
				for line in strings.split_lines_iterator(&iter) {
					tabs := tabs_count(line)

					render_string(
						target,
						x + f32(tabs) * tab_scaled, y,
						line[tabs:],
					)

					y += scaled_size
				}
			}
		}

		case .Mouse_Scroll_X: {
			if scrollbar_valid(td.hscrollbar) {
				return element_message(td.hscrollbar, msg, di, dp)
			}
		}

		case .Mouse_Scroll_Y: {
			if scrollbar_valid(td.vscrollbar) {
				return element_message(td.vscrollbar, msg, di, dp)
			}
		}

		case .Destroy: {
			delete(td.builder.buf)
		}
	}

	return 0	
}

changelog_text_display_init :: proc(
	parent: ^Element,
	flags: Element_Flags,
) -> (res: ^Changelog_Text_Display) {
	res = element_init(Changelog_Text_Display, parent, flags, changelog_text_display_message, context.allocator)
	res.builder = strings.builder_make(0, mem.Kilobyte)
	res.hscrollbar = scrollbar_init(res, {}, true, context.allocator)
	res.vscrollbar = scrollbar_init(res, {}, false, context.allocator)
	return
}

// iterate through tasks the same way
changelog_task_iter :: proc(index: ^int) -> (res: ^Task, remove: bool, ok: bool) {
	include := changelog.checkbox_include_canceled.state
	skip := changelog.checkbox_skip_folded.state

	for i in index^..<len(mode_panel.children) {
		task := cast(^Task) mode_panel.children[i]
		index^ += 1

		// skip individual task
		if !task.visible && skip {
			continue
		}

		state_matched := include ? task.state != .Normal : task.state == .Done 

		if state_matched {
			res = task
			remove = true
			ok = true
			return
		} else if task.has_children {
			// skip parent
			if task.folded && skip {
				continue
			}

			a := include && (task.state_count[.Done] != 0 || task.state_count[.Canceled] != 0)
			b := !include && task.state_count[.Done] != 0

			if a || b {
				res = task
				ok = true
				return
			}
		}
	}

	return
}

changelog_text_display_set :: proc(td: ^Changelog_Text_Display) {
	b := &td.builder
	strings.builder_reset(b)

	write :: proc(b: ^strings.Builder, task: ^Task, indentation: int) {
		for i in 0..<indentation {
			strings.write_byte(b, '\t')
		}

		strings.write_string(b, strings.to_string(task.box.builder))
		strings.write_byte(b, '\n')
	}

	index: int
	for task, remove in changelog_task_iter(&index) {
		write(b, task, task.indentation)
	}
}

// pop the wanted changelog tasks
changelog_result_pop_tasks :: proc(manager: ^Undo_Manager) {
	index: int
	for task, remove in changelog_task_iter(&index) {
		if remove {
			archive_push(strings.to_string(task.box.builder))
			task_remove_at_index(manager, index - 1)
			index -= 1
		}
	}
}

changelog_result :: proc() -> string {
	return strings.to_string(changelog.td.builder)
}

changelog_update :: proc(data: rawptr) {
	changelog_text_display_set(changelog.td)
	changelog.window.update_next = true
}

changelog_spawn :: proc() {
	if changelog.window != nil {
		return
	}

	changelog.window = window_init(nil, {}, "Changelog Genrator", 700, 700)
	changelog.window.element.message_user = changelog_window_message
	changelog.window.on_focus_gained = proc(window: ^Window) {
		if changelog.td != nil {
			changelog_text_display_set(changelog.td)
		}
		window.update_next = true
	}

	changelog.panel = panel_init(
		&changelog.window.element,
		{ .HF, .VF },
		5,
		5,
	)
	p := changelog.panel
	
	{
		p1 := panel_init(p, { .HF, .Panel_Default_Background }, 5, 5)
		p1.background_index = 1
		p1.rounded = true
		label_init(p1, { .HF, .Label_Center }, "Generates a Changelog from your Done/Canceled Tasks")
		
		{
			p2 := panel_init(p1, { .HF, .Panel_Default_Background })
			p2.background_index = 2
			p2.rounded = true
			b1 := button_init(p2, { .HF }, "Update")
			b1.invoke = proc(data: rawptr) {
				changelog_text_display_set(changelog.td)
			}
		}

		{
			p2 := panel_init(p1, { .HF, .Panel_Horizontal }, 5, 5)
			label_init(p2, { .Label_Center }, "Generate to")
			p3 := panel_init(p2, { .HF, .Panel_Horizontal, .Panel_Default_Background })
			p3.background_index = 2
			p3.rounded = true
			button_init(p3, { .HF }, "Clipboard").invoke = proc(data: rawptr) {
				text := changelog_result()
				clipboard_set_with_builder(text)
			}
			button_init(p3, { .HF }, "Terminal").invoke = proc(data: rawptr) {
				fmt.println(changelog_result())
			}
			button_init(p3, { .HF }, "File").invoke = proc(data: rawptr) {
				path := bpath_temp("changelog.txt")
				gs_write_safely(path, changelog.td.builder.buf[:])
			}
		}

		{
			// toggle := toggle_panel_init(p1, { .HF }, { .Panel_Default_Background }, "Options", false)
			// p2 := toggle.panel
			
			p2 := panel_init(p1, { .HF, .Panel_Default_Background, .Panel_Horizontal })
			p2.background_index = 2
			p2.margin = 5
			p2.rounded = true
			p2.gap = 5
			changelog.checkbox_skip_folded = checkbox_init(p2, { .HF }, "Skip Folded", true)
			changelog.checkbox_skip_folded.invoke = changelog_update
			changelog.checkbox_include_canceled = checkbox_init(p2, { .HF }, "Include Canceled Tasks", true)
			changelog.checkbox_include_canceled.invoke = changelog_update
		}
	}

	changelog.td = changelog_text_display_init(p, { .HF, .VF })
	changelog_text_display_set(changelog.td)
}