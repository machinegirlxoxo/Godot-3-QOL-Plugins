tool
extends Node
# Listens on a local TCP port for the JSON the Epic Games Launcher (Fab) sends when you press
# Export with the export target set to "Custom (socket port)".
# Only plain JSON that starts with [ or { is accepted; anything else (for example an HTTP
# request from a web page) is dropped. The server only binds to the loopback address.

signal payload_received(data)
signal message(text)

const MAX_BYTES = 32 * 1024 * 1024
const IDLE_PARSE_SECONDS = 1.0
const IDLE_DROP_SECONDS = 15.0
const MAX_CLIENTS = 8

var port = 24981
var bind_address = "127.0.0.1"

var _server = TCP_Server.new()
var _clients = []   # {peer, buf, idle}


func start(p: int) -> int:
	stop()
	port = p
	var err = _server.listen(port, bind_address)
	if err != OK:
		emit_signal("message", "Could not listen on %s:%d (error %d). Is the port already used by another plugin?" % [bind_address, port, err])
		return err
	emit_signal("message", "Listening on %s:%d" % [bind_address, port])
	return OK


func stop() -> void:
	for c in _clients:
		c["peer"].disconnect_from_host()
	_clients = []
	if _server.is_listening():
		_server.stop()


func is_listening() -> bool:
	return _server.is_listening()


func _exit_tree() -> void:
	stop()


func _process(delta: float) -> void:
	if not _server.is_listening():
		return
	while _server.is_connection_available():
		var peer = _server.take_connection()
		if _clients.size() >= MAX_CLIENTS:
			peer.disconnect_from_host()
			continue
		_clients.append({"peer": peer, "buf": PoolByteArray(), "idle": 0.0, "pos": 0, "depth": 0, "in_str": false, "esc": false, "invalid": false})

	for c in _clients.duplicate():
		var peer: StreamPeerTCP = c["peer"]
		var n = peer.get_available_bytes()
		if n > 0:
			var r = peer.get_data(n)
			if r[0] == OK:
				# PoolByteArray is a value type in Godot 3: modify a local copy and store it back.
				var b: PoolByteArray = c["buf"]
				b.append_array(r[1])
				c["buf"] = b
			c["idle"] = 0.0
			if c["buf"].size() > MAX_BYTES:
				_drop(c, "Payload too large, ignored.")
				continue
			if _try_parse(c):
				_finish(c)
				continue
			if c["invalid"]:
				_drop(c, "Received data that is not valid JSON, ignored.")
				continue
		else:
			c["idle"] += delta

		var closed = peer.get_status() != StreamPeerTCP.STATUS_CONNECTED
		if closed:
			if c["buf"].size() > 0 and not _try_parse(c):
				_drop(c, "Received data that is not valid JSON, ignored.")
			else:
				_finish(c)
		elif c["buf"].size() > 0 and c["idle"] > IDLE_DROP_SECONDS:
			_drop(c, "Received data that is not valid JSON, ignored.")


# Returns true when the buffer holds a complete JSON document (and emits it).
# Completeness is tracked by counting brackets, so half-received data never reaches JSON.parse.
func _try_parse(c: Dictionary) -> bool:
	var buf: PoolByteArray = c["buf"]
	var i: int = c["pos"]
	var complete = false
	while i < buf.size() and not complete:
		var ch = buf[i]
		i += 1
		if c["in_str"]:
			if c["esc"]:
				c["esc"] = false
			elif ch == 92:        # backslash
				c["esc"] = true
			elif ch == 34:        # quote
				c["in_str"] = false
		elif ch == 34:
			c["in_str"] = true
		elif ch == 91 or ch == 123:   # [ {
			c["depth"] += 1
		elif ch == 93 or ch == 125:   # ] }
			c["depth"] -= 1
			if c["depth"] <= 0:
				complete = true
		elif c["depth"] == 0 and not (ch == 32 or ch == 9 or ch == 10 or ch == 13):
			c["invalid"] = true   # does not start with [ or {
			return false
	c["pos"] = i
	if not complete:
		return false
	var parsed = JSON.parse(buf.get_string_from_utf8())
	if parsed.error != OK:
		c["invalid"] = true
		return false
	c["buf"] = PoolByteArray()
	emit_signal("payload_received", parsed.result)
	return true


func _finish(c: Dictionary) -> void:
	c["peer"].disconnect_from_host()
	_clients.erase(c)


func _drop(c: Dictionary, why: String) -> void:
	emit_signal("message", why)
	_finish(c)
