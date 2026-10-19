// mmsystem.h — POSIX (macOS) shim. timeGetTime is provided by xrCore's
// win_compat (GetTickCount-based); multimedia timers are unused by the engine
// core beyond that.
#ifndef XR_POSIX_MMSYSTEM_H
#define XR_POSIX_MMSYSTEM_H

#ifndef TIMERR_NOERROR
#define TIMERR_NOERROR 0
#endif
#ifndef TIME_KILL_SYNCHRONOUS
#define TIME_KILL_SYNCHRONOUS 0x0100
#endif

typedef unsigned int MMRESULT_MMSYSTEM;

// Wave formats (Windows mmreg.h surface used by xrSound)
#ifndef WAVE_FORMAT_PCM
#define WAVE_FORMAT_PCM 0x0001
#define WAVE_FORMAT_IEEE_FLOAT 0x0003
#define WAVE_FORMAT_ADPCM 0x0002
#define WAVE_FORMAT_EXTENSIBLE 0xFFFE
#endif

#ifndef WAVEFORMATEX_DEFINED_XR
#define WAVEFORMATEX_DEFINED_XR
typedef struct _WAVEFORMATEX
{
    unsigned short wFormatTag;
    unsigned short nChannels;
    unsigned long nSamplesPerSec;
    unsigned long nAvgBytesPerSec;
    unsigned short nBlockAlign;
    unsigned short wBitsPerSample;
    unsigned short cbSize;
} WAVEFORMATEX, *PWAVEFORMATEX;

typedef struct _WAVEFORMATEXTENSIBLE
{
    WAVEFORMATEX Format;
    union
    {
        unsigned short wValidBitsPerSample;
        unsigned short wSamplesPerBlock;
        unsigned short wReserved;
    } Samples;
    unsigned short dwChannelMask;
    struct
    {
        unsigned char Data[16];
    } SubFormat;
} WAVEFORMATEXTENSIBLE, *PWAVEFORMATEXTENSIBLE;
#endif

#endif // XR_POSIX_MMSYSTEM_H
