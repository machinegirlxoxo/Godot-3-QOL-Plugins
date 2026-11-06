tool
extends Reference
# Tiny loopback-only TCP receiver for Quixel Bridge's "Custom Socket Export".
# Bridge connects, sends one JSON message and closes. Call poll() every frame; it returns the
# complete messages (as Strings) that arrived since the last call. Never blocks.

const MAX_BYTES = 64 * 1024 * 1024
const TIMEOUT_MS = 30000

var port = 0
var _server: TCP_Server
var _clients = []    # [{peer, buf, t}]


func start(p: int) -> int:
	stop()
	var s = TCP_Server.new()
	var err = s.listen(p, "127.0.0.1")    # loopback only: nothing outside this machine can connect
	if err != OK:
		return err
	_server = s
	port = p
	return OK


func stop() -> void:
	for c in _clients:
		c["peer"].disconnect_from_host()
	_clients = []
	if _server != null:
		_server.stop()
		_server = null


func is_listening() -> bool:
	return _server != null and _server.is_listening()


func _looks_complete(buf: PoolByteArray) -> bool:
	# Cheap check first: a JSON document ends with } or ] (ignoring whitespace).
	var i = buf.size() - 1
	while i >= 0 and (buf[i] == 32 or buf[i] == 10 or buf[i] == 13 or buf[i] == 9 or buf[i] == 0):
		i -= 1
	if i < 0 or (buf[i] != 125 and buf[i] != 93):
		return false
	return JSON.parse(buf.get_string_from_utf8()).error == OK


func poll() -> Array:
	var out = []
	if _server == null:
		return out
	while _server.is_connection_available():
		_clients.append({"peer": _server.take_connection(), "buf": PoolByteArray(), "t": OS.get_ticks_msec()})

	var keep = []
	for c in _clients:
		var peer: StreamPeerTCP = c["peer"]
		# PoolByteArray is a value type: take it out of the dictionary, change it, put it back.
		var buf: PoolByteArray = c["buf"]
		var closed = peer.get_status() != StreamPeerTCP.STATUS_CONNECTED
		var got = false
		if not closed:
			for _i in range(64):
				var r = peer.get_partial_data(65536)    # non-blocking
				if r[0] != OK:
					closed = true    # the sender hung up
					break
				if r[1].size() == 0:
					break
				buf.append_array(r[1])
				got = true
				if buf.size() > MAX_BYTES:
					break
		c["buf"] = buf
		if buf.size() > MAX_BYTES:
			peer.disconnect_from_host()
			continue
		if closed or (got and _looks_complete(buf)):
			if buf.size() > 0:
				out.append(buf.get_string_from_utf8())
			peer.disconnect_from_host()
			continue
		if OS.get_ticks_msec() - c["t"] > TIMEOUT_MS:
			peer.disconnect_from_host()
			continue
		keep.append(c)
	_clients = keep
	return out
