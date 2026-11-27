tool
extends Resource

# Automated, slope- and height-aware terrain texturing for HTerrain.
#
# How it stays fast: it never raycasts and never iterates mesh nodes or
# vertices. HTerrainData already caches the terrain "mesh data" as a CPU-side
# heightmap Image (chunk meshes are just GPU views of that same data), so this
# generator reads every cell once through the cheap bulk API
# `HTerrainData.get_heights_region()` (a single Image lock + pass), computes
# per-cell weights, writes them directly into the CPU-side splat Image(s)
# using raw byte access, and uploads everything to the GPU in one
# `notify_full_change()`. Cost is O(resolution^2) with no scene traversal.
#
# Per-cell decision uses:
#  - Slope angle sampling: central differences on cached heights give a
#    terrain normal; its angle from vertical selects grass (flat) vs rock
#    (steep), with smooth blended transition bands.
#  - Height sampling: relative to the terrain vertical range, low areas get
#    sand, high flat areas get grass, and the band around the sand level gets
#    the patchy grass/sand mix.
#  - Layered value noise (FBM) perturbation so transitions look organic
#    instead of like perfect contour lines.
#
# Texture roles -> splat slots (Classic4 shaders use exactly 4 slots):
#   slot 0 = Grass                 (red channel of splatmap 0)
#   slot 1 = Patchy grass/sand mix (green channel)
#   slot 2 = Sand                  (blue channel)
#   slot 3 = Rock                  (alpha channel)
# The images bound to those slots are the terrain ground textures
# (`u_ground_albedo_bump_N` / `u_ground_normal_roughness_N`, i.e. texture set
# slot N), assigned in the HTerrain inspector. This resource can also
# auto-assign your chosen role textures into those slots (see bind_textures).

const HTerrainData = preload("../hterrain_data.gd")
const HTerrainTextureSet = preload("../hterrain_texture_set.gd")

enum Role { GRASS, PATCHY_GRASS_SAND, SAND, ROCK }

# Which splat slot each role writes to. Only change this if you know what you
# are doing (for example MultiSplat16 terrains with more than 4 textures).
export var grass_slot := 0 setget set_grass_slot
export var patchy_grass_sand_slot := 1 setget set_patchy_grass_sand_slot
export var sand_slot := 2 setget set_sand_slot
export var rock_slot := 3 setget set_rock_slot

# Optionally assign these textures to the terrain slots above when generating,
# so you can identify which texture is which directly here in the inspector.
export(bool) var bind_textures := false setget set_bind_textures
export(Texture) var grass_texture setget set_grass_texture
export(Texture) var patchy_grass_sand_texture setget set_patchy_grass_sand_texture
export(Texture) var sand_texture setget set_sand_texture
export(Texture) var rock_texture setget set_rock_texture

export(bool) var use_heights := true setget set_use_heights
export(bool) var use_slope := true setget set_use_slope

# Height thresholds are expressed as a fraction of the terrain vertical range
# (0 = lowest point, 1 = highest point), so they work on any terrain size.
export(float, 0.0, 1.0) var sand_level := 0.15 setget set_sand_level
export(float, 0.0, 1.0) var blend_level := 0.08 setget set_blend_level

# Slope angles in degrees from vertical-up. Flat (< grass_max_angle) favors
# grass/patchy/sand, steep (> rock_min_angle) favors rock, with a smooth
# transition controlled by angle_blend.
export(float, 0.0, 90.0) var grass_max_angle := 25.0 setget set_grass_max_angle
export(float, 0.0, 90.0) var rock_min_angle := 45.0 setget set_rock_min_angle
export(float, 0.0, 90.0) var angle_blend := 10.0 setget set_angle_blend

# Slope is estimated by differencing cached heights over this many cells.
# Larger values sample smoother (more natural) slopes but blur details.
export(int, 1, 32) var slope_step_cells := 2 setget set_slope_step_cells

# Organic transition noise. Amplitude is a fraction of unit weight space.
export(float, 0.0, 1.0) var noise_amplitude := 0.1 setget set_noise_amplitude
export(int, 1, 4) var noise_octaves := 3 setget set_noise_octaves
export(float, 1.0, 1024.0) var noise_scale_cells := 24.0 setget set_noise_scale_cells
export(int, -100000, 100000) var seed := 0 setget set_seed

signal progress_notified(info)


func set_grass_slot(v: int):
	grass_slot = clamp(int(v), 0, 15)
	emit_changed()

func set_patchy_grass_sand_slot(v: int):
	patchy_grass_sand_slot = clamp(int(v), 0, 15)
	emit_changed()

func set_sand_slot(v: int):
	sand_slot = clamp(int(v), 0, 15)
	emit_changed()

func set_rock_slot(v: int):
	rock_slot = clamp(int(v), 0, 15)
	emit_changed()

func set_bind_textures(v: bool):
	bind_textures = v
	emit_changed()

func set_grass_texture(v):
	grass_texture = v
	emit_changed()

func set_patchy_grass_sand_texture(v):
	patchy_grass_sand_texture = v
	emit_changed()

func set_sand_texture(v):
	sand_texture = v
	emit_changed()

func set_rock_texture(v):
	rock_texture = v
	emit_changed()

func set_use_heights(v: bool):
	use_heights = v
	emit_changed()

func set_use_slope(v: bool):
	use_slope = v
	emit_changed()

func set_sand_level(v: float):
	sand_level = clamp(v, 0.0, 1.0)
	emit_changed()

func set_blend_level(v: float):
	blend_level = max(0.0, v)
	emit_changed()

func set_grass_max_angle(v: float):
	grass_max_angle = clamp(v, 0.0, 90.0)
	emit_changed()

func set_rock_min_angle(v: float):
	rock_min_angle = clamp(v, 0.0, 90.0)
	emit_changed()

func set_angle_blend(v: float):
	angle_blend = max(0.001, v)
	emit_changed()

func set_slope_step_cells(v: int):
	slope_step_cells = clamp(int(v), 1, 32)
	emit_changed()

func set_noise_amplitude(v: float):
	noise_amplitude = clamp(v, 0.0, 1.0)
	emit_changed()

func set_noise_octaves(v: int):
	noise_octaves = clamp(int(v), 1, 4)
	emit_changed()

func set_noise_scale_cells(v: float):
	noise_scale_cells = max(1.0, v)
	emit_changed()

func set_seed(v: int):
	seed = int(v)
	emit_changed()


static func _smoothstep01(v: float) -> float:
	v = clamp(v, 0.0, 1.0)
	return v * v * (3.0 - 2.0 * v)


# Cheap deterministic hash-based value noise (no allocations per call).
static func _hash2(x: int, y: int, s: int) -> float:
	var n := x * 374761393 + y * 668265263 + s * 1442695041
	n = (n ^ (n >> 13)) * 1274126177
	n = n ^ (n >> 16)
	return float(n & 0x7fffffff) / float(0x7fffffff)


static func _value_noise(x: float, y: float, s: int) -> float:
	var xi := int(floor(x))
	var yi := int(floor(y))
	var fx := _smoothstep01(x - float(xi))
	var fy := _smoothstep01(y - float(yi))
	var a := _hash2(xi, yi, s)
	var b := _hash2(xi + 1, yi, s)
	var c := _hash2(xi, yi + 1, s)
	var d := _hash2(xi + 1, yi + 1, s)
	return lerp(lerp(a, b, fx), lerp(c, d, fx), fy)


static func _fbm(x: float, y: float, s: int, octaves: int) -> float:
	var total := 0.0
	var amp := 0.5
	var freq := 1.0
	var norm := 0.0
	for i in octaves:
		total += amp * _value_noise(x * freq, y * freq, s + i * 101)
		norm += amp
		freq *= 2.0
		amp *= 0.5
	return total / norm


# Assigns the role textures to their slots in the terrain texture set,
# creating slots if needed. Works in "Textures" mode (Classic4 shaders);
# silently skipped for texture-array modes.
func _bind_role_textures(terrain) -> void:
	if not bind_textures:
		return
	var ts = terrain.get_texture_set()
	if ts == null or ts.get_mode() != HTerrainTextureSet.MODE_TEXTURES:
		return
	var role_textures = [grass_texture, patchy_grass_sand_texture, sand_texture, rock_texture]
	var role_slots = [grass_slot, patchy_grass_sand_slot, sand_slot, rock_slot]
	var max_needed := 0
	for i in 4:
		if role_textures[i] != null:
			max_needed = max(max_needed, int(role_slots[i]) + 1)
	while ts.get_texture_count() < max_needed:
		ts.insert_slot(-1)
	for i in 4:
		if role_textures[i] != null:
			for type in HTerrainTextureSet.TYPE_COUNT:
				ts.set_texture(int(role_slots[i]), type, role_textures[i])


# Regenerates the splatmap(s). Returns true on success.
# `terrain` must be an HTerrain node whose HTerrainData has its heightmap
# loaded in RAM (which is always the case when data is assigned).
func generate(terrain) -> bool:
	if terrain == null or not terrain.has_method("get_data"):
		push_error("Auto-texturing: not an HTerrain node")
		return false
	var data = terrain.get_data()
	if data == null:
		push_error("Auto-texturing: terrain has no data loaded")
		return false

	var res := data.get_resolution()
	if res < 2:
		return false

	_emit_progress(0.0, "Reading cached heightmap...")

	# Bulk read of the whole heightmap: ONE lock, ONE pass. This is the cheap
	# cached alternative to raycasting the mesh or iterating MeshInstance data.
	var heights : PoolRealArray = data.get_heights_region(0, 0, res, res)
	if len(heights) != res * res:
		push_error("Auto-texturing: unexpected height region size")
		return false

	var sx := terrain.map_scale.x
	var sy := terrain.map_scale.y
	var sz := terrain.map_scale.z
	if sx <= 0.0:
		sx = 1.0
	if sy <= 0.0:
		sy = 1.0
	if sz <= 0.0:
		sz = 1.0

	# Terrain vertical bounds so height thresholds can be relative
	var hmin := heights[0]
	var hmax := heights[0]
	for h in heights:
		if h < hmin:
			hmin = h
		elif h > hmax:
			hmax = h
	var relief := max(hmax - hmin, 0.0001)

	var step := clamp(slope_step_cells, 1, res - 1)
	var cell_dx := float(step) * sx
	var cell_dz := float(step) * sz
	if cell_dx < 0.0001:
		cell_dx = 1.0
	if cell_dz < 0.0001:
		cell_dz = 1.0

	var sand_h := hmin + sand_level * relief
	var blend_h := max(blend_level * relief, 0.0001)

	var role_slots = [grass_slot, patchy_grass_sand_slot, sand_slot, rock_slot]
	var max_slot := 0
	for s in role_slots:
		max_slot = max(max_slot, int(s))
	var splat_maps_needed := int(ceil(float(max_slot + 1) / 4.0))
	if data.get_map_count(HTerrainData.CHANNEL_SPLAT) < splat_maps_needed:
		push_error(str("Auto-texturing needs ", splat_maps_needed,
			" splatmap(s) but the terrain only has ",
			data.get_map_count(HTerrainData.CHANNEL_SPLAT),
			". Switch shader_type to one supporting enough textures ",
			"(Classic4 = 4, MultiSplat16 = 16)."))
		return false

	_bind_role_textures(terrain)

	_emit_progress(0.05, "Writing splatmap...")

	# Lock all target splatmaps once and write raw bytes directly
	var splat_images := []
	var raws := []
	for i in splat_maps_needed:
		var im : Image = data.get_image(HTerrainData.CHANNEL_SPLAT, i)
		if im == null:
			im = Image.new()
			im.create(res, res, false, Image.FORMAT_RGBA8)
		if im.get_format() != Image.FORMAT_RGBA8 or im.get_width() != res:
			push_error("Auto-texturing: unexpected splatmap format")
			return false
		im.lock()
		splat_images.append(im)
		raws.append(im.get_data())

	# Clear existing weights so leftover textures don't linger
	for map_index in splat_maps_needed:
		var wraw : PoolByteArray = raws[map_index]
		for j in wraw.size():
			wraw[j] = 0

	var noise_amp := noise_amplitude
	var inv_noise_scale := 1.0 / max(noise_scale_cells, 1.0)
	var emit_every := maxi(res / 16, 1)

	var gslot := int(grass_slot)
	var pslot := int(patchy_grass_sand_slot)
	var sslot := int(sand_slot)
	var rslot := int(rock_slot)

	var rock_lo := rock_min_angle - angle_blend
	var rock_hi := rock_min_angle
	var grass_hi := rock_min_angle + angle_blend

	for y in res:
		var row := y * res
		# Clamp rows at borders so gradient samples stay inside the map
		var ym := maxi(y - step, 0) * res
		var yp := mini(y + step, res - 1) * res
		var ny := float(y) * inv_noise_scale

		for x in res:
			var h := heights[row + x]

			# --- Slope angle sampling from cached heights (central differences)
			var xm := maxi(x - step, 0)
			var xp := mini(x + step, res - 1)
			var gx := heights[row + xp] - heights[row + xm]
			var gz := heights[yp + x] - heights[ym + x]
			var n := Vector3(gx * sy / cell_dx, 1.0, gz * sy / cell_dz).normalized()
			var slope_deg := rad2deg(acos(clamp(n.y, -1.0, 1.0)))

			var w_grass := 0.0
			var w_patchy := 0.0
			var w_sand := 0.0
			var w_rock := 0.0

			if rock_min_angle <= grass_max_angle:
				# Degenerate config: hard boundary between grass and rock
				w_rock = _smoothstep01((slope_deg - grass_max_angle) / 0.001)
				w_grass = 1.0 - w_rock
			else:
				var flatness := 1.0
				var steepness := 0.0
				if use_slope:
					flatness = 1.0 - _smoothstep01(
						(slope_deg - grass_max_angle) / max(grass_hi - grass_max_angle, 0.001))
					steepness = _smoothstep01(
						(slope_deg - rock_lo) / max(rock_hi - rock_lo, 0.001))

				var lowliness := 0.0
				var middleness := 0.0
				var highness := 0.0
				if use_heights:
					lowliness = 1.0 - _smoothstep01((h - sand_h) / blend_h)
					highness = _smoothstep01((h - sand_h) / blend_h)
					middleness = clamp(
						1.0 - abs(h - sand_h) / max(relief * 0.5, blend_h), 0.0, 1.0)

				# Transition band near the sand level on gentle terrain:
				# this is where the patchy grass/sand mix belongs
				var band := middleness * flatness * (1.0 - steepness)

				w_grass = flatness * highness
				w_sand = (1.0 - steepness) * lowliness
				w_rock = steepness
				w_patchy = band

			# --- Organic noise perturbation (fraction of unit weight space)
			if noise_amp > 0.0001:
				var nx := float(x) * inv_noise_scale
				var n0 := (_fbm(nx, ny, seed, noise_octaves) - 0.5) * noise_amp
				var n1 := (_fbm(nx + 31.7, ny + 59.3, seed + 1, noise_octaves) - 0.5) * noise_amp
				var n2 := (_fbm(nx + 12.9, ny + 78.2, seed + 2, noise_octaves) - 0.5) * noise_amp
				var n3 := (_fbm(nx + 53.5, ny + 91.1, seed + 3, noise_octaves) - 0.5) * noise_amp
				w_grass = max(w_grass + n0, 0.0)
				w_patchy = max(w_patchy + n1, 0.0)
				w_sand = max(w_sand + n2, 0.0)
				w_rock = max(w_rock + n3, 0.0)

			var sum := w_grass + w_patchy + w_sand + w_rock
			if sum < 0.0001:
				# Fallback: pick the most plausible texture for this cell
				if use_slope and slope_deg >= rock_min_angle:
					w_rock = 1.0
				elif use_heights and h <= sand_h:
					w_sand = 1.0
				else:
					w_grass = 1.0
				sum = 1.0

			_write_weight(raws, gslot, row + x, w_grass / sum)
			_write_weight(raws, pslot, row + x, w_patchy / sum)
			_write_weight(raws, sslot, row + x, w_sand / sum)
			_write_weight(raws, rslot, row + x, w_rock / sum)

		if y % emit_every == 0:
			_emit_progress(0.05 + 0.9 * float(y) / float(res), "Writing splatmap...")

	for im in splat_images:
		im.unlock()

	_emit_progress(0.97, "Uploading to GPU...")

	# One-shot upload of all modified maps + viewer/collider refresh
	data.notify_full_change()

	_emit_progress(1.0, "Done")
	return true


static func _write_weight(raws: Array, slot: int, pixel_index: int, weight: float):
	var map_index := slot / 4
	var channel := slot % 4
	var wraw : PoolByteArray = raws[map_index]
	var offset := pixel_index * 4 + channel
	wraw[offset] = int(round(clamp(weight, 0.0, 1.0) * 255.0))


func _emit_progress(p: float, msg: String):
	emit_signal("progress_notified", {
		"progress": p,
		"message": msg,
		"finished": p >= 1.0
	})
