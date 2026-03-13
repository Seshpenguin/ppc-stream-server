/*
 * set_input.c - Set CoreAudio input source on Mac OS X
 * Compile: gcc -o set_input set_input.c -framework CoreAudio
 * Usage:   ./set_input line    (for Line In)
 *          ./set_input spdf    (for Digital/S/PDIF In)
 */

#include <CoreAudio/AudioHardware.h>
#include <stdio.h>
#include <string.h>

int main(int argc, char *argv[]) {
    OSStatus err;
    UInt32 size;
    AudioDeviceID defaultInput;

    if (argc < 2) {
        printf("Usage: %s <line|spdf>\n", argv[0]);
        return 1;
    }

    /* Build the 4-char code from argument */
    UInt32 source = 0;
    const char *src = argv[1];
    int len = strlen(src);
    if (len > 4) len = 4;
    int i;
    for (i = 0; i < 4; i++) {
        source <<= 8;
        if (i < len) source |= (unsigned char)src[i];
        else source |= ' ';
    }

    /* Get default input device */
    size = sizeof(defaultInput);
    AudioObjectPropertyAddress prop = {
        kAudioHardwarePropertyDefaultInputDevice,
        kAudioObjectPropertyScopeGlobal,
        kAudioObjectPropertyElementMaster
    };
    err = AudioObjectGetPropertyData(kAudioObjectSystemObject, &prop, 0, NULL, &size, &defaultInput);
    if (err != noErr) {
        printf("ERROR: No default input device! (err=%d)\n", (int)err);
        return 1;
    }

    /* Set the data source */
    prop.mSelector = kAudioDevicePropertyDataSource;
    prop.mScope = kAudioDevicePropertyScopeInput;
    prop.mElement = kAudioObjectPropertyElementMaster;

    size = sizeof(source);
    err = AudioObjectSetPropertyData(defaultInput, &prop, 0, NULL, size, &source);
    if (err != noErr) {
        printf("ERROR: Failed to set input source (err=%d)\n", (int)err);
        return 1;
    }

    /* Verify */
    UInt32 current = 0;
    size = sizeof(current);
    err = AudioObjectGetPropertyData(defaultInput, &prop, 0, NULL, &size, &current);
    char name[5] = {0};
    name[0] = (current >> 24) & 0xFF;
    name[1] = (current >> 16) & 0xFF;
    name[2] = (current >> 8) & 0xFF;
    name[3] = current & 0xFF;
    printf("Input source now set to: '%s'\n", name);

    return 0;
}
