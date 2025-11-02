extends CanvasLayer

@onready var label: Label = %HealthLabel

func _ready() -> void:
	# Попробуем найти PlayerState как синглтон (autoload).
	var ps := get_node_or_null("/root/PlayerState")
	if ps:
		ps.health_changed.connect(_on_health)
		_on_health(ps.health, ps.max_health)
	else:
		label.text = "HP ?"
		push_warning("PlayerState не найден. Добавь его в Проект → Параметры проекта → Автозагрузка.")

func _on_health(v: int, m: int) -> void:
	# Если эмодзи не видны шрифтом — замени на строку ниже с числами.
	label.text = _hearts(v, m)
	# label.text = "HP: %d/%d" % [v, m]

func _hearts(v: int, m: int) -> String:
	var s := "HP "
	for i in range(m):
		s += "❤" if i < v else "♡"
	return s
