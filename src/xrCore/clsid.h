#ifndef _CLSID_H
#define _CLSID_H

#pragma once

//***** CLASS ID type
typedef u64 CLASS_ID;
#define MK_CLSID(a,b,c,d,e,f,g,h) \
 CLASS_ID((CLASS_ID(a)<<CLASS_ID(56))|(CLASS_ID(b)<<CLASS_ID(48))|(CLASS_ID(c)<<CLASS_ID(40))|(CLASS_ID(d)<<CLASS_ID(32))|(CLASS_ID(e)<<CLASS_ID(24))|(CLASS_ID(f)<<CLASS_ID(16))|(CLASS_ID(g)<<CLASS_ID(8))|(CLASS_ID(h)))

#define MK_CLSID_INV(a,b,c,d,e,f,g,h) MK_CLSID(h,g,f,e,d,c,b,a)

// p4 GL-renderer port: OpenXRay's constexpr 8-char CLASS_ID builders (identical
// packing to MK_CLSID above; staged blender CLSID tables call make_clsid).
namespace xray
{
constexpr CLASS_ID make_clsid(const char (&str)[9])
{
	return CLASS_ID(CLASS_ID(str[0]) << CLASS_ID(56) | CLASS_ID(str[1]) << CLASS_ID(48) | CLASS_ID(str[2]) << CLASS_ID(40) | CLASS_ID(str[3]) << CLASS_ID(32) | CLASS_ID(str[4]) << CLASS_ID(24) | CLASS_ID(str[5]) << CLASS_ID(16) | CLASS_ID(str[6]) << CLASS_ID(8) | CLASS_ID(str[7]));
}

constexpr CLASS_ID make_clsid(const char a, const char b, const char c, const char d, const char e, const char f, const char g, const char h)
{
	return MK_CLSID(a, b, c, d, e, f, g, h);
}
} // namespace xray

extern XRCORE_API void __stdcall CLSID2TEXT(CLASS_ID id, LPSTR text);
extern XRCORE_API CLASS_ID __stdcall TEXT2CLSID(LPCSTR text);

#endif
