# ZMM

## What

A small and simple Zig program that is intended to run on a Raspberry Pi. I have an amp hooked up to a relay that's controlled by a GPIO pin on the Pi. I want the amp to automatically turn on when I tell MPD to play stuff and turn off after a few mins if nothing is currently playing.

## How

This program spawns a thread that connects to a running MPD instance and monitors it for player state changes (play/pause/stop). When it notices that MPD has started playing something it will set a specific GPIO pin high. The main thread will sleep for some given timeout value within a loop. If no message from MPD has been received within one iteration of this loop and MPD is not currently playing anything, then the GPIO pin is set low. This means that if you pause at the start of the time out then the GPIO will not be set low until the end of the next timeout. So the minium time is whatever you set it to, but the maximum time can be nearly twice that. I may make this more predictable, but it works fine for what I need right now and its simple.

The time out and the GPIO pin can be set by modifying the program source. Command line options may get added eventually if I feel like it.

## Build

`zig build` will work. If you are working on another computer and need to cross compile for the Pi, use `zig build -Dtarget=arm-linux` (thank you zig build awesomness). For a gotta-go-fast build use `zig build -Doptimize=FastRelease -Dtarget=arm-linux`
