extends RigidBody2D
# Управляемое физтело: A/D ходьба, Space/W прыжок, ЛКМ выстрел языка, ПКМ отцеп.

@export var move_force: float = 3200.0
@export var max_run_speed: float = 320.0
@export var jump_impulse: Vector2 = Vector2(0, -560.0)

@onready var ray_floor: RayCast2D = $RayFloor
@onready var tongue: Node = $Tongue

func _ready() -> void:
	add_to_group("player")
	# Передаём в язык: жабу и визуалы (RopeSim и/или Line2D)
	var rope := $Tongue.get_node_or_null("Rope")     # узел из аддона RopeSim (переименуй в "Rope")
	var line := $Tongue.get_node_or_null("Line2D")   # запасной Line2D (не обязателен)
	tongue.call("setup", self, rope, line)

func is_on_floor() -> bool:
	return ray_floor.is_colliding()

func _physics_process(_delta: float) -> void:
	var dir := Input.get_action_strength("move_right") - Input.get_action_strength("move_left")
	if abs(linear_velocity.x) < max_run_speed:
		apply_force(Vector2(move_force * dir, 0.0))

	# демпфирование: на земле сильнее, в воздухе слабее
	linear_damp = 0.6 if is_on_floor() else 0.05

	# не даём телу кувыркаться
	angular_velocity = 0.0
	rotation = 0.0

# --- Godot 4.x ---
func _mouse_world() -> Vector2:
	# Конвертируем координаты курсора экрана в мировые с учётом активной Camera2D
	return get_canvas_transform().affine_inverse() * get_viewport().get_mouse_position()

func _unhandled_input(event: InputEvent) -> void:
	if event.is_action_pressed("jump") and is_on_floor():
		apply_central_impulse(jump_impulse)

	if event.is_action_pressed("tongue_fire"):
		tongue.call("fire", _mouse_world())

	if event.is_action_pressed("tongue_release"):
		tongue.call("release")
