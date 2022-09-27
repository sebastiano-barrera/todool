package src

import "core:fmt"
import "core:log"
import "core:math"
import "core:strings"

CAM_CENTER :: 100

Pan_Camera_Animation :: struct {
	animating: bool,
	direction: int,
	goal: f32,
}

Pan_Camera :: struct {
	start_x, start_y: f32, // start of drag
	offset_x, offset_y: f32,
	margin_x, margin_y: f32,

	freehand: bool, // disables auto centering while panning

	ay: Pan_Camera_Animation,
	ax: Pan_Camera_Animation,
}

cam_init :: proc(cam: ^Pan_Camera, margin_x, margin_y: f32) {
	cam.offset_x = margin_x
	cam.margin_x = margin_x
	cam.offset_y = margin_y
	cam.margin_y = margin_y
}

cam_set_y :: proc(cam: ^Pan_Camera, to: f32) {
	cam.offset_y = to
	custom_split.vscrollbar.position = -cam.offset_y
}

cam_set_x :: proc(cam: ^Pan_Camera, to: f32) {
	cam.offset_x = to
	custom_split.hscrollbar.position = -cam.offset_x
}

cam_inc_y :: proc(cam: ^Pan_Camera, off: f32) {
	cam.offset_y += off
	custom_split.vscrollbar.position = -cam.offset_y
}

cam_inc_x :: proc(cam: ^Pan_Camera, off: f32) {
	cam.offset_x += off
	custom_split.hscrollbar.position = -cam.offset_x
}

// return the cam per mode
mode_panel_cam :: proc() -> ^Pan_Camera {
	return &mode_panel.cam[mode_panel.mode]
}

cam_animate :: proc(cam: ^Pan_Camera, x: bool) -> bool {
	a := x ? &cam.ax : &cam.ay
	off := x ? &cam.offset_x : &cam.offset_y
	lerp := x ? &caret_lerp_speed_x : &caret_lerp_speed_y
	using a

	if cam.freehand || !animating {
		return false
	}

	real_goal := direction == CAM_CENTER ? goal : math.floor(off^ + f32(direction) * goal)
	// fmt.eprintln("real_goal", x ? "x" : "y", direction == 0, real_goal, off^, direction)
	res := animate_to(
		&animating,
		off,
		real_goal,
		1 + lerp^,
		1,
	)

	custom_split.vscrollbar.position = -cam.offset_y
	custom_split.hscrollbar.position = -cam.offset_x

	lerp^ = res ? lerp^ + 0.5 : 1

	// if !res {
	// 	fmt.eprintln("done", x ? "x" : "y", off^, goal)
	// }

	return res
}

// returns the wanted goal + direction if y is out of bounds of focus rect
cam_bounds_check_y :: proc(
	cam: ^Pan_Camera,
	focus: Rect,
	to_top: f32,
	to_bottom: f32,
) -> (goal: f32, direction: int) {
	if cam.margin_y * 2 > rect_height(focus) {
		return
	}

	if to_top < focus.t + cam.margin_y {
		goal = math.round(focus.t - to_top + cam.margin_y)
	
		if goal != 0 {
			direction = 1
			return
		}
	} 

	if to_bottom > focus.b - cam.margin_y {
		goal = math.round(to_bottom - focus.b + cam.margin_y)

		if goal != 0 {
			direction = -1
		}
	}

	return
}

cam_bounds_check_x :: proc(
	cam: ^Pan_Camera,
	focus: Rect,
	to_left: f32,
	to_right: f32,
) -> (goal: f32, direction: int) {
	if cam.margin_x * 2 >= rect_width(focus) {
		return
	}

	if to_left < focus.l + cam.margin_x {
		goal = math.round(focus.l - to_left + cam.margin_x)

		if goal != 0 {
			direction = 1
			return
		}
	} 

	if to_right >= focus.r - cam.margin_x {
		goal = math.round(to_right - focus.r + cam.margin_x)
		
		if goal != 0 {
			direction = -1
		}
	}

	return
}

// check animation on caret bounds
mode_panel_cam_bounds_check_y :: proc(
	to_top: f32,
	to_bottom: f32,
	use_task: bool, // use task boundary
) {
	cam := mode_panel_cam()

	if cam.freehand {
		return
	}

	to_top := to_top
	to_bottom := to_bottom

	goal: f32
	direction: int
	if task_head != -1 && use_task {
		task := tasks_visible[task_head]
		to_top = task.bounds.t
		to_bottom = task.bounds.b
	}

	goal, direction = cam_bounds_check_y(cam, mode_panel.bounds, to_top, to_bottom)

	if direction != 0 {
		element_animation_start(mode_panel)
		cam.ay.animating = true
		cam.ay.direction = direction
		cam.ay.goal = goal
	}
}

// check animation on caret bounds
mode_panel_cam_bounds_check_x :: proc(
	to_left: f32,
	to_right: f32,
	check_stop: bool,
	use_kanban: bool,
) {
	cam := mode_panel_cam()

	if cam.freehand {
		return
	}

	goal: f32
	direction: int
	to_left := to_left
	to_right := to_right

	switch mode_panel.mode {
		case .List: {
			if task_head != -1 {
				t := tasks_visible[task_head]

				// check if one liner
				if len(t.box.wrapped_lines) == 1 {
					fcs_element(t)
					fcs_ahv(.Left, .Top)
					text_width := string_width(strings.to_string(t.box.builder))

					// if rect_width(mode_panel.bounds) - cam.margin_x * 2 

					to_left = t.bounds.l
					to_right = t.bounds.l + text_width
					// rect := rect_wh(t.bounds.l, t.bounds.t, text_width, text_width + LINE_WIDTH, scaled_size)
				}
			}

			goal, direction = cam_bounds_check_x(cam, mode_panel.bounds, to_left, to_right)
		}

		case .Kanban: {
			// find indent 0 task and get its rect
			t: ^Task
			if task_head != -1 && use_kanban {
				index := task_head
				for t == nil || (t.indentation != 0 && index >= 0) {
					t = tasks_visible[index]
					index -= 1
				}
			}

			if t != nil && t.kanban_rect != {} && use_kanban {
				// check if larger than kanban size
				if rect_width(t.kanban_rect) < rect_width(mode_panel.bounds) - cam.margin_x * 2 {
					to_left = t.kanban_rect.l
					to_right = t.kanban_rect.r
				} 
			}

			goal, direction = cam_bounds_check_x(cam, mode_panel.bounds, to_left, to_right)
		}
	} 

	// fmt.eprintln(goal, direction)

	if check_stop {
		if direction == 0 {
			cam.ax.animating = false
			// fmt.eprintln("FORCE STOP")
		} else {
			// fmt.eprintln("HAD DIRECTION X", goal, direction)
		}
	} else if direction != 0 {
		element_animation_start(mode_panel)
		cam.ax.animating = true
		cam.ax.direction = direction
		cam.ax.goal = goal
	}
}

cam_center_by_height_state :: proc(
	cam: ^Pan_Camera,
	focus: Rect,
	y: f32,
	max_height: f32 = -1,
) {
	if cam.freehand {
		return
	}

	height := rect_height(focus)
	offset_goal: f32

	switch mode_panel.mode {
		case .List: {
			// center by view height max height is lower than view height
			if max_height != -1 && max_height < height {
				offset_goal = f32(height / 2 - max_height / 2)
			} else {
				top := y - f32(cam.offset_y)
				offset_goal = f32(height / 2 - top)
			}
		}

		case .Kanban: {

		}
	}

	element_animation_start(mode_panel)
	cam.ay.animating = true
	cam.ay.direction = CAM_CENTER
	cam.ay.goal = offset_goal
}