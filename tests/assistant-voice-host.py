"""Same-build voice control fixture. No audio devices, model, or network."""
import json
import struct
import sys

stage = "hello"
while prefix := sys.stdin.buffer.read(4):
    size = struct.unpack(">I", prefix)[0]
    assert 0 < size <= 131072
    message = json.loads(sys.stdin.buffer.read(size))
    kind = message["type"]
    assert kind == stage, (kind, stage)
    if kind == "hello":
        assert message["protocol"] == 1 and message["buildCommit"] == "fixture"
        response, stage = {"type": "ready"}, "initializeRuntime"
    elif kind == "initializeRuntime":
        response, stage = {"type": "runtimeReady"}, "startTransport"
    elif kind == "startTransport":
        response, stage = {"type": "offer", "sdp": "fixture-offer"}, "applyAnswer"
    elif kind == "applyAnswer":
        assert message["sdp"] == "fixture-answer"
        response, stage = {"type": "transportReady"}, "openDevices"
    elif kind == "openDevices":
        response, stage = {"type": "devicesOpened"}, "setAudioControls"
    elif kind == "setAudioControls":
        assert message["controls"]["speakerSuppressed"] is False
        assert isinstance(message["controls"]["microphoneMuted"], bool)
        if "mute-timeout" in sys.argv and message["controls"]["microphoneMuted"]:
            continue  # Keep the process alive but withhold the acknowledgement.
        response = {"type": "audioControlsApplied"}
    else:
        raise AssertionError(kind)
    data = json.dumps(response).encode()
    sys.stdout.buffer.write(struct.pack(">I", len(data)) + data)
    sys.stdout.buffer.flush()
