/*
 * audio_info.c - Query CoreAudio input device info on Mac OS X
 * Compile: gcc -o audio_info audio_info.c -framework CoreAudio -framework AudioToolbox
 */

#include <CoreAudio/AudioHardware.h>
#include <AudioToolbox/AudioToolbox.h>
#include <stdio.h>
#include <string.h>

static void print_device_info(AudioDeviceID deviceID, const char *label) {
    OSStatus err;
    UInt32 size;
    char name[256] = {0};
    Float32 volumes[2];
    UInt32 muted;
    AudioStreamBasicDescription format;

    /* Device name */
    size = sizeof(name);
    err = AudioDeviceGetProperty(deviceID, 0, 1, kAudioDevicePropertyDeviceName, &size, name);
    printf("  %s: ID=%u, Name=\"%s\"\n", label, (unsigned)deviceID, err == noErr ? name : "(error)");

    /* Check if device is alive */
    UInt32 alive = 0;
    size = sizeof(alive);
    err = AudioDeviceGetProperty(deviceID, 0, 1, kAudioDevicePropertyDeviceIsAlive, &size, &alive);
    printf("  Alive: %s\n", alive ? "yes" : "no");

    /* Input stream format */
    size = sizeof(format);
    err = AudioDeviceGetProperty(deviceID, 0, 1, kAudioDevicePropertyStreamFormat, &size, &format);
    if (err == noErr) {
        printf("  Input Format: %.0f Hz, %u ch, %u bits\n",
               format.mSampleRate,
               (unsigned)format.mChannelsPerFrame,
               (unsigned)format.mBitsPerChannel);
    } else {
        printf("  Input Format: (error %d - no input stream?)\n", (int)err);
    }

    /* Input volume per channel */
    Float32 vol;
    size = sizeof(vol);
    err = AudioDeviceGetProperty(deviceID, 1, 1, kAudioDevicePropertyVolumeScalar, &size, &vol);
    if (err == noErr) {
        printf("  Input Ch1 Volume: %.2f\n", vol);
    } else {
        printf("  Input Ch1 Volume: (error %d)\n", (int)err);
    }
    err = AudioDeviceGetProperty(deviceID, 2, 1, kAudioDevicePropertyVolumeScalar, &size, &vol);
    if (err == noErr) {
        printf("  Input Ch2 Volume: %.2f\n", vol);
    } else {
        printf("  Input Ch2 Volume: (error %d)\n", (int)err);
    }

    /* Master input volume */
    err = AudioDeviceGetProperty(deviceID, 0, 1, kAudioDevicePropertyVolumeScalar, &size, &vol);
    if (err == noErr) {
        printf("  Input Master Volume: %.2f\n", vol);
    } else {
        printf("  Input Master Volume: (error %d)\n", (int)err);
    }

    /* Mute status */
    UInt32 mute = 0;
    size = sizeof(mute);
    err = AudioDeviceGetProperty(deviceID, 0, 1, kAudioDevicePropertyMute, &size, &mute);
    if (err == noErr) {
        printf("  Input Muted: %s\n", mute ? "YES" : "no");
    }

    /* Data source */
    UInt32 source = 0;
    size = sizeof(source);
    err = AudioDeviceGetProperty(deviceID, 0, 1, kAudioDevicePropertyDataSource, &size, &source);
    if (err == noErr) {
        char srcName[5] = {0};
        srcName[0] = (source >> 24) & 0xFF;
        srcName[1] = (source >> 16) & 0xFF;
        srcName[2] = (source >> 8) & 0xFF;
        srcName[3] = source & 0xFF;
        printf("  Input Source: '%s' (0x%08X)\n", srcName, (unsigned)source);
    }

    /* List available data sources */
    AudioObjectPropertyAddress prop;
    prop.mSelector = kAudioDevicePropertyDataSources;
    prop.mScope = kAudioDevicePropertyScopeInput;
    prop.mElement = kAudioObjectPropertyElementMaster;

    size = 0;
    err = AudioObjectGetPropertyDataSize(deviceID, &prop, 0, NULL, &size);
    if (err == noErr && size > 0) {
        int count = size / sizeof(UInt32);
        UInt32 sources[16];
        err = AudioObjectGetPropertyData(deviceID, &prop, 0, NULL, &size, sources);
        if (err == noErr) {
            printf("  Available Input Sources (%d):\n", count);
            int i;
            for (i = 0; i < count && i < 16; i++) {
                char sn[5] = {0};
                sn[0] = (sources[i] >> 24) & 0xFF;
                sn[1] = (sources[i] >> 16) & 0xFF;
                sn[2] = (sources[i] >> 8) & 0xFF;
                sn[3] = sources[i] & 0xFF;

                /* Get translated name */
                AudioValueTranslation trans;
                CFStringRef cfName = NULL;
                trans.mInputData = &sources[i];
                trans.mInputDataSize = sizeof(UInt32);
                trans.mOutputData = &cfName;
                trans.mOutputDataSize = sizeof(CFStringRef);
                UInt32 tSize = sizeof(trans);
                OSStatus terr = AudioDeviceGetProperty(deviceID, 0, 1,
                    kAudioDevicePropertyDataSourceNameForIDCFString, &tSize, &trans);
                
                char translatedName[128] = "(unknown)";
                if (terr == noErr && cfName) {
                    CFStringGetCString(cfName, translatedName, sizeof(translatedName), kCFStringEncodingUTF8);
                    CFRelease(cfName);
                }

                printf("    [%d] '%s' (0x%08X) = %s%s\n", i, sn, (unsigned)sources[i],
                       translatedName,
                       sources[i] == source ? " <-- SELECTED" : "");
            }
        }
    }

    /* Number of input streams/channels */
    prop.mSelector = kAudioDevicePropertyStreamConfiguration;
    prop.mScope = kAudioDevicePropertyScopeInput;
    prop.mElement = 0;
    size = 0;
    err = AudioObjectGetPropertyDataSize(deviceID, &prop, 0, NULL, &size);
    if (err == noErr && size > 0) {
        AudioBufferList *bufList = (AudioBufferList *)malloc(size);
        err = AudioObjectGetPropertyData(deviceID, &prop, 0, NULL, &size, bufList);
        if (err == noErr) {
            printf("  Input Streams: %u\n", (unsigned)bufList->mNumberBuffers);
            UInt32 b;
            for (b = 0; b < bufList->mNumberBuffers; b++) {
                printf("    Stream %u: %u channels\n", (unsigned)b,
                       (unsigned)bufList->mBuffers[b].mNumberChannels);
            }
        }
        free(bufList);
    }
}

int main() {
    OSStatus err;
    UInt32 size;
    AudioDeviceID defaultInput;

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
    printf("Default Input Device:\n");
    print_device_info(defaultInput, "Device");

    /* Also list all audio devices */
    prop.mSelector = kAudioHardwarePropertyDevices;
    size = 0;
    err = AudioObjectGetPropertyDataSize(kAudioObjectSystemObject, &prop, 0, NULL, &size);
    if (err == noErr) {
        int count = size / sizeof(AudioDeviceID);
        AudioDeviceID devices[32];
        err = AudioObjectGetPropertyData(kAudioObjectSystemObject, &prop, 0, NULL, &size, devices);
        if (err == noErr) {
            printf("\nAll Audio Devices (%d):\n", count);
            int i;
            for (i = 0; i < count && i < 32; i++) {
                char name[256] = {0};
                UInt32 nsize = sizeof(name);
                AudioDeviceGetProperty(devices[i], 0, 0, kAudioDevicePropertyDeviceName, &nsize, name);
                printf("  [%d] ID=%u \"%s\"%s\n", i, (unsigned)devices[i], name,
                       devices[i] == defaultInput ? " <-- DEFAULT INPUT" : "");
            }
        }
    }

    return 0;
}
