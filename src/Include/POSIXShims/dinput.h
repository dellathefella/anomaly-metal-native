// dinput.h — POSIX (macOS) shim. The DirectInput backend (Xr_input.cpp) is
// not built on Apple platforms; the SDL input port implements CInput's public
// interface instead. This header keeps xrEngine/xrGame call sites intact:
//   - DIK_* scancodes (keybind tokens used across xrGame UI/scripts)
//   - minimal DI types for xr_input.h declarations
//   - DIMOFS/DIPROP tokens referenced by input-related game code

#ifndef XR_POSIX_DINPUT_H
#define XR_POSIX_DINPUT_H

#include <stdint.h>

// HRESULT comes from Common/PlatformApple.inl (long).

#ifndef S_OK
#define S_OK ((HRESULT)0L)
#define S_FALSE ((HRESULT)1L)
#define FAILED(h) (((HRESULT)(h)) < 0)
#define SUCCEEDED(h) (((HRESULT)(h)) >= 0)
#endif
#define DI_OK S_OK
#define DI_NOTATTACHED ((HRESULT)0x80040201L)
#define DI_BUFFEROVERFLOW ((HRESULT)0x80040202L)
#define DIERR_GENERIC ((HRESULT)0x80004005L)
#define DIERR_INVALIDPARAM ((HRESULT)0x80070057L)
#define DIERR_NOTINITIALIZED ((HRESULT)0x80040300L)
#define DIERR_OTHERAPPHASPRIO ((HRESULT)0x80040301L)
#define DIERR_INPUTLOST ((HRESULT)0x80040302L)
#define DIERR_NOTACQUIRED ((HRESULT)0x80040303L)
#define DIERR_UNSUPPORTED ((HRESULT)0x80040307L)

// cooperative levels
#define DISCL_EXCLUSIVE 0x00000001L
#define DISCL_NONEXCLUSIVE 0x00000002L
#define DISCL_FOREGROUND 0x00000004L
#define DISCL_BACKGROUND 0x00000008L
#define DISCL_NOWINKEY 0x00000010L

// device property headers
#define DIPH_DEVICE 0
#define DIPH_BYOFFSET 1
#define DIPH_BYID 2
#define DIPROP_BUFFERSIZE 0x00000003L
#define DIPROP_KEYNAME 0x00000008L

typedef struct tagDIPROPHEADER
{
    uint32_t dwHeader;
    uint32_t dwObj;
    uint32_t dwHow;
} DIPROPHEADER, *LPDIPROPHEADER;

typedef struct tagDIPROPDWORD
{
    DIPROPHEADER diph;
    uint32_t dwData;
} DIPROPDWORD, *LPDIPROPDWORD;

typedef struct tagDIPROPSTRING
{
    DIPROPHEADER diph;
    uint16_t wString[128];
} DIPROPSTRING, *LPDIPROPSTRING;

// mouse object offsets
#define DIMOFS_X 0L
#define DIMOFS_Y 4L
#define DIMOFS_Z 8L
#define DIMOFS_BUTTON0 (8 + 0)
#define DIMOFS_BUTTON1 (8 + 1)
#define DIMOFS_BUTTON2 (8 + 2)
#define DIMOFS_BUTTON3 (8 + 3)
#define DIMOFS_BUTTON4 (8 + 4)
#define DIMOFS_BUTTON5 (8 + 5)
#define DIMOFS_BUTTON6 (8 + 6)
#define DIMOFS_BUTTON7 (8 + 7)

typedef struct tagDIDEVCAPS
{
    uint32_t dwSize;
    uint32_t dwFlags;
    uint32_t dwDevType;
    uint32_t dwAxes;
    uint32_t dwButtons;
    uint32_t dwPOVs;
    uint32_t dwFFSamplePeriod;
    uint32_t dwFFMinTimePeriod;
    uint32_t dwAxisSize;
    uint32_t dwPacketSize;
} DIDEVCAPS, *LPDIDEVCAPS;

typedef struct tagDIDEVICEINSTANCEA
{
    uint32_t dwSize;
    GUID guidInstance;
    GUID guidProduct;
    uint32_t dwDevType;
    char tszInstanceName[128];
    char tszProductName[128];
    GUID guidGuid;
    uint32_t dwFFDriverLevel;
    unsigned char ffPT[4];
} DIDEVICEINSTANCEA, *LPDIDEVICEINSTANCEA;
#define DIDEVICEINSTANCE DIDEVICEINSTANCEA

typedef struct tagDIDEVICEOBJECTINSTANCEA
{
    uint32_t dwSize;
    GUID guidType;
    uint32_t dwType;
    uint32_t dwFlags;
    uint32_t dwOfs;
    uint32_t dwTypeData;
    uint32_t dwCollisions;
    char tszName[128];
    GUID guidGUIDType;
    union {
        struct { int32_t wMin, wMax; };
        struct { int32_t wMinForce, wMaxForce; };
    };
} DIDEVICEOBJECTINSTANCEA, *LPDIDEVICEOBJECTINSTANCEA;
#define DIDEVICEOBJECTINSTANCE DIDEVICEOBJECTINSTANCEA

typedef struct tagDIDEVICEOBJECTDATA
{
    uint32_t dwOfs;
    uint32_t dwData;
    uint32_t uTimestamp;
    uint32_t uSeq;
} DIDEVICEOBJECTDATA, *LPDIDEVICEOBJECTDATA;

typedef struct tagDIDATAFORMAT
{
    uint32_t dwSize;
    uint32_t dwObjSize;
    uint32_t dwFlags;
    uint32_t dwNumObjs;
    void* rgodf;
} DIDATAFORMAT, *LPDIDATAFORMAT;

// Opaque interfaces — the SDL backend never calls into them; they exist so
// xr_input.h declarations parse unchanged.
struct IDirectInput8;
struct IDirectInputDevice8;
typedef IDirectInput8* LPDIRECTINPUT8;
typedef IDirectInputDevice8* LPDIRECTINPUTDEVICE8;
typedef struct HINSTANCE__* LPDIRECTINPUT_VERSION_UNUSED; // keep HINSTANCE-style params happy

// ---------------------------------------------------------------------------
// DIK_* scancodes (standard DirectInput scan-code set, 8-bit + 0x100 extended)
// ---------------------------------------------------------------------------
#define DIK_ESCAPE 0x01
#define DIK_1 0x02
#define DIK_2 0x03
#define DIK_3 0x04
#define DIK_4 0x05
#define DIK_5 0x06
#define DIK_6 0x07
#define DIK_7 0x08
#define DIK_8 0x09
#define DIK_9 0x0A
#define DIK_0 0x0B
#define DIK_MINUS 0x0C
#define DIK_EQUALS 0x0D
#define DIK_BACK 0x0E
#define DIK_TAB 0x0F
#define DIK_Q 0x10
#define DIK_W 0x11
#define DIK_E 0x12
#define DIK_R 0x13
#define DIK_T 0x14
#define DIK_Y 0x15
#define DIK_U 0x16
#define DIK_I 0x17
#define DIK_O 0x18
#define DIK_P 0x19
#define DIK_LBRACKET 0x1A
#define DIK_RBRACKET 0x1B
#define DIK_RETURN 0x1C
#define DIK_LCONTROL 0x1D
#define DIK_A 0x1E
#define DIK_S 0x1F
#define DIK_D 0x20
#define DIK_F 0x21
#define DIK_G 0x22
#define DIK_H 0x23
#define DIK_J 0x24
#define DIK_K 0x25
#define DIK_L 0x26
#define DIK_SEMICOLON 0x27
#define DIK_APOSTROPHE 0x28
#define DIK_GRAVE 0x29
#define DIK_LSHIFT 0x2A
#define DIK_BACKSLASH 0x2B
#define DIK_Z 0x2C
#define DIK_X 0x2D
#define DIK_C 0x2E
#define DIK_V 0x2F
#define DIK_B 0x30
#define DIK_N 0x31
#define DIK_M 0x32
#define DIK_COMMA 0x33
#define DIK_PERIOD 0x34
#define DIK_SLASH 0x35
#define DIK_RSHIFT 0x36
#define DIK_MULTIPLY 0x37
#define DIK_LMENU 0x38
#define DIK_SPACE 0x39
#define DIK_CAPITAL 0x3A
#define DIK_F1 0x3B
#define DIK_F2 0x3C
#define DIK_F3 0x3D
#define DIK_F4 0x3E
#define DIK_F5 0x3F
#define DIK_F6 0x40
#define DIK_F7 0x41
#define DIK_F8 0x42
#define DIK_F9 0x43
#define DIK_F10 0x44
#define DIK_NUMLOCK 0x45
#define DIK_SCROLL 0x46
#define DIK_NUMPAD7 0x47
#define DIK_NUMPAD8 0x48
#define DIK_NUMPAD9 0x49
#define DIK_SUBTRACT 0x4A
#define DIK_NUMPAD4 0x4B
#define DIK_NUMPAD5 0x4C
#define DIK_NUMPAD6 0x4D
#define DIK_ADD 0x4E
#define DIK_NUMPAD1 0x4F
#define DIK_NUMPAD2 0x50
#define DIK_NUMPAD3 0x51
#define DIK_NUMPAD0 0x52
#define DIK_DECIMAL 0x53
#define DIK_SPECIAL1 0x54
#define DIK_SPECIAL2 0x55
#define DIK_SPECIAL3 0x56
#define DIK_F11 0x57
#define DIK_F12 0x58
#define DIK_F13 0x64
#define DIK_F14 0x65
#define DIK_F15 0x66
// extended (0x100)
#define DIK_SPECIAL4 0x100
#define DIK_NUMPADENTER 0x11C
#define DIK_RCONTROL 0x11D
#define DIK_NUMPADCOMMA 0x12C
#define DIK_DIVIDE 0x135
#define DIK_SYSRQ 0x137
#define DIK_RMENU 0x138
#define DIK_SPECIAL5 0x139
#define DIK_SPECIAL6 0x13A
#define DIK_SPECIAL7 0x13B
#define DIK_SPECIAL8 0x13C
#define DIK_HOME 0x147
#define DIK_UP 0x148
#define DIK_PRIOR 0x149
#define DIK_LEFT 0x14B
#define DIK_RIGHT 0x14D
#define DIK_END 0x14F
#define DIK_DOWN 0x150
#define DIK_NEXT 0x151
#define DIK_INSERT 0x152
#define DIK_DELETE 0x153
#define DIK_LWIN 0x15B
#define DIK_RWIN 0x15C
#define DIK_APPS 0x15D
#define DIK_POWER 0x15E
#define DIK_SLEEP 0x15F
#define DIK_WAKE 0x163
#define DIK_WEBSEARCH 0x165
#define DIK_WEBFAVORITES 0x166
#define DIK_WEBREFRESH 0x167
#define DIK_WEBHOME 0x168
#define DIK_PAUSE 0x145
#define DIK_BREAK 0x146
#define DIK_LALT DIK_LMENU
#define DIK_RALT DIK_RMENU
#define DIK_NUMPADMINUS DIK_SUBTRACT
#define DIK_NUMPADPERIOD DIK_DECIMAL
#define DIK_NUMPADPLUS DIK_ADD
#define DIK_NUMPADSLASH DIK_DIVIDE
#define DIK_NUMPADSTAR DIK_MULTIPLY
#define DIK_BACKSLASH2 DIK_BACKSLASH

#endif // XR_POSIX_DINPUT_H
