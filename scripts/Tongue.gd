extends Node2D
## Tongue that wraps around corners (multiple wrap points) and unwraps when line-of-sight returns.
## Godot 4.x
@export var wheel_step: float = 24.0        # пикселей за щелчок
@export var wheel_step_fast: float = 64.0   # если зажата Shift

@export var max_length: float = 380.0
@export var reel_speed: float = 320.0
@export var stiffness: float = 90.0
@export var damping: float = 6.0
@export var pull_force: float = 1200.0
@export var pivot_offset: float = 10.0
@export var pivot_min_dist: float = 6.0
@export var add_pivot_cooldown: float = 0.05
@export var unwrap_hysteresis: float = 4.0
@export_flags_2d_physics var ray_mask := 1
@export var mouth_offset: Vector2 = Vector2(6, -6)
@export var unwrap_hold_time: float = 0.2  # сколько времени подряд нужна прямая видимость
var _unwrap_accum: float = 0.0             # аккумулятор времени LOS для последней точки

@export var eat_radius: float = 22.0   # дистанция до рта, на которой убиваем врага
@export_enum("HOOK","PULL_TO_ANCHOR","PULL_TARGET_TO_FROG") var scenario := 0

var frog: RigidBody2D
var rope_renderer: Node = null
var line: Line2D = null

var target_body: Node2D = null
var target_local: Vector2 = Vector2.ZERO
var created_anchor: Node2D = null

var pivots: Array[Vector2] = []
var active := false
var rope_length: float = 0.0
var _pivot_cd := 0.0


func setup(_frog: RigidBody2D, rope_node: Node=null, fallback_line: Line2D=null) -> void:
	frog = _frog
	rope_renderer = rope_node
	line = fallback_line
	if line:
		line.clear_points()
		line.visible = false
	_set_renderer_visible(false)

func fire(target_world: Vector2) -> void:
	if frog == null:
		return
	var mouth = frog.global_position + mouth_offset
	var vec = target_world - mouth
	if vec.length() > max_length:
		vec = vec.normalized() * max_length
	var hit := _raycast(mouth, mouth + vec, [frog])
	if hit.is_empty():
		return

	var collider: Object = hit["collider"]
	var hit_pos: Vector2 = hit["position"]

	if collider is RigidBody2D or collider is StaticBody2D or collider is Node2D:
		target_body = collider as Node2D
		if collider is RigidBody2D or collider is StaticBody2D:
			target_local = (target_body as Node2D).to_local(hit_pos)
			created_anchor = null
		else:
			target_local = Vector2.ZERO
	else:
		created_anchor = Node2D.new()
		created_anchor.global_position = hit_pos
		get_tree().current_scene.add_child(created_anchor)
		target_body = created_anchor
		target_local = Vector2.ZERO

	pivots.clear()
	active = true
	_pivot_cd = 0.0
	rope_length = (hit_pos - mouth).length()
	if line:
		line.visible = true
	_set_renderer_visible(true)

func release() -> void:
	if not active:
		return
	active = false
	pivots.clear()
	_apply_points_to_renderer([] as Array[Vector2])
	if line:
		line.clear_points()
		line.visible = false
	_set_renderer_visible(false)
	if created_anchor and is_instance_valid(created_anchor):
		created_anchor.queue_free()
	target_body = null
	created_anchor = null

func set_scenario(new_mode:int) -> void:
	scenario = new_mode

func _physics_process(delta: float) -> void:
	if not active or frog == null or target_body == null:
		return

	_pivot_cd = maxf(0.0, _pivot_cd - delta)

	var mouth: Vector2 = frog.global_position + mouth_offset
	var anchor: Vector2 = target_body.to_global(target_local)

	_update_wrap_points(mouth, anchor)

	var pts: Array[Vector2] = []
	pts.append(mouth)
	for p in pivots:
		pts.append(p)
	pts.append(anchor)
	_apply_points_to_renderer(pts)   # отрисовка и для RopeSim, и для Line2D внутри


	var L := _polyline_length(pts)
	match scenario:
		0:
			pass  # HOOK: длина управляется колесиком; авто-намотки нет
		1:
			rope_length = max(0.0, rope_length - reel_speed * delta)
		2:
			rope_length = max(0.0, rope_length - reel_speed * delta)

	if L > rope_length:
		var deficit := L - rope_length
		_apply_tension_forces(pts, deficit, delta)
		# если якорь — враг и он близко ко рту — "съесть"
		if target_body and target_body.is_in_group("enemy"):
			var eat_anchor: Vector2 = (target_body as Node2D).to_global(target_local)
			var mouth_now: Vector2 = frog.global_position + mouth_offset
			if mouth_now.distance_to(eat_anchor) <= eat_radius:
				if target_body.has_method("kill"):
					target_body.call_deferred("kill")
				else:
					target_body.queue_free()
				release()
				return

		# если тянем врага и подтащили к рту — «съесть»
		if scenario == 2 and target_body is RigidBody2D and target_body.is_in_group("enemy"):
			var eat_anchor: Vector2 = (target_body as Node2D).to_global(target_local)
			if mouth.distance_to(eat_anchor) <= eat_radius:
				if target_body.has_method("kill"):
					target_body.call_deferred("kill")
				else:
					target_body.queue_free()
				release()


func _update_wrap_points(mouth: Vector2, anchor: Vector2) -> void:
	# --- добавление поворотных точек (wrap) ---
	var guard := 0
	while guard < 16:
		guard += 1
		var a: Vector2 = mouth if pivots.size() == 0 else pivots[pivots.size() - 1]

		var hit := _raycast_including_target(a, anchor, [frog, target_body])
		if hit.is_empty():
			break  # последний отрезок чистый — новых pivot не нужно

		# NB: намеренно НЕ блокируем добавление pivot по кулдауну,
		# если пересечение всё ещё есть — иначе можно «проскочить» момент
		var pos: Vector2 = hit["position"]
		var n: Vector2 = (hit["normal"] as Vector2).normalized()
		var t := Vector2(-n.y, n.x) # тангенс

		var cand1 := pos + t * pivot_offset
		var cand2 := pos - t * pivot_offset

		# Сторона, с которой есть прямая видимость до anchor
		var ok1 := _raycast_including_target(cand1, anchor, [frog, target_body]).is_empty()
		var ok2 := _raycast_including_target(cand2, anchor, [frog, target_body]).is_empty()

		var chosen := cand1
		if ok1 and not ok2:
			chosen = cand1
		elif ok2 and not ok1:
			chosen = cand2
		else:
			# Ни с одной стороны LOS нет — всё равно добавим pivot,
			# берём более удалённый от 'a' (обычно внешняя сторона)
			chosen = cand1 if a.distance_to(cand1) > a.distance_to(cand2) else cand2

		# --- депенетрация pivot наружу по нормали ---
		if true:
			var space: PhysicsDirectSpaceState2D = get_world_2d().direct_space_state
			var steps := 0
			while steps < depenetrate_max_steps:
				var pp := PhysicsPointQueryParameters2D.new()
				pp.position = chosen
				pp.collision_mask = ray_mask
				pp.collide_with_bodies = true
				pp.collide_with_areas = false
				var inside := space.intersect_point(pp, 1).size() > 0
				if not inside:
					break
				chosen += n * depenetrate_step
				steps += 1

		if pivots.size() == 0 or pivots[-1].distance_to(chosen) > pivot_min_dist:
			pivots.append(chosen)
			_pivot_cd = add_pivot_cooldown
		else:
			break

	# --- удаление поворотных точек (unwrap) с временной гистерезисом ---
	while pivots.size() > 0:
		var prev := mouth if pivots.size() == 1 else pivots[pivots.size() - 2]
		var test := _raycast_including_target(prev, anchor, [frog, target_body])

		if test.is_empty():
			_unwrap_accum += get_physics_process_delta_time()
			if _unwrap_accum >= unwrap_hold_time:
				pivots.pop_back()
				_unwrap_accum = 0.0
			else:
				break  # ждём, подтвердится ли LOS на следующих кадрах
		else:
			_unwrap_accum = 0.0
			var hit_pos: Vector2 = test["position"]
			if prev.distance_to(hit_pos) < unwrap_hysteresis:
				pivots.pop_back()
			else:
				break


func _apply_tension_forces(poly: Array, deficit: float, delta: float) -> void:
	if poly.size() < 2:
		return
	var a: Vector2 = poly[0]
	var b: Vector2 = poly[1]
	var dir: Vector2 = (b - a).normalized()
	var impulse := dir * stiffness * deficit * delta
	var v := frog.linear_velocity
	var v_along := dir * v.dot(dir)
	impulse -= v_along * damping * delta
	frog.apply_central_impulse(impulse)

	if scenario == 2 and target_body is RigidBody2D:
		var p1: Vector2 = poly[poly.size() - 2]
		var p2: Vector2 = poly[poly.size() - 1]
		var tdir := (p1 - p2).normalized()
		var imp2 := tdir * stiffness * deficit * delta
		(target_body as RigidBody2D).apply_central_impulse(imp2)

func _polyline_length(poly: Array[Vector2]) -> float:
	var L: float = 0.0
	for i in range(poly.size() - 1):
		L += (poly[i + 1] - poly[i]).length()
	return L


@export var ray_side_eps: float = 3.0    # «толщина» верёвки для проверки (пиксели)
@export var ray_start_eps: float = 0.5   # смещение старта луча вперёд (пиксели)

func _raycast(from: Vector2, to: Vector2, exclude_nodes: Array[Node]) -> Dictionary:
	var dir := to - from
	var seg_len := dir.length()
	if seg_len <= 0.0001:
		return {}
	var nd := dir / seg_len

	var space: PhysicsDirectSpaceState2D = get_world_2d().direct_space_state

	var ex: Array[RID] = []
	for n in exclude_nodes:
		if n is CollisionObject2D:
			ex.append((n as CollisionObject2D).get_rid())

	var side := Vector2(-nd.y, nd.x) * ray_side_eps
	var origins := [
		from + nd * ray_start_eps,
		from + nd * ray_start_eps + side,
		from + nd * ray_start_eps - side
	]

	var closest := {}
	var best_dist := INF

	for o in origins:
		var q := PhysicsRayQueryParameters2D.create(o, o + nd * (seg_len - ray_start_eps))
		q.exclude = ex
		q.collision_mask = ray_mask
		q.hit_from_inside = true
		q.collide_with_areas = false
		q.collide_with_bodies = true
		var hit := space.intersect_ray(q)
		if not hit.is_empty():
			var d := (hit["position"] as Vector2).distance_to(o)
			if d < best_dist:
				best_dist = d
				closest = hit

	return closest


@export var end_shrink_eps: float = 2.0  # укоротить луч перед якорем, пиксели

func _raycast_including_target(from: Vector2, to: Vector2, exclude_nodes: Array[Node]) -> Dictionary:
	# как _raycast, но НЕ исключаем target_body и укорачиваем луч на end_shrink_eps
	var space: PhysicsDirectSpaceState2D = get_world_2d().direct_space_state
	
	var dir := to - from
	var seg_len := dir.length()
	if seg_len <= 0.0001:
		return {}
	var nd := dir / seg_len


	# исключаем только то, что реально надо (обычно — лягушку)
	var ex: Array[RID] = []
	for n in exclude_nodes:
		if n is CollisionObject2D:
			ex.append((n as CollisionObject2D).get_rid())

	# «толстый» веер из 3-х лучей
	var side := Vector2(-nd.y, nd.x) * ray_side_eps
	var origins := [
		from + nd * ray_start_eps,
		from + nd * ray_start_eps + side,
		from + nd * ray_start_eps - side
	]

	var closest := {}
	var best_dist := INF
	for o in origins:
		var q := PhysicsRayQueryParameters2D.create(o, o + nd * (seg_len - ray_start_eps))
		q.exclude = ex
		q.collision_mask = ray_mask
		q.hit_from_inside = true
		q.collide_with_bodies = true
		q.collide_with_areas = false
		var hit := space.intersect_ray(q)
		if not hit.is_empty():
			var d := (hit["position"] as Vector2).distance_to(o)
			if d < best_dist:
				best_dist = d
				closest = hit
	return closest


func _apply_points_to_renderer(pts: Array[Vector2]) -> void:
	# Выберем, к какому узлу приводить в локальные: RopeSim если есть, иначе Line2D
	var ref_node: Node2D = null
	if rope_renderer is Node2D:
		ref_node = rope_renderer as Node2D
	elif line is Node2D:
		ref_node = line as Node2D

	var local_pts: Array[Vector2] = []
	if ref_node != null:
		for p in pts:
			local_pts.append(ref_node.to_local(p))
	else:
		local_pts = pts.duplicate()

	var packed := PackedVector2Array(local_pts)

	# --- RopeSim / кастомный рендерер ---
	if rope_renderer != null:
		if rope_renderer.has_method("set_points"):
			rope_renderer.call("set_points", packed)
			return
		if "points" in rope_renderer:
			rope_renderer.points = packed
			return
		if local_pts.size() >= 2:
			var a: Vector2 = local_pts[0]
			var b: Vector2 = local_pts[local_pts.size() - 1]
			if "start" in rope_renderer and "end" in rope_renderer:
				rope_renderer.start = a
				rope_renderer.end = b
				return
			if "a" in rope_renderer and "b" in rope_renderer:
				rope_renderer.a = a
				rope_renderer.b = b
				return

	# --- Fallback: Line2D ---
	if line != null:
		line.visible = true
		line.clear_points()
		for p in local_pts:
			line.add_point(p)



func _set_renderer_visible(v: bool) -> void:
	if rope_renderer == null:
		return
	if "visible" in rope_renderer:
		rope_renderer.visible = v

@export var depenetrate_step: float = 1.6
@export var depenetrate_max_steps: int = 8

func _point_inside_solid(p: Vector2) -> bool:
	var space: PhysicsDirectSpaceState2D = get_world_2d().direct_space_state
	var params := PhysicsPointQueryParameters2D.new()
	params.position = p
	params.collision_mask = ray_mask
	params.collide_with_areas = false
	params.collide_with_bodies = true
	var res: Array = space.intersect_point(params, 1)
	return res.size() > 0



func _push_out(point: Vector2, normal: Vector2) -> Vector2:
	var p := point
	var n := normal.normalized()
	for i in range(depenetrate_max_steps):
		if not _point_inside_solid(p):
			return p
		p += n * depenetrate_step
	return p

func _adjust_length(delta_len: float) -> void:
	if not active:
		return
	rope_length = clamp(rope_length + delta_len, 0.0, max_length)

func _unhandled_input(event: InputEvent) -> void:
	if not active:
		return
	if event is InputEventMouseButton and event.pressed:
		var step := wheel_step
		if event.shift_pressed:
			step = wheel_step_fast
		match event.button_index:
			MOUSE_BUTTON_WHEEL_UP:
				_adjust_length(-step)   # укоротить язык, подтянуться
			MOUSE_BUTTON_WHEEL_DOWN:
				_adjust_length(step)    # отпустить язык, добавить слабину
