extends Node2D


# Called when the node enters the scene tree for the first time.
func _ready() -> void:
	pass # Replace with function body.


# Called every frame. 'delta' is the elapsed time since the previous frame.
func _process(_delta: float) -> void:
	pass

func _input(event): # Выход через esc
	if event.is_action_pressed("ui_cancel"):
		get_tree().quit()
		
func _on_test_3_pressed() -> void: # Кнопка выключения
	get_tree().quit()
	pass 


func _on_test_1_pressed() -> void: # ЛВЛ 1
	get_tree().change_scene_to_file("res://scenes/TestLevel.tscn")
	pass 


func _on_test_2_pressed() -> void: # ЛВЛ 2
	get_tree().change_scene_to_file("res://scenes/MapTileTest.tscn")
	pass 
