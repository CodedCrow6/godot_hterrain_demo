tool
extends Resource

# Generates an HTerrain classic 4 splatmap from cached height data.
# It never raycasts or iterates mesh nodes: each terrain cell is read once from
# HTerrainData's CPU-side height Image and the result is written directly to the
# CPU-side splat Image, then uploaded in one operation.

const HTerrainData = preload("../hterrain_data.gd")

export(bool) var enabled = true
export(float, -512.0, 4096.0) var sand_max_height = 8.0
export(float, 0.0, 4096.0) var sand_height_blend = 4.0
export(float, 0.0, 90.0) var grass_max_slope = 18.0
export(float, 0.0, 90.0) var rock_min_slope = 35.0
export(float, 0.0, 45.0) var slope_blend = 8.0
export(float, 0.0, 20.0) var sample_distance = 1.0
export(float, 0.0, 1.0) var noise_strength = 0.12
export(float, 0.0, 1.0) var mix_grass_sand_strength = 0.35

func _smoothstep01(v: float) -> float:
	v = clamp(v, 0.0, 1.0)
	return v * v * (3.0 - 2.0 * v)

# Stable, cheap hash noise. It avoids a random/time component and remains
# deterministic between editor runs.
func _hash2(x: int, y: int) -> float:
	var n := int(x) * 374761393 + int(y) * 668265263
	n = (n ^ (n >> 13)) * 1274126177
	return float(n & 0x7fffffff) / float(0x7fffffff)

func generate(terrain) -> bool:
	if terrain == null or not terrain.has_method("get_data"):
		return false
	var data = terrain.get_data()
	if data == null:
		return false

	var height_image: Image = data.get_image(HTerrainData.CHANNEL_HEIGHT)
	if height_image == null:
		return false
	if data.get_map_count(HTerrainData.CHANNEL_SPLAT) == 0:
		return false

	var splat_image: Image = data.get_image(HTerrainData.CHANNEL_SPLAT)
	if splat_image == null:
		splat_image = Image.new()
		splat_image.create(data.get_resolution(), data.get_resolution(), false, Image.FORMAT_RGBA8)

	var res := data.get_resolution()
	var sx: float = terrain.map_scale.x
	var sy: float = terrain.map_scale.y
	var sz: float = terrain.map_scale.z
	if sx <= 0.0:
		sx = 1.0
	if sy <= 0.0:
		sy = 1.0
	if sz <= 0.0:
		sz = 1.0

	height_image.lock()
	splat_image.lock()

	for y in range(res):
		for x in range(res):
			var h := height_image.get_pixel(x, y).r * sy

			var xm := max(x - int(sample_distance), 0)
			var xp := min(x + int(sample_distance), res - 1)
			var ym := max(y - int(sample_distance), 0)
			var yp := min(y + int(sample_distance), res - 1)

			var hx := height_image.get_pixel(xp, y).r * sy - height_image.get_pixel(xm, y).r * sy
			var hz := height_image.get_pixel(x, yp).r * sy - height_image.get_pixel(x, ym).r * sy
			var dx := float(xp - xm) * sx
			var dz := float(yp - ym) * sz
			if dx <= 0.0001:
				dx = 1.0
			if dz <= 0.0001:
				dz = 1.0

			var tangent_x := Vector3(dx, hx, 0.0)
			var tangent_z := Vector3(0.0, hz, dz)
			var normal := tangent_x.cross(tangent_z).normalized()
			var slope := rad2deg(acos(clamp(normal.dot(Vector3.UP), -1.0, 1.0)))

			# Low and gentle = sand. High and gentle = grass.
			var sand_height_weight := 1.0 - _smoothstep01((h - sand_max_height) / max(sand_height_blend, 0.001))
			var grass_height_weight := 1.0 - sand_height_weight

			# Flat-to-gentle slopes favor grass; steeper slopes favor rock.
			var grass_slope_weight := 1.0 - _smoothstep01((slope - grass_max_slope) / max(slope_blend, 0.001))
			var rock_weight := _smoothstep01((slope - rock_min_slope) / max(slope_blend, 0.001))
			var grass_weight := grass_slope_weight * grass_height_weight
			var sand_weight := (1.0 - rock_weight) * sand_height_weight

			# Patchy grass/sand is a localized transition band, not a random global mix.
			var band_distance := abs(h - sand_max_height) / max(sand_height_blend, 0.001)
			var transition_height := 1.0 - _smoothstep01(band_distance)
			var noise := _hash2(x, y) * 2.0 - 1.0
			var patch_mask := clamp(transition_height * mix_grass_sand_strength * (0.55 + 0.45 * noise), 0.0, 1.0)
			var patch_weight := patch_mask * (1.0 - rock_weight)

			# Remove patch weight from grass and sand before assigning all four weights.
			grass_weight *= 1.0 - patch_weight * 0.5
			sand_weight *= 1.0 - patch_weight * 0.5

			var n := (noise_strength * 2.0) * (_hash2(x * 3 + 17, y * 5 - 11) - 0.5)
			rock_weight = clamp(rock_weight + n * rock_weight, 0.0, 1.0)

			var sum := grass_weight + patch_weight + sand_weight + rock_weight
			if sum <= 0.0001:
				grass_weight = 1.0
				sum = 1.0

			var r := grass_weight / sum
			var g := patch_weight / sum
			var b := sand_weight / sum
			var a := rock_weight / sum

			splat_image.set_pixel(x, y, Color(r, g, b, a))

	height_image.unlock()
	splat_image.unlock()

	data.notify_full_change()
	if terrain.has_method("update_collider"):
		terrain.update_collider()
	return true
