extends Node2D
"""
UNIFIED TONGUE SYSTEM
- Увеличенная длина языка
- Многократное обворачивание вокруг препятствий
- Правильное втягивание вместо исчезновения
- Исправленные механики выпуска языка
- Исправленный баг с направлением при прыжке
- Поддержка прикрепления к точкам
"""

# -------- параметры поведения --------
@export var max_length: float = 3000.0                # увеличенная дальность выстрела
@export var reel_speed: float = 300.0                 # скорость подмотки
@export var stiffness: float = 120.0                  # жёсткость пружин
@export var damping: float = 12.0                     # затухание пружин
@export var pull_force: float = 3500.0                # сила притягивания
@export var break_tension: float = 300.0              # порог на разрыв
@export_flags_2d_physics var ray_mask := 3            # слои для обнаружения препятствий
@export var mouth_offset: Vector2 = Vector2(6, -6)    # точка выхода языка

# -------- параметры физики --------
@export var tongue_extension_speed: float = 1500.0    # скорость выстрела языка
@export var tongue_retraction_speed: float = 1200.0   # скорость втягивания языка
@export var tongue_acceleration: float = 3500.0       # ускорение языка
@export var tongue_width: float = 5.0                 # толщина языка

# -------- параметры сегментов --------
@export var num_segments: int = 12                    # увеличено количество сегментов
@export var segment_length: float = 0.6               # длина сегмента
@export var segment_gravity_scale: float = 0.8        # гравитация для сегментов
@export var segment_linear_damp: float = 0.6          # затухание сегментов

# -------- параметры обворачивания --------
@export var pivot_min_dist: float = 5.0               # минимальная дистанция между точками
@export var unwrap_hysteresis: float = 8.0            # допуск при разворачивании
@export var add_pivot_cooldown: float = 0.01          # интервал между точками
@export var max_wrap_points: int = 10                 # максимальное количество точек обворачивания

# -------- ссылки --------
var frog: RigidBody2D
var line: Line2D = null

# -------- рабочие объекты --------
var target_body: Node2D = null
var pivots: Array[StaticBody2D] = []
var joints: Array[DampedSpringJoint2D] = []
var active: bool = false
var _pivot_cd: float = 0.0

# -------- физические сегменты --------
var segments: Array[RigidBody2D] = []
var segment_joints: Array[Joint2D] = []
var tip_segment: RigidBody2D = null

# -------- переменные состояния --------
var tongue_current_length: float = 0.0
var tongue_target_length: float = 0.0
var tongue_velocity: float = 0.0
var tongue_state: String = "retracted"  # "retracted", "extending", "attached", "retracting"
var tongue_target_position: Vector2 = Vector2.ZERO

func _ready() -> void:
	# Включаем физическую обработку
	set_physics_process(true)
	
	# If this is a hook point, draw its visual
	if name.begins_with("HookPoint"):
		_draw_hook_point_visual()

func setup(_frog: RigidBody2D, rope_node: Node=null, fallback_line: Line2D=null) -> void:
	frog = _frog
	
	# Создаем визуализацию языка
	line = Line2D.new()
	line.name = "TongueVisual"
	line.width = tongue_width
	line.default_color = Color(1.0, 0.3, 0.4, 1.0)  # красновато-розовый цвет
	line.set_as_top_level(true)
	line.visible = false
	add_child(line)

func fire(target_pos: Vector2) -> void:
	# Проверяем, можно ли выпустить язык
	if active or tongue_state != "retracted":
		return
	
	if not is_instance_valid(frog):
		return
	
	var mouth_world: Vector2 = frog.global_position + mouth_offset
	var to_vec: Vector2 = target_pos - mouth_world
	var distance: float = to_vec.length()
	
	# Ограничиваем длину языка
	if distance > max_length:
		to_vec = to_vec.normalized() * max_length
		distance = max_length

	# Начинаем выстрел языка
	tongue_target_position = mouth_world + to_vec
	tongue_target_length = distance
	tongue_current_length = 0.0
	tongue_velocity = 0.0
	tongue_state = "extending"
	active = true
	_pivot_cd = 0.0
	
	# Показываем визуалы
	line.visible = true
	line.clear_points()
	line.add_point(mouth_world)
	line.add_point(mouth_world)

func release() -> void:
	if not active:
		return

	# Очищаем все соединения
	for j in joints:
		if is_instance_valid(j): 
			j.queue_free()
	joints.clear()

	for p in pivots:
		if is_instance_valid(p): 
			p.queue_free()
	pivots.clear()

	if is_instance_valid(target_body) and target_body is StaticBody2D:
		target_body.queue_free()
	target_body = null

	# Сбрасываем состояние
	active = false
	tongue_state = "retracted"
	tongue_current_length = 0.0
	tongue_target_length = 0.0
	tongue_velocity = 0.0
	
	# Скрываем визуалы
	line.clear_points()
	line.visible = false

func _physics_process(delta: float) -> void:
	if _pivot_cd > 0.0:
		_pivot_cd -= delta

	if not active:
		return
	
	var mouth_world: Vector2 = frog.global_position + mouth_offset
	
	# Обрабатываем разные состояния языка
	match tongue_state:
		"extending":
			_update_tongue_extension(delta, mouth_world)
		"attached":
			_update_tongue_attached(delta, mouth_world)
		"retracting":
			_update_tongue_retraction(delta, mouth_world)

func _update_tongue_extension(delta: float, mouth_world: Vector2) -> void:
	# Ускоряем язык при выстреле
	tongue_velocity += tongue_acceleration * delta
	tongue_velocity = min(tongue_velocity, tongue_extension_speed)
	
	# Увеличиваем длину языка
	tongue_current_length += tongue_velocity * delta
	tongue_current_length = min(tongue_current_length, tongue_target_length)
	
	# Вычисляем текущую позицию конца языка
	var direction: Vector2 = (tongue_target_position - mouth_world).normalized()
	var current_tip_pos: Vector2 = mouth_world + direction * tongue_current_length
	
	# Проверяем столкновения с более точным рейкастом
	var hit: Dictionary = _raycast(mouth_world, current_tip_pos, [frog])
	
	if not hit.is_empty():
		# Язык коснулся препятствия
		var collider: Object = hit["collider"]
		var pos: Vector2 = hit["position"]
		var normal: Vector2 = hit.get("normal", Vector2.ZERO)
		
		# Проверяем, является ли это боковым столкновением
		var is_side_collision: bool = abs(normal.x) > abs(normal.y)
		
		# For all collisions, we should attach properly
		# Создаём якорь для любой поверхности
		if collider is RigidBody2D:
			target_body = collider as RigidBody2D
		else:
			var anchor := StaticBody2D.new()
			anchor.global_position = pos
			anchor.collision_layer = 0
			anchor.collision_mask = 0
			get_tree().current_scene.add_child(anchor)
			target_body = anchor
		
		# For side collisions, also add a pivot point for wrapping visualization
		if is_side_collision:
			# анти-спам: не вставляем точку слишком близко к существующей
			var should_add_pivot = false
			if pivots.size() == 0:
				should_add_pivot = true
			else:
				var distance_to_last_pivot = pos.distance_to(pivots[0].global_position)
				should_add_pivot = distance_to_last_pivot >= pivot_min_dist
			
			if should_add_pivot and _pivot_cd <= 0.0 and pivots.size() < max_wrap_points:
				var p := StaticBody2D.new()
				p.global_position = pos
				p.collision_layer = 0
				p.collision_mask = 0
				get_tree().current_scene.add_child(p)
				pivots.insert(0, p)
		
		tongue_state = "attached"
		tongue_current_length = mouth_world.distance_to(pos)
		_rebuild_joints()
		_pivot_cd = add_pivot_cooldown
		
		# добавляем силу прилипания
		_add_side_attachment_force(normal, pos)
		return
	
	# Обновляем визуалы
	_update_tongue_visuals(mouth_world, current_tip_pos)
	
	# Если достигли максимальной длины, начинаем втягивание
	if tongue_current_length >= tongue_target_length:
		tongue_state = "retracting"
		return
		
	# Дополнительная проверка: если язык уже достаточно длинный и мы приближаемся к цели,
	# можно перейти в состояние прикрепления заранее
	if tongue_current_length >= tongue_target_length * 0.9:
		# Проверяем, есть ли что-то прямо перед кончиком языка
		var tip_direction: Vector2 = direction
		var check_pos: Vector2 = current_tip_pos + tip_direction * 5.0
		var close_hit: Dictionary = _raycast(current_tip_pos, check_pos, [frog])
		
		if not close_hit.is_empty():
			var collider: Object = close_hit["collider"]
			var pos: Vector2 = close_hit["position"]
			var normal: Vector2 = close_hit.get("normal", Vector2.ZERO)
			
			# Создаём якорь
			if collider is RigidBody2D:
				target_body = collider as RigidBody2D
			else:
				var anchor := StaticBody2D.new()
				anchor.global_position = pos
				anchor.collision_layer = 0
				anchor.collision_mask = 0
				get_tree().current_scene.add_child(anchor)
				target_body = anchor
			
			tongue_state = "attached"
			tongue_current_length = mouth_world.distance_to(pos)
			_rebuild_joints()
			
			# добавляем силу прилипания
			_add_side_attachment_force(normal, pos)
			return

func _update_tongue_attached(delta: float, _mouth_world: Vector2) -> void:
	if not is_instance_valid(target_body):
		release()
		return
	
	_update_wrap_points()
	
	# Подмотка первого сегмента
	if joints.size() > 0:
		joints[0].length = max(0.0, joints[0].length - reel_speed * delta)
	
	# Дополнительная тяга
	var pts: PackedVector2Array = _get_points_world()
	if pts.size() >= 2:
		var a: Vector2 = pts[0]
		var b: Vector2 = pts[1]
		var dir: Vector2 = (b - a).normalized()
		var force = dir * pull_force * delta
		frog.apply_central_impulse(force)
		
		if target_body is RigidBody2D:
			var opposite_force = -dir * pull_force * delta
			(target_body as RigidBody2D).apply_central_impulse(opposite_force)
	
	# Разрыв при перенатяжении
	if joints.size() > 0 and pts.size() >= 2:
		var t: float = max(0.0, pts[0].distance_to(pts[1]) - joints[0].length)
		if t > break_tension:
			release()
			return
	
	# Обновляем визуалы
	if line:
		line.points = pts

func _update_tongue_retraction(delta: float, mouth_world: Vector2) -> void:
	# Втягиваем язык
	tongue_current_length -= tongue_retraction_speed * delta
	tongue_current_length = max(0.0, tongue_current_length)
	
	if tongue_current_length <= 0.0:
		# Язык полностью втянут
		release()
		return
	
	# Вычисляем позицию конца языка при втягивании
	var direction: Vector2 = (tongue_target_position - mouth_world).normalized()
	var current_tip_pos: Vector2 = mouth_world + direction * tongue_current_length
	
	# Обновляем визуалы
	_update_tongue_visuals(mouth_world, current_tip_pos)

func _update_tongue_visuals(mouth_world: Vector2, tip_pos: Vector2) -> void:
	# Обновляем линию языка
	if line:
		line.clear_points()
		line.add_point(mouth_world)
		
		# Добавляем все точки обворачивания для визуализации
		for pivot in pivots:
			if is_instance_valid(pivot):
				line.add_point(pivot.global_position)
		
		line.add_point(tip_pos)

func _add_side_attachment_force(normal: Vector2, _pos: Vector2) -> void:
	# Добавляем дополнительную силу прилипания
	var attachment_force: float = 1000.0
	var force_direction: Vector2 = -normal
	
	# Применяем силу к лягушке
	var frog_force = force_direction * attachment_force * 0.2
	frog.apply_central_impulse(frog_force)
	
	# Если цель - RigidBody2D, применяем противоположную силу
	if target_body is RigidBody2D:
		var target_force = -force_direction * attachment_force * 0.2
		(target_body as RigidBody2D).apply_central_impulse(target_force)
	
	# Дополнительно: если язык прикреплен к боковой поверхности, 
	# добавляем небольшую силу в направлении от поверхности для стабильности
	var is_side_collision: bool = abs(normal.x) > abs(normal.y)
	if is_side_collision:
		# Добавляем небольшую силу, чтобы язык "отошел" от поверхности немного
		# Это предотвращает застревание языка в стене
		var offset_force: Vector2 = normal.normalized() * 50.0
		frog.apply_central_impulse(offset_force)

func _get_points_world() -> PackedVector2Array:
	var arr: PackedVector2Array = PackedVector2Array()
	arr.append(frog.global_position + mouth_offset)
	
	for p in pivots:
		if is_instance_valid(p):
			arr.append(p.global_position)
	
	if is_instance_valid(target_body):
		var target_pos = (target_body as Node2D).global_position
		arr.append(target_pos)
	
	return arr

func _rebuild_joints() -> void:
	# убираем старые
	for j in joints:
		if is_instance_valid(j): 
			j.queue_free()
	joints.clear()

	# проверяем, что target_body существует
	if not is_instance_valid(target_body):
		return

	# последовательность узлов: рот (жаба) → pivots → цель
	var nodes: Array[Node2D] = []
	nodes.append(frog)
	
	for p in pivots:
		if is_instance_valid(p):
			nodes.append(p)
	
	nodes.append(target_body)

	# создаём пружину на каждом соседнем отрезке
	for i in range(nodes.size() - 1):
		var a: Node2D = nodes[i]
		var b: Node2D = nodes[i + 1]
		
		# проверяем, что оба узла валидны
		if not is_instance_valid(a) or not is_instance_valid(b):
			continue
			
		var j: DampedSpringJoint2D = DampedSpringJoint2D.new()
		j.node_a = (a as Node).get_path()
		j.node_b = (b as Node).get_path()
		j.length = a.global_position.distance_to(b.global_position)
		j.stiffness = stiffness
		j.damping = damping
		get_tree().current_scene.add_child(j)
		joints.append(j)

# расстояние от точки P до отрезка AB
func _point_to_segment_dist(p: Vector2, a: Vector2, b: Vector2) -> float:
	var ab: Vector2 = b - a
	var t: float = 0.0
	var ab_len2: float = ab.length_squared()
	if ab_len2 > 0.0:
		t = clamp((p - a).dot(ab) / ab_len2, 0.0, 1.0)
	var proj: Vector2 = a + ab * t
	return p.distance_to(proj)

# Рейкаст с увеличенной точностью для боковых поверхностей
func _raycast_precise(from: Vector2, to: Vector2, exclude_nodes: Array[Node]) -> Dictionary:
	var space: PhysicsDirectSpaceState2D = get_world_2d().direct_space_state
	var q = PhysicsRayQueryParameters2D.create(from, to)
	var ex: Array[RID] = []
	for n in exclude_nodes:
		if n is CollisionObject2D:
			ex.append((n as CollisionObject2D).get_rid())
	q.exclude = ex
	q.collision_mask = ray_mask
	# Увеличиваем точность для лучшего обнаружения боковых поверхностей
	# Note: These properties may not exist in all Godot versions, using standard raycast instead
	return space.intersect_ray(q)

# Рейкаст с ВКЛЮЧЁННОЙ целью
func _raycast_including_target(from: Vector2, to: Vector2) -> Dictionary:
	var space: PhysicsDirectSpaceState2D = get_world_2d().direct_space_state
	var q = PhysicsRayQueryParameters2D.create(from, to)
	var ex: Array[RID] = []
	# исключаем только жабу
	if frog is CollisionObject2D:
		ex.append((frog as CollisionObject2D).get_rid())
	q.exclude = ex
	q.collision_mask = ray_mask
	return space.intersect_ray(q)

func _raycast(from: Vector2, to: Vector2, exclude_nodes: Array[Node]) -> Dictionary:
	var space: PhysicsDirectSpaceState2D = get_world_2d().direct_space_state
	var q = PhysicsRayQueryParameters2D.create(from, to)
	var ex: Array[RID] = []
	for n in exclude_nodes:
		if n is CollisionObject2D:
			ex.append((n as CollisionObject2D).get_rid())
	q.exclude = ex
	q.collision_mask = ray_mask
	
	return space.intersect_ray(q)

func _update_wrap_points() -> void:
	# Проверяем каждый сегмент языка на возможность обворачивания
	var points := _get_points_world()
	
	# Проверяем каждый сегмент на наличие препятствий
	for i in range(points.size() - 1):
		var start_point := points[i]
		var end_point := points[i + 1]
		
		# Проверяем, есть ли препятствия на пути между точками
		if _pivot_cd <= 0.0:
			# Используем более точный рейкаст для боковых поверхностей
			var hit := _raycast(start_point, end_point, [frog])
			if not hit.is_empty():
				var pos: Vector2 = hit["position"]
				var normal: Vector2 = hit.get("normal", Vector2.ZERO)
				
				# Если попали практически в конечную точку, считаем, что препятствия нет
				if pos.distance_to(end_point) > 2.0:
					# Проверяем, не слишком ли близко к существующим точкам
					var should_add_pivot: bool = true
					for existing_pivot in pivots:
						if pos.distance_to(existing_pivot.global_position) < pivot_min_dist:
							should_add_pivot = false
							break
					
					# Добавляем новую точку обворачивания, если она допустима
					if should_add_pivot and pivots.size() < max_wrap_points:
						var p := StaticBody2D.new()
						p.global_position = pos
						p.collision_layer = 0
						p.collision_mask = 0
						get_tree().current_scene.add_child(p)
						# Вставляем точку в правильное место в массиве
						pivots.insert(i, p)
						_rebuild_joints()
						_pivot_cd = add_pivot_cooldown
						
						# Для боковых поверхностей добавляем небольшое смещение,
						# чтобы язык не застревал в стене
						var is_side_collision: bool = abs(normal.x) > abs(normal.y)
						if is_side_collision:
							# Слегка смещаем точку от стены для предотвращения застревания
							p.global_position = pos + normal.normalized() * 1.0
						
						# Добавляем дополнительную силу прилипания для вертикальных поверхностей
						if not is_side_collision:
							_add_side_attachment_force(normal, pos)
						return

	# Разматывание: если путь между точками свободен — снимаем ближние pivot точки
	for i in range(pivots.size()):
		if i >= pivots.size():
			break
			
		var pivot_point := pivots[i]
		if not is_instance_valid(pivot_point):
			continue
			
		# Определяем соседние точки
		var prev_point: Vector2
		var next_point: Vector2
		
		if i == 0:
			prev_point = frog.global_position + mouth_offset
		else:
			prev_point = pivots[i - 1].global_position
			
		if i == pivots.size() - 1:
			if is_instance_valid(target_body):
				next_point = target_body.global_position
			else:
				continue
		else:
			next_point = pivots[i + 1].global_position
		
		# Проверяем, можно ли удалить эту точку обворачивания
		var clear := _raycast(prev_point, next_point, [frog])
		if clear.is_empty():
			# гистерезис: удаляем pivot только если он «почти на прямой»
			var pivot_world: Vector2 = pivot_point.global_position
			var distance_to_line = _point_to_segment_dist(pivot_world, prev_point, next_point)
			
			if distance_to_line <= unwrap_hysteresis:
				# Удаляем точку
				var removed_pivot: StaticBody2D = pivots.pop_at(i)
				if is_instance_valid(removed_pivot): 
					removed_pivot.queue_free()
				_rebuild_joints()
				# Перезапускаем проверку с начала
				_update_wrap_points()
				return

# Hook point visualization
func _draw_hook_point_visual() -> void:
	# Create a simple circle texture for the hook point
	var image = Image.create(32, 32, false, Image.FORMAT_RGBA8)
	image.fill(Color(0, 0, 0, 0))
	
	# Draw a circle
	var center = Vector2(16, 16)
	var radius = 12
	var color = Color(1, 0.8, 0, 1)  # Yellow-orange color
	
	for x in range(32):
		for y in range(32):
			var distance = center.distance_to(Vector2(x, y))
			if distance <= radius and distance >= radius - 3:
				image.set_pixel(x, y, color)
	
	var texture = ImageTexture.create_from_image(image)
	self.texture = texture
	self.centered = true

# ===== API ФУНКЦИИ =====
func get_active() -> bool:
	return active

func get_current_state() -> String:
	return tongue_state

func start_retracting() -> void:
	if tongue_state == "extending" or tongue_state == "attached":
		tongue_state = "retracting"

func adjust_target_length(delta_length: float) -> void:
	# Корректировка длины
	tongue_target_length = clamp(tongue_target_length + delta_length, 0.0, max_length)

func attach_to_hook_point(hook_point: Node, attachment_position: Vector2) -> void:
	if tongue_state == "extending":
		tongue_state = "attached"
		target_body = hook_point
		tongue_current_length = frog.global_position.distance_to(attachment_position)
		_rebuild_joints()

func on_tongue_tip_hit_hook_point(hook_point: Area2D) -> void:
	# Attach to hook point when tongue tip hits it
	if tongue_state == "extending":
		tongue_state = "attached"
		target_body = hook_point
		tongue_current_length = frog.global_position.distance_to(hook_point.global_position)
		_rebuild_joints()

func fire_tongue(target_pos: Vector2) -> void:
	fire(target_pos)
	
func release_attachment() -> void:
	release()
