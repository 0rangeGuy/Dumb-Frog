extends Node

signal health_changed(value: int, max_value: int)

@export var max_health: int = 3
var health: int

func _ready() -> void:
	reset()

func reset() -> void:
	health = max_health
	emit_signal("health_changed", health, max_health)

func set_health(v: int) -> void:
	v = clamp(v, 0, max_health)
	if v != health:
		health = v
		emit_signal("health_changed", health, max_health)

func heal(n: int = 1) -> void: set_health(health + n)
func damage(n: int = 1) -> void: set_health(health - n)
func is_dead() -> bool: return health <= 0
