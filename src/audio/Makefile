all: audio
	@echo > /dev/null

audio: main.vala audio.vala audio-interface.vala ../config/config-interface.vala
	valac -X -w -o $@ --pkg gstreamer-1.0 --pkg gio-2.0 $^

clean:
	rm -rf audio

.PHONY: all clean
