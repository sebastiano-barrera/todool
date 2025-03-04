package src

import "core:fmt"
import "core:strings"
import "core:log"
import "core:mem"
import glm "core:math/linalg/glsl"
import "core:runtime"
import "core:math"
import "core:image"
import "core:image/png"
import "core:sort"
import "core:slice"
import sdl "vendor:sdl2"
import gl "vendor:OpenGL"
import "vendor:fontstash"
import "cutf8"

shader_vert := #load("assets/vert.glsl")
shader_frag := #load("assets/frag.glsl")
png_sv := #load("assets/sv.png")
png_hue := #load("assets/hue.png")
png_mode_icon_kanban := #load("assets/Kanban Mode Icon.png")
png_mode_icon_list := #load("assets/List Mode Icon.png")
png_mode_icon_drag := #load("assets/Task Drag Icon.png")
Align_Horizontal :: fontstash.AlignHorizontal
Align_Vertical :: fontstash.AlignVertical
DROP_SHADOW :: 20
DEFAULT_VERTICES :: 1024 * 2

Icon :: enum {	
	NONE =         0x0,
	DOWN_OPEN =    0xe800,
	FLOPPY =       0xe801,
	TAG =          0xe802,
	COG =          0xe803,
	STOP =         0xe804,
	PAUSE =        0xe805,
	LEFT_OPEN =    0xe806,
	RIGHT_OPEN =   0xe807,
	DOC =          0xe808,
	PLUS =         0xe809,
	MINUS =        0xe80a,
	CANCEL =       0xe80b,
	OK =           0xe80c,
	FOLDER =       0xe80d,
	ARCHIVE =      0xe80e,
	DOCS =         0xf0c5,
	PLAY_CIRCLED = 0xf144,
	DOC_INV =      0xf15b,
	CHART_AREA =   0xf1fe,
}

Render_Target :: struct {
	window_show: b32,

	// holding groups of vertices
	groups: [dynamic]Render_Group,

	// slice to quickly clear vertices
	vertices: []Render_Vertex,
	vertex_index: int,

	// gl based
	vao: u32,
	attribute_buffer: u32,
	shader_program: u32,

	// shader locations
	// uniforms
	uniform_projection: i32,
	uniform_shadow_color: i32,
	shadow_color: Color,

	// attributes
	attribute_position: u32,
	attribute_uv: u32,
	attribute_color: u32,
	attribute_roundness_and_thickness: u32,
	attribute_add: u32,
	attribute_kind: u32,

	// texture atlas
	textures: [Texture_Kind]Render_Texture,

	// context thats needed to be switched to
	opengl_context: sdl.GLContext,

	// shared shallow texture
	shallow_uniform_sampler: i32,
}

Render_Group :: struct {
	clip: RectI,
	vertex_start, vertex_end: int,
	bind_handle: u32,
	bind_slot: int,
	
	// state properties
	blend_sfactor: i32,
	blend_dfactor: i32,
	blend_func: i32,
}

Texture_Kind :: enum {
	Fonts,
	SV,
	HUE,
	Kanban,
	List,
	Drag,
}

Render_Texture :: struct {
	width, height: i32,
	data: rawptr,
	handle: u32, // gl handle
	format_a: i32,
	format_b: u32,

	uniform_sampler: i32,
	image: ^image.Image,
}

Render_Kind :: enum u32 {
	Invalid,
	Rectangle,
	Glyph,
	Drop_Shadow,
	Circle,
	Circle_Outline,
	Sine,
	Segment,

	SV,
	HUE,
	Texture,
}

Render_Vertex :: struct #packed {
	pos_xy: [2]f32,
	uv_xy: [2]f32,
	color: Color,
	
	// split for u32
	roundness: u16,
	thickness: u16,
	add: [4]f32,

	// render kind
	kind: Render_Kind,
}

render_target_init :: proc(window: ^sdl.Window) -> (res: ^Render_Target) {
	res = new(Render_Target)
	using res

	sdl.GL_SetAttribute(.CONTEXT_MAJOR_VERSION, 3)
	sdl.GL_SetAttribute(.CONTEXT_MINOR_VERSION, 3)
	sdl.GL_SetAttribute(.CONTEXT_PROFILE_MASK, i32(sdl.GLprofile.CORE))
	sdl.GL_SetAttribute(.CONTEXT_FLAGS, i32(sdl.GLcontextFlag.DEBUG_FLAG))
	opengl_context = sdl.GL_CreateContext(window)
	gl.load_up_to(3, 3, sdl.gl_set_proc_address)

	// shader loading
	shader_ok: bool
	shader_program, shader_ok = gl.load_shaders_source(string(shader_vert), string(shader_frag), false)
	if !shader_ok {
		log.panic("RENDERER: Failed to load shader")
	}
	gl.UseProgram(shader_program)

	// uniforms
	uniform_projection = gl.GetUniformLocation(shader_program, "u_projection")
	uniform_shadow_color = gl.GetUniformLocation(shader_program, "u_shadow_color")
	
	// attributes
	attribute_position = u32(gl.GetAttribLocation(shader_program, "i_pos"))
	attribute_uv = u32(gl.GetAttribLocation(shader_program, "i_uv"))
	attribute_color = u32(gl.GetAttribLocation(shader_program, "i_color"))
	attribute_add = u32(gl.GetAttribLocation(shader_program, "i_add"))
	attribute_roundness_and_thickness = u32(gl.GetAttribLocation(shader_program, "i_roundness_and_thickness"))
	attribute_kind = u32(gl.GetAttribLocation(shader_program, "i_kind"))

	gl.GenVertexArrays(1, &vao)
	gl.BindVertexArray(vao)

	gl.GenBuffers(1, &attribute_buffer)
	gl.BindBuffer(gl.ARRAY_BUFFER, attribute_buffer)

	// render data
	groups = make([dynamic]Render_Group, 0, 32)
	vertices = make([]Render_Vertex, 1000 * 64)

	render_target_fontstash_generate(res, gs.fc.width, gs.fc.height)
	textures[.Fonts].uniform_sampler = gl.GetUniformLocation(shader_program, "u_sampler_font")

	// TODO only generate this for main window?
	texture_generate_from_png(res, .SV, png_sv, "_sv")
	texture_generate_from_png(res, .HUE, png_hue, "_hue")
	texture_generate_from_png(res, .Kanban, png_mode_icon_kanban, "_kanban")
	texture_generate_from_png(res, .List, png_mode_icon_list, "_list")
	texture_generate_from_png(res, .Drag, png_mode_icon_drag, "_drag", gl.CLAMP_TO_EDGE, gl.LINEAR)

	res.shallow_uniform_sampler = gl.GetUniformLocation(shader_program, "u_sampler_custom")
	// log.info("bind slots", gl.MAX_COMBINED_TEXTURE_IMAGE_UNITS)

	return
}

// generate the fontstash atlas texture with the wanted width and height
render_target_fontstash_generate :: proc(using target: ^Render_Target, width, height: int) {
	textures[.Fonts] = Render_Texture {
		data = raw_data(gs.fc.textureData),
		width = i32(width),
		height = i32(height),
		format_a = gl.R8,
		format_b = gl.RED,
	}
	// TODO could do texture image2d with nil on resize?
	texture_generate(target, .Fonts)
}

render_target_destroy :: proc(using target: ^Render_Target) {
	sdl.GL_DeleteContext(opengl_context)
	delete(vertices)
	delete(groups)
	
	for texture in &textures {
		texture_destroy(&texture)
	}

	free(target)
}

render_target_begin :: proc(using target: ^Render_Target, shadow: Color) {
	shadow_color = shadow

	// clear group
	clear(&target.groups)
	
	// clear vertex info
	vertex_index = 0
}

rect_scissor :: proc(target_height: i32, r: RectI) {
	height := i32(r.b - r.t)
	gl.Scissor(i32(r.l), target_height - height - i32(r.t), i32(r.r - r.l), height)
}

render_target_end :: proc(
	using target: ^Render_Target, 
	window: ^sdl.Window, 
	width, height: int,
) {
	// showing the window delayed, in case the window is moved!
	if !target.window_show {
		target.window_show = true
		sdl.ShowWindow(window)
	}

	err := sdl.GL_MakeCurrent(window, target.opengl_context)
	if err < 0 {
		log.panic("GL: MakeCurrent failed!")
	}

	w := sdl.GL_GetCurrentWindow()
	if w != window {
		log.panic("GL: unmatched window")
	}

	gl.Enable(gl.SCISSOR_TEST)
	gl.Enable(gl.BLEND)
	gl.Enable(gl.MULTISAMPLE)
	gl.Disable(gl.CULL_FACE)
	gl.Disable(gl.DEPTH_TEST)
	
	gl.Viewport(0, 0, i32(width), i32(height))
	gl.Scissor(0, 0, i32(width), i32(height))
	gl.ClearColor(1, 1, 1, 1)
	gl.Clear(gl.COLOR_BUFFER_BIT)
	gl.BindTexture(gl.TEXTURE_2D, 0)

	gl.EnableVertexAttribArray(attribute_position)
	gl.EnableVertexAttribArray(attribute_uv)
	gl.EnableVertexAttribArray(attribute_color)
	gl.EnableVertexAttribArray(attribute_add)
	gl.EnableVertexAttribArray(attribute_roundness_and_thickness)
	gl.EnableVertexAttribArray(attribute_kind)
	size := i32(size_of(Render_Vertex))
	gl.VertexAttribPointer(attribute_position, 2, gl.FLOAT, true, size, 0)
	gl.VertexAttribPointer(attribute_uv, 2, gl.FLOAT, true, size, offset_of(Render_Vertex, uv_xy))
	gl.VertexAttribIPointer(attribute_color, 1, gl.UNSIGNED_INT, size, offset_of(Render_Vertex, color))
	gl.VertexAttribPointer(attribute_add, 4, gl.FLOAT, true, size, offset_of(Render_Vertex, add))
	gl.VertexAttribIPointer(attribute_roundness_and_thickness, 1, gl.UNSIGNED_INT, size, offset_of(Render_Vertex, roundness))
	gl.VertexAttribIPointer(attribute_kind, 1, gl.UNSIGNED_INT, size, offset_of(Render_Vertex, kind))

	for kind in Texture_Kind {
		texture_bind(target, kind)
	}

	last_sfactor: i32 = -1
	last_dfactor: i32 = -1
	last_func: i32 = -1

	// fmt.eprintln("render")

	for group, group_index in &groups {
		rect_scissor(i32(height), group.clip)
		vertice_count := group.vertex_end - group.vertex_start

		// custom bind texture
		if group.bind_slot != -1 {
			kind := 3
			gl.Uniform1i(target.shallow_uniform_sampler, i32(kind))
			gl.ActiveTexture(gl.TEXTURE0 + u32(kind))
			gl.BindTexture(gl.TEXTURE_2D, group.bind_handle)
		}

		// skip empty group
		if vertice_count != 0 {
			defer {
				last_sfactor = group.blend_sfactor
				last_dfactor = group.blend_dfactor
				last_func = group.blend_func
			}

			if last_sfactor != group.blend_sfactor || last_dfactor != group.blend_dfactor {
				gl.BlendFunc(u32(group.blend_sfactor), u32(group.blend_dfactor))
			}

			if last_func != group.blend_func {
				gl.BlendEquation(u32(group.blend_func))
				// fmt.eprintln("DIFF", gl.FUNC_SUBTRACT == group.blend_func)
			}

			// TODO use raw_data again on new master
			base := &target.vertices[0]
			root := mem.ptr_offset(base, group.vertex_start)
			gl.BufferData(gl.ARRAY_BUFFER, vertice_count * size_of(Render_Vertex), root, gl.STREAM_DRAW)

			// update uniforms
			projection := glm.mat4Ortho3d(0, f32(width), f32(height), 0, -1, 1)
			gl.UniformMatrix4fv(uniform_projection, 1, false, &projection[0][0])
			gl.Uniform4f(
				uniform_shadow_color, 
				f32(shadow_color.r) / 255,
				f32(shadow_color.g) / 255,
				f32(shadow_color.b) / 255,
				f32(shadow_color.a) / 255,
			)

			gl.DrawArrays(gl.TRIANGLES, 0, i32(vertice_count))
		}
	}

	gl.DisableVertexAttribArray(attribute_position)
	gl.DisableVertexAttribArray(attribute_uv)
	gl.DisableVertexAttribArray(attribute_color)
	gl.DisableVertexAttribArray(attribute_roundness_and_thickness)
	gl.DisableVertexAttribArray(attribute_kind)
	gl.Flush()
	sdl.GL_SwapWindow(window)
}

//////////////////////////////////////////////
// HELPERS
//////////////////////////////////////////////

@(private)
render_target_push_vertices :: proc(
	target: ^Render_Target,
	group: ^Render_Group,
	count: int,
) -> []Render_Vertex #no_bounds_check {
	old_end := group.vertex_end
	group.vertex_end += count
	target.vertex_index += count
	return target.vertices[old_end:group.vertex_end]
}

// push a clip group
render_push_clip :: proc(using target: ^Render_Target, clip_goal: RectI) {
	append(&groups, Render_Group {
		clip = clip_goal,
		vertex_start = vertex_index,	
		vertex_end = vertex_index,
		bind_slot = -1,
		blend_sfactor = gl.SRC_ALPHA,
		blend_dfactor = gl.ONE_MINUS_SRC_ALPHA,
		blend_func = gl.FUNC_ADD,
	})
}

//////////////////////////////////////////////
// RENDER PRIMITIVES
//////////////////////////////////////////////

// render_arc :: proc(
// 	target: ^Render_Target,
// 	rect: Rect, 
// 	color: Color,
// 	thickness: f32,

// 	radians: f32, // 0-PI
// 	rotation: f32, // 0-PI,
// ) {
// 	group := &target.groups[len(target.groups) - 1]
// 	vertices := render_target_push_vertices(target, group, 6)
	
// 	vertices[0].pos_xy = { rect.l, rect.t }
// 	vertices[1].pos_xy = { rect.r, rect.t }
// 	vertices[2].pos_xy = { rect.l, rect.b }
	
// 	vertices[3].pos_xy = { rect.r, rect.t }
// 	vertices[4].pos_xy = { rect.l, rect.b }
// 	vertices[5].pos_xy = { rect.r, rect.b }

// 	center_x, center_y := rect_center(rect)
// 	// real_roundness := u16(roundness)
// 	real_thickness := u16(thickness)
	
// 	for i in 0..<6 {
// 		vertices[i].uv_xy = { center_x, center_y }
// 		vertices[i].color = color
// 		vertices[i].thickness = real_thickness
// 		vertices[i].kind = .Arc
// 		vertices[i].additional = { radians, rotation }
// 	}
// }

// no
render_circle :: proc(
	target: ^Render_Target,
	x_origin, y_origin: f32,
	radius: f32,
	color: Color,
	centered := false,
) {
	group := &target.groups[len(target.groups) - 1]
	vertices := render_target_push_vertices(target, group, 6)
	
	radius := radius * 2
	x := x_origin - (centered ? radius / 2 : 0)
	y := y_origin - (centered ? radius / 2 : 0)
	xx := x + radius
	yy := y + radius
	vertices[0].pos_xy = { x, y }
	vertices[1].pos_xy = { xx, y }
	vertices[2].pos_xy = { x, yy }
	
	vertices[3].pos_xy = { xx, y }
	vertices[4].pos_xy = { x, yy }
	vertices[5].pos_xy = { xx, yy }

	center_x := x_origin + (centered ? 0 : radius / 2)
	center_y := y_origin + (centered ? 0 : radius / 2)
	
	for i in 0..<6 {
		vertices[i].uv_xy = { center_x, center_y }
		vertices[i].color = color
		vertices[i].kind = .Circle
		vertices[i].roundness = u16(radius)
	}
}

render_circle_outline :: proc(
	target: ^Render_Target,
	x_origin, y_origin: f32,
	radius: f32,
	thickness: f32,
	color: Color,
	centered := false,
) {
	group := &target.groups[len(target.groups) - 1]
	vertices := render_target_push_vertices(target, group, 6)
	
	radius := radius * 2
	x := x_origin - (centered ? radius / 2 : 0)
	y := y_origin - (centered ? radius / 2 : 0)
	xx := f32(x) + radius
	yy := f32(y) + radius
	vertices[0].pos_xy = { x, y }
	vertices[1].pos_xy = { xx, y }
	vertices[2].pos_xy = { x, yy }
	
	vertices[3].pos_xy = { xx, y }
	vertices[4].pos_xy = { x, yy }
	vertices[5].pos_xy = { xx, yy }

	center_x := x_origin + (centered ? 0 : radius / 2)
	center_y := y_origin + (centered ? 0 : radius / 2)
	
	for i in 0..<6 {
		vertices[i].uv_xy = { center_x, center_y }
		vertices[i].color = color
		vertices[i].kind = .Circle_Outline
		vertices[i].roundness = u16(radius)
		vertices[i].thickness = u16(thickness)
	}
}

// no
render_rect :: proc(
	target: ^Render_Target,
	rect: RectI, 
	color: Color,
	roundness: int = 0,
) {
	render_rect_outline(target, rect, color, roundness, 0)
}

render_rect_outline :: proc(
	target: ^Render_Target,
	rect: RectI,
	color: Color,
	roundness: int = ROUNDNESS,
	thickness: int = LINE_WIDTH,
) #no_bounds_check {
	group := &target.groups[len(target.groups) - 1]
	vertices := render_target_push_vertices(target, group, 6)
	
	vertices[0].pos_xy = { f32(rect.l), f32(rect.t) }
	vertices[1].pos_xy = { f32(rect.r), f32(rect.t) }
	vertices[2].pos_xy = { f32(rect.l), f32(rect.b) }
	vertices[5].pos_xy = { f32(rect.r), f32(rect.b) }

	vertices[3] = vertices[1]
	vertices[4] = vertices[2]

	center_x, center_y := rect_center(rect)
	real_roundness := u16(roundness)
	real_thickness := u16(thickness)
	
	for i in 0..<6 {
		vertices[i].uv_xy = { center_x, center_y }
		vertices[i].color = color
		vertices[i].roundness = real_roundness
		vertices[i].thickness = real_thickness
		vertices[i].kind = .Rectangle
	}
}

render_underline :: proc(
	target: ^Render_Target,
	r: RectI,
	color: Color,
	line_width: int = LINE_WIDTH,
) {
	r := r
	r.t = r.b - line_width
	render_rect(target, r, color, 0)
}

render_drop_shadow :: proc(
	target: ^Render_Target,
	r: RectI,
	color: Color,
	roundness: int = ROUNDNESS,
) {
	group := &target.groups[len(target.groups) - 1] 
	vertices := render_target_push_vertices(target, group, 6)
	r := r
	r = rect_margin(r, -DROP_SHADOW)

	vertices[0].pos_xy = { f32(r.l), f32(r.t) }
	vertices[1].pos_xy = { f32(r.r), f32(r.t) }
	vertices[2].pos_xy = { f32(r.l), f32(r.b) }
	vertices[5].pos_xy = { f32(r.r), f32(r.b) }

	vertices[3] = vertices[1]
	vertices[4] = vertices[2]

	center_x, center_y := rect_center(r)
	real_roundness := u16(roundness)
	
	for i in 0..<6 {
		vertices[i].uv_xy = { center_x, center_y }
		vertices[i].color = color
		vertices[i].roundness = real_roundness
		vertices[i].kind = .Drop_Shadow
	}
}

//////////////////////////////////////////////
// TEXTURE
//////////////////////////////////////////////

texture_generate_from_png :: proc(
	target: ^Render_Target,
	kind: Texture_Kind, 
	data: []byte, 
	text: string,
	mode := i32(gl.CLAMP_TO_EDGE),
	param := i32(gl.NEAREST),
) -> (res: ^image.Image) {
	err: image.Error
	res, err = png.load_from_bytes(data)
	
	if err != nil {
		log.error("RENDERER: image loading failed for", kind)
	}

	builder := strings.builder_make(0, 32, context.temp_allocator)
	strings.write_string(&builder, "u_sampler")
	strings.write_string(&builder, text)
	strings.write_byte(&builder, '\x00')
	combined_name := strings.unsafe_string_to_cstring(strings.to_string(builder))
	location := gl.GetUniformLocation(target.shader_program, combined_name)

	target.textures[kind] = Render_Texture {
		data = raw_data(res.pixels.buf),
		width = i32(res.width),
		height = i32(res.height),
		format_a = gl.RGBA8,
		format_b = gl.RGBA,
		image = res,
		uniform_sampler = location,
	}

	texture_generate(target, kind, mode, param)
	return
}

@(private)
texture_generate :: proc(
	target: ^Render_Target, 
	kind: Texture_Kind, 
	mode := i32(gl.CLAMP_TO_EDGE),
	param := i32(gl.NEAREST),
) {
	texture := &target.textures[kind]
	using texture 

	// when called multiple times
	if handle != 0 {
		gl.DeleteTextures(1, &handle)
		handle = 0
	}

	gl.GenTextures(1, &handle)
	gl.BindTexture(gl.TEXTURE_2D, handle)

	// gl.PixelStorei(gl.UNPACK_ALIGNMENT, 1) 
	gl.TexImage2D(
		gl.TEXTURE_2D, 
		0,
		format_a,
		width, 
		height, 
		0, 
		format_b, 
		gl.UNSIGNED_BYTE, 
		data,
	)
	gl.TexParameteri(gl.TEXTURE_2D, gl.TEXTURE_WRAP_S, mode)
	gl.TexParameteri(gl.TEXTURE_2D, gl.TEXTURE_WRAP_T, mode)
	gl.TexParameteri(gl.TEXTURE_2D, gl.TEXTURE_MIN_FILTER, param)
	gl.TexParameteri(gl.TEXTURE_2D, gl.TEXTURE_MAG_FILTER, param)
	
	gl.BindTexture(gl.TEXTURE_2D, 0)
	return
}

// update the full texture 
texture_update :: proc(using texture: ^Render_Texture) {
	gl.BindTexture(gl.TEXTURE_2D, handle)
	gl.TexImage2D(
		gl.TEXTURE_2D, 
		0, 
		format_a, 
		width, 
		height, 
		0, 
		format_b, 
		gl.UNSIGNED_BYTE, 
		data,
	)
	gl.BindTexture(gl.TEXTURE_2D, 0)
}

// NOTE ASSUMING RGBA
texture_update_handle :: proc(
	handle: u32,
	data: ^byte,
	width: int,
	height: int,
) {
	gl.BindTexture(gl.TEXTURE_2D, handle)
	gl.TexImage2D(
		gl.TEXTURE_2D, 
		0, 
		gl.RGBA8, 
		i32(width), 
		i32(height), 
		0, 
		gl.RGBA, 
		gl.UNSIGNED_BYTE, 
		data,
	)
	gl.BindTexture(gl.TEXTURE_2D, 0)		
}

// NOTE assumess the correct GL context to be set
texture_update_subimage :: proc(
	texture: ^Render_Texture,
	rect: [4]f32,
	data: rawptr,
) {
	// log.info("RENDERER: Update subimage")
	w := rect[2] - rect[0]
	h := rect[3] - rect[1]

	// Push old values
	alignment, rowLength, skipPixels, skipRows: i32
	gl.GetIntegerv(gl.UNPACK_ALIGNMENT, &alignment)
	gl.GetIntegerv(gl.UNPACK_ROW_LENGTH, &rowLength)
	gl.GetIntegerv(gl.UNPACK_SKIP_PIXELS, &skipPixels)
	gl.GetIntegerv(gl.UNPACK_SKIP_ROWS, &skipRows)

	gl.BindTexture(gl.TEXTURE_2D, texture.handle)

	gl.PixelStorei(gl.UNPACK_ALIGNMENT, 1)
	gl.PixelStorei(gl.UNPACK_ROW_LENGTH, texture.width)
	gl.PixelStorei(gl.UNPACK_SKIP_PIXELS, i32(rect[0]))
	gl.PixelStorei(gl.UNPACK_SKIP_ROWS, i32(rect[1]))

	gl.TexSubImage2D(gl.TEXTURE_2D, 0, i32(rect[0]), i32(rect[1]), i32(w), i32(h), gl.RED, gl.UNSIGNED_BYTE, data)

	// Pop old values
	gl.PixelStorei(gl.UNPACK_ALIGNMENT, alignment)
	gl.PixelStorei(gl.UNPACK_ROW_LENGTH, rowLength)
	gl.PixelStorei(gl.UNPACK_SKIP_PIXELS, skipPixels)
	gl.PixelStorei(gl.UNPACK_SKIP_ROWS, skipRows)  	
}

texture_bind :: proc(target: ^Render_Target, kind: Texture_Kind) {
	texture := &target.textures[kind]
	using texture

	gl.Uniform1i(uniform_sampler, i32(kind))
	gl.ActiveTexture(gl.TEXTURE0 + u32(kind))
	gl.BindTexture(gl.TEXTURE_2D, handle)
}

texture_image :: proc(target: ^Render_Target, kind: Texture_Kind) -> ^image.Image #no_bounds_check {
	assert(kind != .Fonts)
	return target.textures[kind].image
}

texture_destroy :: proc(using texture: ^Render_Texture) {
	if image != nil {
		png.destroy(image)
	}
}

//////////////////////////////////////////////
// Shallow Texture
//////////////////////////////////////////////

shallow_texture_init :: proc(img: ^image.Image) -> (handle: u32) {
	gl.GenTextures(1, &handle)
	gl.BindTexture(gl.TEXTURE_2D, handle)
	defer gl.BindTexture(gl.TEXTURE_2D, 0)

	// gl.PixelStorei(gl.UNPACK_ALIGNMENT, 1) 
	// try loading the correct format
	// log.info("loading ")
	format := u32(img.channels == 4 ? gl.RGBA : gl.RGB)

	gl.TexImage2D(
		gl.TEXTURE_2D,
		0,
		gl.RGBA8,
		i32(img.width), 
		i32(img.height), 
		0, 
		format,
		gl.UNSIGNED_BYTE, 
		raw_data(img.pixels.buf),
	)

	mode := i32(gl.CLAMP_TO_EDGE)
	gl.TexParameteri(gl.TEXTURE_2D, gl.TEXTURE_WRAP_S, mode)
	gl.TexParameteri(gl.TEXTURE_2D, gl.TEXTURE_WRAP_T, mode)
	gl.TexParameteri(gl.TEXTURE_2D, gl.TEXTURE_MIN_FILTER, gl.LINEAR)
	gl.TexParameteri(gl.TEXTURE_2D, gl.TEXTURE_MAG_FILTER, gl.LINEAR)
	return
}

shallow_texture_init_data :: proc(
	data: ^byte, 
	width: int,
	height: int,
	channels: int = 4,
) -> (handle: u32) {
	gl.GenTextures(1, &handle)
	gl.BindTexture(gl.TEXTURE_2D, handle)
	defer gl.BindTexture(gl.TEXTURE_2D, 0)

	format := u32(channels == 4 ? gl.RGBA : gl.RGB)

	gl.TexImage2D(
		gl.TEXTURE_2D,
		0,
		gl.RGBA8,
		i32(width), 
		i32(height), 
		0, 
		format,
		gl.UNSIGNED_BYTE, 
		data,
	)

	mode := i32(gl.CLAMP_TO_EDGE)
	gl.TexParameteri(gl.TEXTURE_2D, gl.TEXTURE_WRAP_S, mode)
	gl.TexParameteri(gl.TEXTURE_2D, gl.TEXTURE_WRAP_T, mode)
	gl.TexParameteri(gl.TEXTURE_2D, gl.TEXTURE_MIN_FILTER, gl.LINEAR)
	gl.TexParameteri(gl.TEXTURE_2D, gl.TEXTURE_MAG_FILTER, gl.LINEAR)
	return
}

//////////////////////////////////////////////
// GLYPH
//////////////////////////////////////////////

// rendered_glyph_rect :: proc(info: ^Render_Info, codepoint_offset: int) -> (res: RectF) {
// 	index := info.vertex_start + codepoint_offset * 6
// 	v0 := info.target.vertices[index + 0]
// 	v1 := info.target.vertices[index + 1]
// 	v2 := info.target.vertices[index + 2]
// 	res.l = v0.pos_xy.x
// 	res.r = v1.pos_xy.x
// 	res.t = v0.pos_xy.y
// 	res.b = v2.pos_xy.y
// 	return
// }

// render a quad from the fontstash texture atlas
render_glyph_quad :: proc(
	target: ^Render_Target, 
	group: ^Render_Group, 
	state: ^fontstash.State,
	q: ^fontstash.Quad,
) {
	v := render_target_push_vertices(target, group, 6)
	v[0].uv_xy = { q.s0, q.t0 }
	v[1].uv_xy = { q.s1, q.t0 }
	v[2].uv_xy = { q.s0, q.t1 }
	v[5].uv_xy = { q.s1, q.t1 }

	v[0].pos_xy = { q.x0, q.y0 }
	v[1].pos_xy = { q.x1, q.y0 }
	v[2].pos_xy = { q.x0, q.y1 }
	v[5].pos_xy = { q.x1, q.y1 }

	v[3] = v[1]
	v[4] = v[2]

	for vertex in &v {
		vertex.color = state.color
		vertex.kind = .Glyph
	}
}

// render string offset to alignment
render_string_rect :: proc(
	target: ^Render_Target,
	rect: RectI,
	text: string,
) -> f32 {
	ctx := &gs.fc
	group := &target.groups[len(target.groups) - 1]
	state := fontstash.__getState(&gs.fc)

	x: f32
	y: f32
	switch state.ah {
		case .LEFT: { x = f32(rect.l) }
		case .CENTER: { 
			x = f32(rect.l) + rect_widthf_halfed(rect)
		}
		case .RIGHT: { x = f32(rect.r) }
	}
	switch state.av {
		case .TOP: { y = f32(rect.t) }
		case .MIDDLE: { 
			y = f32(rect.t) + rect_heightf_halfed(rect) 
		}
		case .BASELINE: { y = f32(rect.t) }
		case .BOTTOM: { y = f32(rect.b) }
	}

	iter := fontstash.TextIterInit(&gs.fc, x, y, text)
	q: fontstash.Quad

	for fontstash.TextIterNext(&gs.fc, &iter, &q) {
		render_glyph_quad(target, group, state, &q)
	}

  return iter.nextx
}

// render a string at arbitrary xy
render_string :: proc(
	target: ^Render_Target,
	x, y: int,
	text: string,
) -> f32 {
	group := &target.groups[len(target.groups) - 1]
	state := fontstash.__getState(&gs.fc)
	iter := fontstash.TextIterInit(&gs.fc, f32(x), f32(y), text)
	q: fontstash.Quad

	for fontstash.TextIterNext(&gs.fc, &iter, &q) {
		render_glyph_quad(target, group, state, &q)
	}

	return iter.nextx
}

render_icon :: proc(
	target: ^Render_Target,
	x, y: f32,
	icon: Icon,
) -> f32 {
	ctx := &gs.fc
	state := fontstash.__getState(ctx)
	group := &target.groups[len(target.groups) - 1]
	font := fontstash.__getFont(ctx, state.font)
	isize := i16(state.size * 10)
	scale := fontstash.__getPixelHeightScale(font, f32(isize / 10))

	// get glyph codepoint manually	
	codepoint := rune(icon)
	glyph, ok := fontstash.__getGlyph(ctx, font, codepoint, isize, 0)
	q: fontstash.Quad
	x_origin := x
	x := x
	y := y

	if ok {
		fontstash.__getQuad(ctx, font, -1, glyph, scale, state.spacing, &x, &y, &q)
		render_glyph_quad(target, group, state, &q)
	}

	return 0
}

render_icon_rect :: proc(
	target: ^Render_Target,
	rect: RectI,
	icon: Icon,
) -> f32 {
	ctx := &gs.fc
	state := fontstash.__getState(&gs.fc)
	group := &target.groups[len(target.groups) - 1]
	font := fontstash.__getFont(ctx, state.font)
	isize := i16(state.size * 10)
	scale := fontstash.__getPixelHeightScale(font, f32(isize / 10))

	x: f32
	y: f32
	switch state.ah {
		case .LEFT: { x = f32(rect.l) }
		case .CENTER: { 
			width := fontstash.CodepointWidth(font, rune(icon), scale)
			x = f32(rect.l) + rect_widthf_halfed(rect) - width / 2
		}
		case .RIGHT: { x = f32(rect.r) }
	}
	switch state.av {
		case .TOP: { y = f32(rect.t) }
		case .MIDDLE: { y = f32(rect.t) + rect_heightf_halfed(rect) }
		case .BASELINE: { y = f32(rect.t) }
		case .BOTTOM: { y = f32(rect.b) }
	}

	y += fontstash.__getVerticalAlign(ctx, font, state.av, isize)

	// get glyph codepoint manually	
	codepoint := rune(icon)
	glyph, ok := fontstash.__getGlyph(ctx, font, codepoint, isize, 0)
	q: fontstash.Quad

	if ok {
		fontstash.__getQuad(ctx, font, -1, glyph, scale, state.spacing, &x, &y, &q)
		render_glyph_quad(target, group, state, &q)
	}

  return q.x1 - q.x0
}

render_texture_from_kind :: proc(
	target: ^Render_Target,
	kind: Texture_Kind,
	r: RectI,
	color := WHITE,
) #no_bounds_check {
	group := &target.groups[len(target.groups) - 1]	
	vertices := render_target_push_vertices(target, group, 6)
	
	vertices[0] = { pos_xy = { f32(r.l), f32(r.t) }, uv_xy = { 0, 0 }}
	vertices[1] = { pos_xy = { f32(r.r), f32(r.t) }, uv_xy = { 1, 0 }}
	vertices[2] = { pos_xy = { f32(r.l), f32(r.b) }, uv_xy = { 0, 1 }}
	vertices[5] = { pos_xy = { f32(r.r), f32(r.b) }, uv_xy = { 1, 1 }}

	vertices[3] = vertices[1]
	vertices[4] = vertices[2]

	wanted_kind := Render_Kind(int(kind) - 1 + int(Render_Kind.SV))
	width := u16(rect_width(r))
	height := u16(rect_height(r))

	for i in 0..<6 {
		vertices[i].color = color
		vertices[i].roundness = width
		vertices[i].thickness = height
		vertices[i].kind = wanted_kind
	}
}

render_texture_from_handle :: proc(
	target: ^Render_Target,
	handle: u32,
	r: RectI,
	color := WHITE,
) #no_bounds_check {
	group := &target.groups[len(target.groups) - 1]	
	group.bind_handle = handle
	group.bind_slot = 0

	vertices := render_target_push_vertices(target, group, 6)
	
	vertices[0] = { pos_xy = { f32(r.l), f32(r.t) }, uv_xy = { 0, 0 }}
	vertices[1] = { pos_xy = { f32(r.r), f32(r.t) }, uv_xy = { 1, 0 }}
	vertices[2] = { pos_xy = { f32(r.l), f32(r.b) }, uv_xy = { 0, 1 }}
	vertices[5] = { pos_xy = { f32(r.r), f32(r.b) }, uv_xy = { 1, 1 }}

	vertices[3] = vertices[1]
	vertices[4] = vertices[2]

	wanted_kind := Render_Kind.Texture
	width := u16(rect_width(r))
	height := u16(rect_height(r))

	for i in 0..<6 {
		vertices[i].color = color
		vertices[i].roundness = width
		vertices[i].thickness = height
		vertices[i].kind = wanted_kind
	}
}

render_sine :: proc(
	target: ^Render_Target,
	r: RectI,
	color: Color,
) {
	group := &target.groups[len(target.groups) - 1]	
	vertices := render_target_push_vertices(target, group, 6)
	
	vertices[0] = { pos_xy = { f32(r.l), f32(r.t) }, uv_xy = { 0, 0 }}
	vertices[1] = { pos_xy = { f32(r.r), f32(r.t) }, uv_xy = { 1, 0 }}
	vertices[2] = { pos_xy = { f32(r.l), f32(r.b) }, uv_xy = { 0, 1 }}
	vertices[5] = { pos_xy = { f32(r.r), f32(r.b) }, uv_xy = { 1, 1 }}

	vertices[3] = vertices[1]
	vertices[4] = vertices[2]
	// center_x, center_y := rect_center(r)
	center_x, center_y := f32(r.l), f32(r.t)

	for i in 0..<6 {
		vertices[i].color = color
		vertices[i].uv_xy = { center_x, center_y }
		// vertices[i].roundness = width
		// vertices[i].thickness = height
		vertices[i].kind = .Sine
	}		
}

// paint children, dont use this yourself
render_element_clipped :: proc(target: ^Render_Target, element: ^Element) {
	// skip hidden element
	if .Hide in element.flags {
		return
	}

	if rect_invalid(element.clip) {
		return
	}

	// do default clipping when element doesnt expose clip event
	clip := element.clip
	element_message(element, .Custom_Clip, 0, &clip)
	render_push_clip(target, clip)

	if element_message(element, .Paint_Recursive) != 0 {
		return
	}

	temp := element_children_sorted_or_unsorted(element)

	// for i := len(temp) - 1; i >= 0; i -= 1 {
	// 	child := temp[i]

	for child in temp {
		render_element_clipped(target, child)
		
		if child.window.focused == child {
			render_rect_outline(target, child.bounds, theme.text_good)
		}
	}
}

Rendered_Glyph :: struct {
	vertices: []Render_Vertex,
	x, y: f32,
	codepoint: rune,
}

// render a quad from the fontstash texture atlas
render_glyph_quad_store :: proc(
	target: ^Render_Target, 
	group: ^Render_Group, 
	state: ^fontstash.State,
	q: ^fontstash.Quad,
	rglyph: ^Rendered_Glyph,
) {
	v := render_target_push_vertices(target, group, 6)
	v[0].uv_xy = { q.s0, q.t0 }
	v[1].uv_xy = { q.s1, q.t0 }
	v[2].uv_xy = { q.s0, q.t1 }
	v[5].uv_xy = { q.s1, q.t1 }

	v[0].pos_xy = { q.x0, q.y0 }
	v[1].pos_xy = { q.x1, q.y0 }
	v[2].pos_xy = { q.x0, q.y1 }
	v[5].pos_xy = { q.x1, q.y1 }

	v[3] = v[1]
	v[4] = v[2]

	for vertex in &v {
		vertex.color = state.color
		vertex.kind = .Glyph
	}

	rglyph.vertices = v
}

// render a string at arbitrary xy
render_string_store :: proc(
	target: ^Render_Target,
	x, y: int,
	text: string,
) -> f32 {
	group := &target.groups[len(target.groups) - 1]
	state := fontstash.__getState(&gs.fc)
	iter := fontstash.TextIterInit(&gs.fc, f32(x), f32(y), text)
	q: fontstash.Quad

	for fontstash.TextIterNext(&gs.fc, &iter, &q) {
		rglyph := rendered_glyph_push(iter.x, iter.y, iter.codepoint)
		render_glyph_quad_store(target, group, state, &q, rglyph)
	}

	return iter.nextx
}

// render a string at arbitrary xy
render_string_rect_store :: proc(
	target: ^Render_Target,
	rect: RectI,
	text: string,
	glyphs: ^[]Rendered_Glyph,
) -> f32 {
	ctx := &gs.fc
	group := &target.groups[len(target.groups) - 1]
	state := fontstash.__getState(&gs.fc)

	x: f32
	y: f32
	switch state.ah {
		case .LEFT: { x = f32(rect.l) }
		case .CENTER: { 
			x = f32(rect.l) + rect_widthf_halfed(rect)
		}
		case .RIGHT: { x = f32(rect.r) }
	}
	switch state.av {
		case .TOP: { y = f32(rect.t) }
		case .MIDDLE: { 
			y = f32(rect.t) + rect_heightf_halfed(rect) 
		}
		case .BASELINE: { y = f32(rect.t) }
		case .BOTTOM: { y = f32(rect.b) }
	}

	iter := fontstash.TextIterInit(&gs.fc, x, y, text)
	q: fontstash.Quad

	rendered_glyph_start()
	for fontstash.TextIterNext(&gs.fc, &iter, &q) {
		rglyph := rendered_glyph_push(iter.x, iter.y, iter.codepoint)
		render_glyph_quad_store(target, group, state, &q, rglyph)
	}
	rendered_glyph_gather(glyphs)

  return iter.nextx
}

render_line :: proc(
	target: ^Render_Target,
	p0: [2]f32,
	p1: [2]f32,
	color: Color,
	line_width: int = LINE_WIDTH,
) {
	group := &target.groups[len(target.groups) - 1]
	vertices := render_target_push_vertices(target, group, 6)
	
	clip := RectI {
		int(min(p0.x, p1.x)) - line_width,
		int(max(p0.x, p1.x)) + line_width,
		int(min(p0.y, p1.y)) - line_width,
		int(max(p0.y, p1.y)) + line_width,
	}
	// fmt.eprintln(clip)

	vertices[0].pos_xy = { f32(clip.l), f32(clip.t) }
	vertices[1].pos_xy = { f32(clip.r), f32(clip.t) }
	vertices[2].pos_xy = { f32(clip.l), f32(clip.b) }
	vertices[5].pos_xy = { f32(clip.r), f32(clip.b) }

	vertices[3] = vertices[1]
	vertices[4] = vertices[2]

	for i in 0..<6 {
		vertices[i].color = color
		vertices[i].add = { p0.x, p0.y, p1.x, p1.y }
		vertices[i].thickness = u16(line_width)
		vertices[i].kind = .Segment
	}
}

// render_group_blend_reset :: proc(target: ^Render_Target) {
// 	group := &target.groups[len(target.groups) - 1]
// 	group.blend_sfactor = gl.SRC_ALPHA
// 	group.blend_dfactor = gl.ONE_MINUS_SRC_ALPHA
// }

// render_group_blend_test :: proc(
// 	target: ^Render_Target,
// 	// sfactor: i32,
// 	// dfactor: i32,
// ) {
// 	group := &target.groups[len(target.groups) - 1]
// 	group.blend_sfactor = gl.SRC_COLOR
// 	group.blend_dfactor = gl.ONE_MINUS_SRC_COLOR
// 	// group.blend_func = gl.FUNC_REVERSE_SUBTRACT
// 	group.blend_func = gl.FUNC_ADD
// }