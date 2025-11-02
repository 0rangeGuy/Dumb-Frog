extends RigidBody2D

@export var touch_damage: int = 1              # урон за тик
@export var damage_interval: float = 1.5       # как часто бить, пока соприкасаемся
@export var area_padding: float = 5.0          # расширить хитбокс на столько пикселей

var _player_overlapping := false
var _tick_timer: Timer
var damage_area: Area2D

@export var damage_cooldown: float = 0.5
var _can_hit := true

@export var speed: float = 90.0
@export var patrol_half: float = 140.0
@export var flip_on_wall: bool = true
@export var tint: Color = Color(1, 0.2, 0.2, 1) # цвет врага (красный по умолчанию)

var _origin_x: float
var _dir: int = 1
var _alive: bool = true

func _ready() -> void:
	_ensure_nodes()
	_ensure_damage_area()
	_origin_x = global_position.x
	add_to_group("enemy")
	
	
	_tick_timer = Timer.new()
	_tick_timer.wait_time = damage_interval
	_tick_timer.one_shot = false
	add_child(_tick_timer)
	_tick_timer.timeout.connect(_on_damage_tick)


func _integrate_forces(state: PhysicsDirectBodyState2D) -> void:
	if not _alive:
		return
	var v := state.get_linear_velocity()
	v.x = speed * _dir
	state.set_linear_velocity(v)
	if global_position.x > _origin_x + patrol_half: _dir = -1
	elif global_position.x < _origin_x - patrol_half: _dir = 1

func _on_hit_wall() -> void:
	if flip_on_wall: _dir *= -1

func kill() -> void:
	if not _alive: return
	_alive = false
	collision_layer = 0
	collision_mask = 0
	set_deferred("sleeping", true)
	queue_free()

# ---- visuals ---------------------------------------------------------------

func _ensure_nodes() -> void:
	# --- CollisionShape2D ---
	var col := get_node_or_null("CollisionShape2D")
	if col == null:
		col = CollisionShape2D.new()
		col.name = "CollisionShape2D"
		add_child(col)
	if col.shape == null:
		var rs := RectangleShape2D.new()
		rs.size = Vector2(16, 16) # подгони под свой размер
		col.shape = rs

	# --- Sprite2D ---  <<< ДОБАВЬ ЭТО
	var spr := get_node_or_null("Sprite2D") as Sprite2D
	if spr == null:
		spr = Sprite2D.new()
		spr.name = "Sprite2D"
		add_child(spr)
	if spr.texture == null:
		spr.texture = _make_solid_texture(16, 16, tint) # твой helper снизу
		spr.centered = true


func _ensure_damage_area() -> void:
	damage_area = get_node_or_null("DamageArea") as Area2D
	if damage_area == null:
		damage_area = Area2D.new()
		damage_area.name = "DamageArea"
		add_child(damage_area)

	var col := damage_area.get_node_or_null("CollisionShape2D") as CollisionShape2D
	if col == null:
		col = CollisionShape2D.new()
		col.name = "CollisionShape2D"
		damage_area.add_child(col)

	# форма области урона = форма основного коллайдера, но чутка больше
	var base_col := get_node_or_null("CollisionShape2D") as CollisionShape2D
	if base_col and base_col.shape:
		col.shape = base_col.shape.duplicate()
	if col.shape == null:
		var rs := RectangleShape2D.new()
		rs.size = Vector2(16, 16)
		col.shape = rs

	# лёгкое расширение, чтобы ловить контакт боком
	if col.shape is RectangleShape2D:
		(col.shape as RectangleShape2D).size += Vector2(area_padding * 2.0, area_padding * 2.0)
	elif col.shape is CircleShape2D:
		(col.shape as CircleShape2D).radius += area_padding

	damage_area.monitoring = true
	damage_area.monitorable = true
	damage_area.collision_layer = 0
	damage_area.collision_mask = 0x7FFFFFFF   # для надёжной проверки; позже можно сузить до 1<<0

	# сигналы
	if not damage_area.is_connected("body_entered", Callable(self, "_on_damage_body_entered")):
		damage_area.body_entered.connect(_on_damage_body_entered)
	if not damage_area.is_connected("body_exited", Callable(self, "_on_damage_body_exited")):
		damage_area.body_exited.connect(_on_damage_body_exited)



func _on_damage_body_entered(body: Node) -> void:
	if body.is_in_group("player"):
		_player_overlapping = true
		_hit_once()                # мгновенно бьём один раз
		if _tick_timer.is_stopped():
			_tick_timer.start()    # затем бьём каждые damage_interval

func _on_damage_body_exited(body: Node) -> void:
	if body.is_in_group("player"):
		_player_overlapping = false
		_tick_timer.stop()

func _on_damage_tick() -> void:
	if _player_overlapping:
		_hit_once()

func _hit_once() -> void:
	PlayerState.damage(touch_damage)


func _on_damage_area_entered(area: Area2D) -> void:
	# Если вдруг у лягушки хитбокс — Area2D
	var p := area.get_parent()
	_try_hit(p if p else area)

func _try_hit(node: Node) -> void:
	if not _can_hit:
		return
	if node and node.is_in_group("player"):
		PlayerState.damage(touch_damage)
		_can_hit = false
		get_tree().create_timer(damage_cooldown).timeout.connect(func(): _can_hit = true)




func _make_solid_texture(w: int, h: int, col: Color) -> Texture2D:
	var img := Image.create(w, h, false, Image.FORMAT_RGBA8)
	img.fill(col)
	return ImageTexture.create_from_image(img)
