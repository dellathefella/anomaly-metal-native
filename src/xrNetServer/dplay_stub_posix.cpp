// dplay_stub_posix.cpp — DirectPlay 8 runtime stub for POSIX.
//
// macOS has no DirectPlay. xrEngine/xrNetServer link against this instead:
// CoCreateInstance hands out COM objects that fail every transport operation
// with a sane error code, so connection attempts degrade to clean error
// messages and singleplayer never touches these paths. Multiplayer hosting/
// joining over the DP transport is Windows-only by design (see
// Include/POSIXShims/dplay/dplay8.h).

#ifndef _WIN32

#include "stdafx.h"

namespace
{

// Canonical DirectPlay GUIDs (must match xrNetServer's definitions).
const GUID kCLSID_DirectPlay8Client =
	{0x743f1dc6, 0x5aba, 0x429f, {0x8b, 0xdf, 0xc5, 0x4d, 0x03, 0x25, 0x3d, 0xc2}};
const GUID kCLSID_DirectPlay8Server =
	{0xda825e1b, 0x6830, 0x43d7, {0x83, 0x5d, 0x0b, 0x5a, 0xd8, 0x29, 0x56, 0xa2}};
const GUID kCLSID_DirectPlay8Address =
	{0x934a9523, 0xa3ca, 0x4bc5, {0xad, 0xa0, 0xd6, 0xd9, 0x5d, 0x97, 0x94, 0x21}};
const GUID kIID_IDirectPlay8Client =
	{0x5102dacd, 0x241b, 0x11d3, {0xae, 0xa7, 0x00, 0x60, 0x97, 0xb0, 0x14, 0x11}};
const GUID kIID_IDirectPlay8Server =
	{0x5102dace, 0x241b, 0x11d3, {0xae, 0xa7, 0x00, 0x60, 0x97, 0xb0, 0x14, 0x11}};
const GUID kIID_IDirectPlay8Address =
	{0x83783300, 0x4063, 0x4c8a, {0x9d, 0xb3, 0x82, 0x83, 0x0a, 0x7f, 0xeb, 0x31}};

struct StubAddress : IDirectPlay8Address
{
	ULONG refs;
	GUID sp;

	StubAddress() : refs(1), sp() {}

	unsigned long WINAPI AddRef() override { return (unsigned long)__sync_add_and_fetch(&refs, 1); }
	unsigned long WINAPI Release() override
	{
		unsigned long r = (unsigned long)__sync_sub_and_fetch(&refs, 1);
		if (r == 0)
			delete this;
		return r;
	}

	HRESULT WINAPI GetSP(GUID** ppGuid) override
	{
		if (!ppGuid)
			return DPNERR_INVALIDPARAM;
		*ppGuid = new GUID(sp); // engine does not free this — leak is fine, stub
		return DPN_OK;
	}
	HRESULT WINAPI SetSP(const GUID* pguidSP) override
	{
		if (pguidSP)
			sp = *pguidSP;
		return DPN_OK;
	}
	HRESULT WINAPI AddComponent(DWORD, const void*, DWORD, DWORD) override { return DPN_OK; }
	HRESULT WINAPI GetComponentByName(DWORD, void*, DWORD*, DWORD*) override
	{
		return DPNERR_INVALIDOBJECT;
	}
	HRESULT WINAPI Duplicate(IDirectPlay8Address** ppAddress) override
	{
		if (!ppAddress)
			return DPNERR_INVALIDPARAM;
		StubAddress* copy = new StubAddress();
		copy->sp = sp;
		*ppAddress = copy;
		return DPN_OK;
	}
	HRESULT WINAPI GetURLA(char* pchURL, DWORD* pcchURL) override
	{
		if (pchURL && pcchURL && *pcchURL > 0)
			pchURL[0] = 0;
		return DPN_OK;
	}
};

struct StubClient : IDirectPlay8Client
{
	ULONG refs;
	StubClient() : refs(1) {}

	unsigned long WINAPI AddRef() override { return (unsigned long)__sync_add_and_fetch(&refs, 1); }
	unsigned long WINAPI Release() override
	{
		unsigned long r = (unsigned long)__sync_sub_and_fetch(&refs, 1);
		if (r == 0)
			delete this;
		return r;
	}

	HRESULT WINAPI Initialize(PVOID, PFNDPMESSAGECALLBACK, DWORD) override { return DPN_OK; }
	HRESULT WINAPI Close(DWORD) override { return DPN_OK; }
	HRESULT WINAPI Connect(DPN_APPLICATION_DESC*, IDirectPlay8Address*, IDirectPlay8Address*,
	                      void*, void*, const void*, DWORD, void*, DPNHANDLE*, DWORD) override
	{
		return DPNERR_CONNECT;
	}
	HRESULT WINAPI EnumHosts(DPN_APPLICATION_DESC*, IDirectPlay8Address*, IDirectPlay8Address*,
	                         const void*, DWORD, DWORD, DWORD, DWORD, void*, DPNHANDLE*,
	                         DWORD) override
	{
		return DPNERR_NORESPONSE;
	}
	HRESULT WINAPI Send(DPN_BUFFER_DESC*, DWORD, DWORD, void*, DPNHANDLE*, DWORD) override
	{
		return DPNERR_CONNECTIONLOST;
	}
	HRESULT WINAPI GetConnectionInfo(DPN_CONNECTION_INFO*, DWORD) override
	{
		return DPNERR_NOTAVAILABLE;
	}
	HRESULT WINAPI GetSendQueueInfo(DWORD* pdwPending, DWORD*, DWORD) override
	{
		if (pdwPending)
			*pdwPending = 0;
		return DPNERR_NOTAVAILABLE;
	}
	HRESULT WINAPI GetApplicationDesc(DPN_APPLICATION_DESC*, DWORD*, DWORD) override
	{
		return DPNERR_INVALIDOBJECT;
	}
	HRESULT WINAPI SetClientInfo(DPN_PLAYER_INFO*, const void*, DWORD, DWORD) override
	{
		return DPN_OK;
	}
};

struct StubServer : IDirectPlay8Server
{
	ULONG refs;
	StubServer() : refs(1) {}

	unsigned long WINAPI AddRef() override { return (unsigned long)__sync_add_and_fetch(&refs, 1); }
	unsigned long WINAPI Release() override
	{
		unsigned long r = (unsigned long)__sync_sub_and_fetch(&refs, 1);
		if (r == 0)
			delete this;
		return r;
	}

	HRESULT WINAPI Initialize(PVOID, PFNDPMESSAGECALLBACK, DWORD) override { return DPN_OK; }
	HRESULT WINAPI Close(DWORD) override { return DPN_OK; }
	HRESULT WINAPI Host(DPN_APPLICATION_DESC*, IDirectPlay8Address**, DWORD, void*, void*,
	                    const void*, DWORD) override
	{
		return DPNERR_CONNECT;
	}
	HRESULT WINAPI DestroyClient(DPNID, const void*, DWORD, DWORD) override
	{
		return DPNERR_INVALIDPLAYER;
	}
	HRESULT WINAPI GetClientInfo(DPNID, DPN_PLAYER_INFO*, DWORD*, DWORD) override
	{
		return DPNERR_INVALIDPLAYER;
	}
	HRESULT WINAPI SetServerInfo(DPN_PLAYER_INFO*, const void*, DWORD, DWORD) override
	{
		return DPN_OK;
	}
	HRESULT WINAPI GetConnectionInfo(DPNID, DPN_CONNECTION_INFO*, DWORD) override
	{
		return DPNERR_NOTAVAILABLE;
	}
	HRESULT WINAPI GetSendQueueInfo(DPNID, DWORD* pdwPending, DWORD*, DWORD) override
	{
		if (pdwPending)
			*pdwPending = 0;
		return DPNERR_NOTAVAILABLE;
	}
	HRESULT WINAPI SendTo(DPNID, DPN_BUFFER_DESC*, DWORD, DWORD, void*, DPNHANDLE*, DWORD) override
	{
		return DPNERR_CONNECTIONLOST;
	}
};

} // namespace

HRESULT CoCreateInstance(REFCLSID rclsid, void*, DWORD, REFIID riid, LPVOID* ppv)
{
	if (!ppv)
		return DPNERR_INVALIDPARAM;
	*ppv = nullptr;

	if (rclsid == kCLSID_DirectPlay8Address && riid == kIID_IDirectPlay8Address)
	{
		*ppv = new StubAddress();
		return DPN_OK;
	}
	if (rclsid == kCLSID_DirectPlay8Client && riid == kIID_IDirectPlay8Client)
	{
		*ppv = new StubClient();
		return DPN_OK;
	}
	if (rclsid == kCLSID_DirectPlay8Server && riid == kIID_IDirectPlay8Server)
	{
		*ppv = new StubServer();
		return DPN_OK;
	}
	return DPNERR_NOTAVAILABLE; // CLASS_E_CLASSNOTAVAILABLE equivalent
}

#endif // !_WIN32
