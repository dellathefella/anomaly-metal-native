// dplay/dplay8.h — POSIX (macOS) shim for Microsoft DirectPlay 8.
//
// xrNetServer's transport layer is written against DirectPlay 8. macOS has no
// DirectPlay; this shim provides the type/interface surface the engine needs
// to compile. Method signatures mirror the call sites in xrNetServer (which
// uses X-Ray's DP fork conventions, not canonical MS dplay8.h). At runtime the
// engine links against a stub implementation (xrDPlayStub) whose COM objects
// fail every operation, so hosting/joining a game fails gracefully while
// singleplayer stays unaffected. Multiplayer over this path is Windows-only.
//
// The GUID/IID values are the canonical Microsoft ones; the interface VTABLES
// are NOT the Microsoft ABI — both xrNetServer and the stub compile against
// this header, so they are self-consistent.
#ifndef XR_POSIX_DPLAY_DPLAY8_H
#define XR_POSIX_DPLAY_DPLAY8_H

#include <stdint.h>

// DWORD / HRESULT / GUID / BOOL come from xrCore's win_compat + PlatformApple
// via stdafx (dplay8.h is always included after them).

typedef DWORD DPNID;
typedef DWORD DPNHANDLE;

#ifndef XR_POSIX_WCHAR_DEFINED
#define XR_POSIX_WCHAR_DEFINED
typedef unsigned short WCHAR;
typedef WCHAR* LPWSTR;
typedef const WCHAR* LPCWSTR;
#endif

// ---------------------------------------------------------------------------
// Well-known CLSIDs / IIDs (canonical values; xrNetServer defines the objects)
// ---------------------------------------------------------------------------
extern const GUID CLSID_DirectPlay8Client;
extern const GUID CLSID_DirectPlay8Server;
extern const GUID CLSID_DirectPlay8Peer;
extern const GUID CLSID_DirectPlay8Address;
extern const GUID IID_IDirectPlay8Client;
extern const GUID IID_IDirectPlay8Server;
extern const GUID IID_IDirectPlay8Address;

// ---------------------------------------------------------------------------
// Result codes (values only need to be unique — never cross a Windows wire)
// ---------------------------------------------------------------------------
#define DPN_OK 0L
#define DPNERR_GENERIC ((HRESULT)0x80004005L)
#define DPNERR_PENDING ((HRESULT)0x000000E7L) // S_FALSE-like
#define DPNSUCCESS_PENDING ((HRESULT)0x000000E7L)
#define DPNERR_NOTAVAILABLE ((HRESULT)0x80004006L)
#define DPNERR_NOTALLOWED ((HRESULT)0x80004007L)
#define DPNERR_ALREADYCONNECTED ((HRESULT)0x80004008L)
#define DPNERR_CONNECT ((HRESULT)0x80004009L)
#define DPNERR_TIMEOUT ((HRESULT)0x8000400AL)
#define DPNERR_INVALIDPARAM ((HRESULT)0x8000400BL)
#define DPNERR_INVALIDINTERFACE ((HRESULT)0x8000400CL)
#define DPNERR_INVALIDOBJECT ((HRESULT)0x8000400DL)
#define DPNERR_INVALIDPLAYER ((HRESULT)0x8000400EL)
#define DPNERR_INVALIDGROUP ((HRESULT)0x8000400FL)
#define DPNERR_INVALIDHANDLE ((HRESULT)0x80004010L)
#define DPNERR_INVALIDHOSTADDRESS ((HRESULT)0x80004011L)
#define DPNERR_INVALIDPASSWORD ((HRESULT)0x80004012L)
#define DPNERR_HOSTFULL ((HRESULT)0x80004013L)
#define DPNERR_SESSIONFULL ((HRESULT)0x80004014L)
#define DPNERR_USERFULL ((HRESULT)0x80004015L)
#define DPNERR_CONNECTIONLOST ((HRESULT)0x80004016L)
#define DPNERR_CANTCREATEPLAYER ((HRESULT)0x80004017L)
#define DPNERR_TERMINATED ((HRESULT)0x80004018L)
#define DPNERR_NOTHOST ((HRESULT)0x80004019L)
#define DPNERR_HOSTRENTED ((HRESULT)0x8000401AL)
#define DPNERR_HOSTEXISTS ((HRESULT)0x8000401BL)
#define DPNERR_HOSTDOESNOTEXIST ((HRESULT)0x8000401CL)
#define DPNERR_SECURITYFAILED ((HRESULT)0x8000401DL)
#define DPNERR_BUFFERTOOSMALL ((HRESULT)0x8000401EL)
#define DPNERR_NORESPONSE ((HRESULT)0x8000401FL)
#define DPNERR_NOTALLOWEDTOHOST ((HRESULT)0x80004020L)
#define DPNERR_LOBBYCONNECTFAILED ((HRESULT)0x80004021L)
#define DPNERR_ALREADYLOBBY ((HRESULT)0x80004022L)
#define DPNERR_NOTLOBBY ((HRESULT)0x80004023L)
#define DPNERR_PEEREXISTS ((HRESULT)0x80004024L)
#define DPNERR_RETURNEDTOLOBBY ((HRESULT)0x80004025L)
#define DPNERR_INCOMINGCALLREJECTED ((HRESULT)0x80004026L)
#define DPNERR_INCOMINGPENDING ((HRESULT)0x80004027L)
#define DPNERR_USERBANNED ((HRESULT)0x80004028L)
#define DPNERR_USERKICKED ((HRESULT)0x80004029L)
#define DPNERR_USERBANNEDKICKED ((HRESULT)0x8000402AL)
#define DPNERR_HOSTMIGRATIONREQUIRED ((HRESULT)0x8000402BL)
#define DPNERR_HOSTMIGRATIONFAILED ((HRESULT)0x8000402CL)
#define DPNERR_INVALIDCONNECTIONTYPE ((HRESULT)0x8000402DL)
#define DPNERR_DIRECTCONNECTFAILED ((HRESULT)0x8000402EL)

// ---------------------------------------------------------------------------
// Message ids (canonical numbering)
// ---------------------------------------------------------------------------
enum
{
	DPN_MSGID_CREATE_PLAYER = 0x1,
	DPN_MSGID_DESTROY_PLAYER = 0x2,
	DPN_MSGID_CREATE_GROUP = 0x3,
	DPN_MSGID_DESTROY_GROUP = 0x4,
	DPN_MSGID_GROUP_INFO = 0x5,
	DPN_MSGID_ADD_PLAYER_TO_GROUP = 0x6,
	DPN_MSGID_REMOVE_PLAYER_FROM_GROUP = 0x7,
	DPN_MSGID_CHAT_EVENT = 0x8,
	DPN_MSGID_SECURITY_FAILED = 0x9,
	DPN_MSGID_ASYNC_OP_COMPLETE = 0xA,
	DPN_MSGID_CLIENT_INFO = 0xB,
	DPN_MSGID_SERVER_INFO = 0xC,
	DPN_MSGID_CONNECT = 0xD,
	DPN_MSGID_INDICATE_CONNECT = 0xE,
	DPN_MSGID_INDICATED_CONNECT_ABORTED = 0xF,
	DPN_MSGID_CONNECTION_REQUEST = 0x10,
	DPN_MSGID_CONNECT_REQUEST = 0x10, // legacy alias
	DPN_MSGID_CONNECT_COMPLETE = 0x11,
	DPN_MSGID_SEND_COMPLETE = 0x12,
	DPN_MSGID_CREATE_SESSION = 0x13,
	DPN_MSGID_TERMINATE_SESSION = 0x14,
	DPN_MSGID_HOST_MIGRATE = 0x15,
	DPN_MSGID_SENDTO_ACK = 0x16,
	DPN_MSGID_SENDTO_NAK = 0x17,
	DPN_MSGID_DESTROY_SESSION = 0x18,
	DPN_MSGID_PEER_INFO = 0x19,
	DPN_MSGID_LOBBY_DESTROY_LOBBY_HOST = 0x1A,
	DPN_MSGID_RETURN_BUFFER = 0x1B,
	DPN_MSGID_LOST_CONNECTION = 0x1C,
	DPN_MSGID_DIRECT_CONNECT_FAILED = 0x1D,
	DPN_MSGID_ENUM_HOSTS_QUERY = 0x1E,
	DPN_MSGID_ENUM_HOSTS_RESPONSE = 0x1F,
	DPN_MSGID_RECEIVE = 0x20,
	DPN_MSGID_COMMAND_HOST = 0x21,
	DPN_MSGID_EXECUTE_CLIENT = 0x22,
	DPN_MSGID_MAX = 0x23
};

// ---------------------------------------------------------------------------
// Flags / constants
// ---------------------------------------------------------------------------
#define DPNSESSION_NODPNSVR 0x00000001
#define DPNSESSION_IMPORTSESSION 0x00000002
#define DPNSESSION_SHOWPLATFORMSPECIFICCONVERSATION 0x00000004
#define DPNSESSION_VOICE 0x00000008
#define DPNSESSION_MIGRATE_HOST 0x00000010
#define DPNSESSION_ENUMHOSTS 0x00000020
#define DPNSESSION_FULLPEERMIGRATION 0x00000040
#define DPNSESSION_CLIENT_SERVER 0x00000080
#define DPNSESSION_REQUIREPASSWORD 0x00000100
#define DPNSESSION_NOCLIENTS 0x00000200
#define DPNSESSION_LIMITED 0x00000400
#define DPNSESSION_SECURE_DP 0x00000800

#define DPNCONNECT_SYNC 0x00000001
#define DPNCONNECT_OKTOQUERYFORADDRESSING 0x00000002

#define DPNSEND_IMMEDIATELLY 0x1 // sic (typo preserved from MS header)
#define DPNSEND_COALESCE 0x2
#define DPNSEND_IMMEDIATELY 0x1
#define DPNSEND_LOCALECHO 0x4
#define DPNSEND_GUARANTEED 0x8
#define DPNSEND_WITH_SESSIONID 0x100
#define DPNSEND_NONSEQUENTIAL 0x20
#define DPNSEND_NOLOOPBACK 0x40
#define DPNSEND_PRIORITY_LOW 0x80
#define DPNSEND_PRIORITY_HIGH 0x100
#define DPNSEND_NOCOMPLETE 0x200
#define DPNSEND_NAGLE 0x400
#define DPNSEND_NOT_WITH_SESSIONID 0x800

#define DPNENUMHOSTS_OKTOQUERYFORADDRESSING 0x1
#define DPNENUMHOSTS_SENDEVERYLOBBY 0x2
#define DPNENUMHOSTS_USENATRESOLVER 0x4
#define DPNENUMHOSTS_SYNCFILTER 0x8
#define DPNENUMHOSTS_SYNC 0x10

#define DPNINITIALIZE_DISABLEPARAMVAL 0x1
#define DPNINITIALIZE_NOLOBBY 0x2

#define DPNSETCLIENTINFO_SYNC 0x1
#define DPNSETSERVERINFO_SYNC 0x1

#define DPNCLOSE_WAITFORQUITTASKS 0x1

#define DPNDESTROYPLAYER_SYNC 0x1
#define DPNDESTROYCLIENT_SYNC 0x1

// Address component keys/datatypes (canonical values)
#define DPNA_DATATYPE_INVALID 0
#define DPNA_DATATYPE_DWORD 1
#define DPNA_DATATYPE_GUID 2
#define DPNA_DATATYPE_STRING 3
#define DPNA_DATATYPE_BINARY 4
#define DPNA_KEY_SP 0x00000001
#define DPNA_KEY_HOSTNAME 0x00000400
#define DPNA_KEY_PORT 0x00000401
#define DPNA_KEY_APPLICATION_INSTANCE 0x00000402
#define DPNA_KEY_PEERS 0x00000403
#define DPNA_KEY_COMMITS 0x00000404
#define DPNA_KEY_NAT_RESOLVER_SP 0x00000405
#define DPNA_KEY_NAT_RESOLVERS 0x00000406
#define DPNA_KEY_LTM_SP 0x00000407
#define DPNA_KEY_LTM_HOSTS 0x00000408
#define DPNA_KEY_LTM_HOST_TIMEOUT 0x00000409
#define DPNA_KEY_LTM_HOST_RETIRES 0x0000040A
#define DPNA_KEY_TRAVERSALMODE 0x0000040B
#define DPNA_KEY_BURNING 0x0000040C
#define DPNA_KEY_SENDFLAGS 0x0000040D
#define DPNA_KEY_REQUESTEDSENDLAG 0x0000040E
#define DPNA_KEY_AGENT_ADDRESS 0x0000040F
#define DPNA_KEY_RTO 0x00000501
#define DPNA_KEY_RCVWIN 0x00000502
#define DPNA_KEY_SNDWIN 0x00000503
#define DPNA_KEY_MAXBANDWIDTH 0x00000504
#define DPNA_KEY_SOURCE 0xFEDCBA98
#define DPNA_KEY_TARGET 0x89ABCDEF
#define DPNA_KEY_HOSTINTERFACE 0x00000601
#define DPNA_KEY_PEERINTERFACE 0x00000602
#define DPNA_KEY_METACONNECTION 0x00000603
#define DPNA_KEY_MINBANDWIDTH 0x00000605
#define DPNA_KEY_MAXRTF 0x00000606
#define DPNA_KEY_MAXMTU 0x00000607
#define DPNA_KEY_RESOLVERS 0x00000608
#define DPNA_KEY_RESOLVER 0x00000609

#define DPNA_TRAVERSALMODE_NONE 1
#define DPNA_TRAVERSALMODE_AGENT 2
#define DPNA_TRAVERSALMODE_PORTSCAN 3

// Player/group info flags
#define DPNINFO_NAME 0x00000001
#define DPNINFO_DATA 0x00000002
#define DPNINFO_NICKNAME 0x00000004

#define DPNPLAYER_LOCAL 0x00000002
#define DPNPLAYER_HOST 0x00000004
#define DPNPLAYER_LOWLat 0x00000010
#define DPNPLAYER_Good 0x00000020
#define DPNPLAYER_HighLat 0x00000040
#define DPNPLAYER_CLIENT 0x00000080

// Client/server info change flags (DPNMSG_CLIENT_INFO/SERVER_INFO dwFlags)
#define DPNSERVER_INFO 0x00000001
#define DPNSERVER_NAME 0x00000002
#define DPNSERVER_LOBBY 0x00000004
#define DPNCLIENT_INFO 0x00000001
#define DPNCLIENT_NAME 0x00000002
#define DPNCLIENT_NICKNAME 0x00000004

// ---------------------------------------------------------------------------
// Core structures
// ---------------------------------------------------------------------------
typedef struct _DPN_APPLICATION_DESC
{
	DWORD dwSize;
	DWORD dwFlags;
	GUID guidApplication;
	GUID guidInstance;
	DWORD dwCurrentPlayers;
	DWORD dwMaxPlayers;
	WCHAR* pwszSessionName;
	WCHAR* pwszPassword;
	void* pvReservedData;
	DWORD dwReservedDataSize;
	void* pvApplicationReservedData;
	DWORD dwApplicationReservedDataSize;
	// DP fork extras
	DWORD dwPrivateDataSize;
	void* pvPrivateData;
	WCHAR unused[4];
} DPN_APPLICATION_DESC, *PDPN_APPLICATION_DESC;

typedef struct _DPN_BUFFER_DESC
{
	void* pvData;
	DWORD dwDataSize;
} DPN_BUFFER_DESC, *PDPN_BUFFER_DESC;

typedef struct _DPN_CONNECTION_INFO
{
	DWORD dwSize;
	DWORD roundTripTime;
	DWORD bandwidthIn;
	DWORD bandwidthOut;
	float connectionQuality;
	DWORD dwMessagesReceived;
	DWORD dwMessagesTransmittedHighPriority;
	DWORD dwMessagesTransmittedNormalPriority;
	DWORD dwMessagesTransmittedLowPriority;
	// X-Ray DP-fork statistics fields (net_shared.h)
	DWORD dwPacketsDropped;
	DWORD dwPacketsRetried;
	DWORD dwPeakThroughputBPS;
	DWORD dwRoundTripLatencyMS;
	DWORD dwThroughputBPS;
} DPN_CONNECTION_INFO, *PDPN_CONNECTION_INFO;

typedef struct _DPN_PLAYER_INFO
{
	DWORD dwSize;
	DWORD dwInfoFlags;
	// game version fields kept opaque but present for layout sanity
	DWORD dwVersionMajor;
	DWORD dwVersionMinor;
	DWORD dwVersionBuild;
	DWORD dwVersionRevision;
	WCHAR* pwszName;
	void* pvData;
	DWORD dwDataSize;
	DWORD dwPlayerFlags;
	WCHAR* pwszNickName;
} DPN_PLAYER_INFO, *PDPN_PLAYER_INFO;

typedef struct _DPN_GROUP_INFO
{
	DWORD dwSize;
	DWORD dwInfoFlags;
	WCHAR* pwszName;
	void* pvData;
	DWORD dwDataSize;
} DPN_GROUP_INFO, *PDPN_GROUP_INFO;

// ---------------------------------------------------------------------------
// Message structures (only fields xrNetServer touches are meaningful)
// ---------------------------------------------------------------------------
struct IDirectPlay8Address;

typedef struct _DPNMSG_CONNECT_COMPLETE
{
	DPNID idSession;
	DPNHANDLE hAsync;
	HRESULT hrResult;
	DPNID dpnidSponsor;
	DPN_APPLICATION_DESC* pApplicationDesc;
	IDirectPlay8Address* pAddressServer;
	IDirectPlay8Address* pAddressPlayer;
	DPN_CONNECTION_INFO* pConnectionInfo;
	void* pvApplicationReplyData;
	DWORD dwApplicationReplyDataSize;
	void* pvData;
	DWORD dwDataSize;
} DPNMSG_CONNECT_COMPLETE, *PDPNMSG_CONNECT_COMPLETE;

typedef struct _DPNMSG_RECEIVE
{
	DPNID idSession;
	DPNID dpnidSender;
	void* pReceiveData;
	DWORD dwReceiveDataSize;
	DPNHANDLE hUserHandle;
} DPNMSG_RECEIVE, *PDPNMSG_RECEIVE;

typedef struct _DPNMSG_SEND_COMPLETE
{
	DPNID idSession;
	DPNHANDLE hAsync;
	HRESULT hrResult;
	DPNHANDLE hUserHandle;
} DPNMSG_SEND_COMPLETE, *PDPNMSG_SEND_COMPLETE;

typedef struct _DPNMSG_TERMINATE_SESSION
{
	DPNID idSession;
	BOOL fForceTerminate;
	void* pvTerminateData;
	DWORD dwTerminateDataSize;
	HRESULT hResultCode;
} DPNMSG_TERMINATE_SESSION, *PDPNMSG_TERMINATE_SESSION;

typedef struct _DPNMSG_CREATE_PLAYER
{
	DPNID idSession;
	DPNID dpnidPlayer;
	void* pvPlayerContext;
} DPNMSG_CREATE_PLAYER, *PDPNMSG_CREATE_PLAYER;

typedef struct _DPNMSG_DESTROY_PLAYER
{
	DPNID idSession;
	DPNID dpnidPlayer;
	void* pvPlayerContext;
	DWORD dwPlayerContextSize;
	// fork extension: reason
	void* pvData;
	DWORD dwDataSize;
} DPNMSG_DESTROY_PLAYER, *PDPNMSG_DESTROY_PLAYER;

typedef struct _DPNMSG_CONNECT
{
	DPNID idSession;
	DPNID dpnidSponsor;
	IDirectPlay8Address* pAddressSource;
	DPN_APPLICATION_DESC* pApplicationDesc;
	void* pvData;
	DWORD dwDataSize;
	WCHAR* pwszPassword;
	void** ppvPlayerData;
	DWORD* pdwPlayerDataSize;
} DPNMSG_CONNECT, *PDPNMSG_CONNECT;

typedef struct _DPNMSG_INDICATE_CONNECT
{
	DPNID idSession;
	DPNID dpnidSponsor;
	DPN_APPLICATION_DESC* pApplicationDesc;
	void** ppvPlayerData;
	DWORD* pdwPlayerDataSize;
	IDirectPlay8Address* pAddressPlayer;
	void* pvReplyData;
	DWORD dwReplyDataSize;
} DPNMSG_INDICATE_CONNECT, *PDPNMSG_INDICATE_CONNECT;

typedef struct _DPNMSG_INDICATED_CONNECT_ABORTED
{
	DPNID idSession;
	DPNID dpnidNewPlayer;
	void* pvPlayerData;
	DWORD dwPlayerDataSize;
	void* pvReplyData;
	DWORD dwReplyDataSize;
} DPNMSG_INDICATED_CONNECT_ABORTED, *PDPNMSG_INDICATED_CONNECT_ABORTED;

typedef struct _DPNMSG_CLIENT_INFO
{
	DPNID idSession;
	DPNID dpnidPlayer;
	DWORD dwMessageId;
	DWORD dwFlags;
	DWORD dwFlagsChangeMask;
	// game version
	DWORD dwVersionMajor;
	DWORD dwVersionMinor;
	DWORD dwVersionBuild;
	DWORD dwVersionRevision;
	WCHAR* pwszName;
	WCHAR* pwszNickName;
	IDirectPlay8Address* pAddress;
	void* pvData;
	DWORD dwDataSize;
} DPNMSG_CLIENT_INFO, *PDPNMSG_CLIENT_INFO;

typedef struct _DPNMSG_SERVER_INFO
{
	DPNID idSession;
	DWORD dwMessageId;
	DWORD dwFlags;
	DWORD dwFlagsChangeMask;
	DWORD dwVersionMajor;
	DWORD dwVersionMinor;
	DWORD dwVersionBuild;
	DWORD dwVersionRevision;
	WCHAR* pwszServerName;
	WCHAR* pwszServerVersion;
	WCHAR* pwszUserInfo;
	IDirectPlay8Address* pAddressPreferredServer;
	DWORD dwUpdateRate;
	DWORD dwTimeout;
	DWORD dwMaxPlayers;
	DWORD dwCurrentPlayers;
} DPNMSG_SERVER_INFO, *PDPNMSG_SERVER_INFO;

typedef struct _DPNMSG_GROUP_INFO
{
	DPNID idSession;
	DPNID dpnidGroup;
	DPNID dpnidGroupOwner;
	DWORD dwMessageId;
	DWORD dwFlags;
	DWORD dwFlagsChangeMask;
	WCHAR* pwszName;
	void* pvData;
	DWORD dwDataSize;
} DPNMSG_GROUP_INFO, *PDPNMSG_GROUP_INFO;

typedef struct _DPNMSG_PEER_INFO
{
	DPNID idSession;
	DPNID dpnidPlayer;
	DWORD dwMessageId;
	DWORD dwFlags;
	DWORD dwFlagsChangeMask;
	DWORD dwVersionMajor;
	DWORD dwVersionMinor;
	DWORD dwVersionBuild;
	DWORD dwVersionRevision;
	WCHAR* pwszName;
	IDirectPlay8Address* pAddress;
	void* pvData;
	DWORD dwDataSize;
} DPNMSG_PEER_INFO, *PDPNMSG_PEER_INFO;

typedef struct _DPNMSG_ENUM_HOSTS_QUERY
{
	DPNID idSession;
	IDirectPlay8Address* pAddressSender;
	IDirectPlay8Address* pAddressDestination;
	DPN_APPLICATION_DESC* pApplicationDescription;
	void* pvReceivedData;
	DWORD dwReceivedDataSize;
	void** ppvResponseData;
	DWORD* pdwResponseDataSize;
	DPN_CONNECTION_INFO* pConnectionInfo;
	DWORD dwRetryCount;
	DWORD dwRetryIndex;
} DPNMSG_ENUM_HOSTS_QUERY, *PDPNMSG_ENUM_HOSTS_QUERY;

typedef struct _DPNMSG_ENUM_HOSTS_RESPONSE
{
	DPNID idSession;
	IDirectPlay8Address* pAddressSender;
	DPN_APPLICATION_DESC* pApplicationDescription;
	void* pvReplyData;
	DWORD dwReplyDataSize;
	DPN_CONNECTION_INFO* pConnectionInfo;
	void* pvReceivedData;
	DWORD dwReceivedDataSize;
	DWORD dwRetryCount;
	DWORD dwRetryIndex;
} DPNMSG_ENUM_HOSTS_RESPONSE, *PDPNMSG_ENUM_HOSTS_RESPONSE;

typedef struct _DPNMSG_HOST_MIGRATE
{
	DPNID idSession;
	DPNID dpnidOldHost;
	DPNID dpnidNewHost;
	void* pvPlayerData;
	DWORD dwPlayerDataSize;
} DPNMSG_HOST_MIGRATE, *PDPNMSG_HOST_MIGRATE;

typedef struct _DPNMSG_ASYNC_OP_COMPLETE
{
	DPNID idSession;
	DPNHANDLE hAsync;
	HRESULT hrResult;
} DPNMSG_ASYNC_OP_COMPLETE, *PDPNMSG_ASYNC_OP_COMPLETE;

typedef struct _DPNMSG_ADD_PLAYER_TO_GROUP
{
	DPNID idSession;
	DPNID dpnidGroup;
	DPNID dpnidGroupOwner;
	DPNID dpnidPlayer;
	void* pvUserContext;
} DPNMSG_ADD_PLAYER_TO_GROUP, *PDPNMSG_ADD_PLAYER_TO_GROUP;

typedef struct _DPNMSG_REMOVE_PLAYER_FROM_GROUP
{
	DPNID idSession;
	DPNID dpnidGroup;
	DPNID dpnidGroupOwner;
	DPNID dpnidPlayer;
	void* pvUserContext;
} DPNMSG_REMOVE_PLAYER_FROM_GROUP, *PDPNMSG_REMOVE_PLAYER_FROM_GROUP;

typedef struct _DPNMSG_CREATE_GROUP
{
	DPNID idSession;
	DPNID dpnidGroup;
	DPNID dpnidGroupOwner;
	void* pvGroupContext;
} DPNMSG_CREATE_GROUP, *PDPNMSG_CREATE_GROUP;

typedef struct _DPNMSG_DESTROY_GROUP
{
	DPNID idSession;
	DPNID dpnidGroup;
	DPNID dpnidGroupOwner;
	void* pvGroupContext;
	DWORD dwGroupContextSize;
} DPNMSG_DESTROY_GROUP, *PDPNMSG_DESTROY_GROUP;

typedef struct _DPNMSG_RETURN_BUFFER
{
	DPNID idSession;
	void* pvBuffer;
	void* pvContext;
} DPNMSG_RETURN_BUFFER, *PDPNMSG_RETURN_BUFFER;

typedef struct _DPNMSG_DESTROY_SESSION
{
	DPNID idSession;
	DPN_APPLICATION_DESC* pApplicationDesc;
	IDirectPlay8Address* pAddressHost;
} DPNMSG_DESTROY_SESSION, *PDPNMSG_DESTROY_SESSION;

typedef struct _DPNMSG_LOST_CONNECTION
{
	DPNID idSession;
	HRESULT hrResult;
	IDirectPlay8Address* pAddress;
} DPNMSG_LOST_CONNECTION, *PDPNMSG_LOST_CONNECTION;

typedef struct _DPNMSG_DIRECT_CONNECT_FAILED
{
	DPNID idSession;
	DPNID dpnidPlayer;
	IDirectPlay8Address* pAddress;
	HRESULT hrResult;
} DPNMSG_DIRECT_CONNECT_FAILED, *PDPNMSG_DIRECT_CONNECT_FAILED;

typedef struct _DPNMSG_SECURITY_FAILED
{
	DPNID idSession;
	DPNID dpnidPlayer;
	IDirectPlay8Address* pAddress;
	HRESULT hrResult;
	DWORD dwDataSize;
	void* pvData;
} DPNMSG_SECURITY_FAILED, *PDPNMSG_SECURITY_FAILED;

typedef struct _DPNMSG_ADDTOGROUP_COMPLETE
{
	DPNID idSession;
	DPNHANDLE hAsync;
	HRESULT hrResult;
} DPNMSG_ADDTOGROUP_COMPLETE, *PDPNMSG_ADDTOGROUP_COMPLETE;

// ---------------------------------------------------------------------------
// Message handler callback
// ---------------------------------------------------------------------------
typedef HRESULT(WINAPI* PFNDPMESSAGECALLBACK)(PVOID pvUserContext, DWORD dwMessageType, PVOID pMessage);
typedef PFNDPMESSAGECALLBACK PDPMSGHANDLER;

// ---------------------------------------------------------------------------
// Interfaces (pure virtual; implemented by the runtime stub)
// ---------------------------------------------------------------------------
struct IDirectPlay8Address
{
	virtual HRESULT WINAPI QueryInterface(const GUID&, void**) { return DPNERR_NOTAVAILABLE; }
	virtual unsigned long WINAPI AddRef() = 0;
	virtual unsigned long WINAPI Release() = 0;

	virtual HRESULT WINAPI GetAddressableType(GUID* pType) { if (pType) *pType = GUID{}; return DPN_OK; }
	virtual HRESULT WINAPI GetAddressableTypeName(WCHAR*, DWORD*, DWORD) { return DPNERR_NOTAVAILABLE; }
	virtual HRESULT WINAPI GetAddressableTypeSize(DWORD*, DWORD) { return DPNERR_NOTAVAILABLE; }
	virtual HRESULT WINAPI GetSP(GUID** ppGuid) = 0;
	virtual HRESULT WINAPI GetSPSize(DWORD*, DWORD) { return DPNERR_NOTAVAILABLE; }
	virtual HRESULT WINAPI SetSP(const GUID* pguidSP) = 0;
	virtual HRESULT WINAPI AddComponent(DWORD guidKey, const void* pvData, DWORD dwSize, DWORD dwDataType) = 0;
	virtual HRESULT WINAPI GetComponent(DWORD, void*, DWORD*, DWORD*, DWORD) { return DPNERR_NOTAVAILABLE; }
	virtual HRESULT WINAPI GetComponentByIndex(DWORD, GUID*, void*, DWORD*, DWORD*, DWORD) { return DPNERR_NOTAVAILABLE; }
	virtual HRESULT WINAPI GetComponentCount(DWORD* pdwCount) { if (pdwCount) *pdwCount = 0; return DPN_OK; }
	virtual HRESULT WINAPI GetComponentByName(DWORD guidKey, void* pvData, DWORD* pdwSize, DWORD* pdwDataType) = 0;
	virtual HRESULT WINAPI Duplicate(IDirectPlay8Address** ppAddress) = 0;
	virtual HRESULT WINAPI SetMethod(const char*, const GUID*) { return DPNERR_NOTAVAILABLE; }
	virtual HRESULT WINAPI GetMethod(char*, DWORD*, GUID*) { return DPNERR_NOTAVAILABLE; }
	virtual HRESULT WINAPI GetURLA(char* pchURL, DWORD* pcchURL) = 0;
	virtual HRESULT WINAPI GetURLW(WCHAR*, DWORD*) { return DPNERR_NOTAVAILABLE; }
};

struct IDirectPlay8Client
{
	virtual HRESULT WINAPI QueryInterface(const GUID&, void**) { return DPNERR_NOTAVAILABLE; }
	virtual unsigned long WINAPI AddRef() = 0;
	virtual unsigned long WINAPI Release() = 0;

	virtual HRESULT WINAPI Initialize(PVOID pvUserContext, PFNDPMESSAGECALLBACK pMsgCallback, DWORD dwFlags) = 0;
	virtual HRESULT WINAPI Close(DWORD dwFlags) = 0;
	virtual HRESULT WINAPI Connect(
		DPN_APPLICATION_DESC* pdnAppDesc,
		IDirectPlay8Address* pHostAddr,
		IDirectPlay8Address* pDeviceInfo,
		void* pdnSecurity,
		void* pdnCredentials,
		const void* pvUserConnectData,
		DWORD dwUserConnectDataSize,
		void* pvAsyncContext,
		DPNHANDLE* phAsyncHandle,
		DWORD dwFlags) = 0;
	virtual HRESULT WINAPI Disconnect(DPNHANDLE hAsync, DWORD dwFlags) { (void)hAsync; (void)dwFlags; return DPNERR_NOTAVAILABLE; }
	virtual HRESULT WINAPI EnumHosts(
		DPN_APPLICATION_DESC* pApplicationDesc,
		IDirectPlay8Address* pdpaddrHost,
		IDirectPlay8Address* pdpaddrDeviceInfo,
		const void* pvUserEnumData,
		DWORD dwUserEnumDataSize,
		DWORD dwEnumCount,
		DWORD dwRetryInterval,
		DWORD dwTimeOut,
		void* pvUserContext,
		DPNHANDLE* pAsyncHandle,
		DWORD dwFlags) = 0;
	virtual HRESULT WINAPI Receive(void* pvBuffer, DWORD* pdwBufferSize, void* pvContext, DWORD dwFlags)
	{
		(void)pvBuffer; (void)pdwBufferSize; (void)pvContext; (void)dwFlags;
		return DPNERR_NOTAVAILABLE;
	}
	virtual HRESULT WINAPI Send(
		DPN_BUFFER_DESC* pdpBuffers,
		DWORD dwBufferCount,
		DWORD dwTimeout,
		void* pvContext,
		DPNHANDLE* phAsyncHandle,
		DWORD dwFlags) = 0;
	virtual HRESULT WINAPI CancelAsyncOperation(DPNHANDLE hAsync, DWORD dwFlags) { (void)hAsync; (void)dwFlags; return DPNERR_NOTAVAILABLE; }
	virtual HRESULT WINAPI GetConnectionInfo(DPN_CONNECTION_INFO* pConnectionInfo, DWORD dwFlags) = 0;
	virtual HRESULT WINAPI GetSendQueueInfo(DWORD* pdwPending, DWORD* pdwHigh, DWORD dwFlags) = 0;
	virtual HRESULT WINAPI GetApplicationDesc(DPN_APPLICATION_DESC* pAppDescBuffer, DWORD* pdwDescSize, DWORD dwFlags) = 0;
	virtual HRESULT WINAPI SetClientInfo(DPN_PLAYER_INFO* pdnPlayerInfo, const void* pvAckData, DWORD dwAckDataLen, DWORD dwFlags) = 0;
	virtual HRESULT WINAPI SetConnectData(const void* pv, DWORD dw, DWORD dwFlags) { (void)pv; (void)dw; (void)dwFlags; return DPNERR_NOTAVAILABLE; }
	virtual HRESULT WINAPI GetSPCaps(const GUID*, void*, DWORD) { return DPNERR_NOTAVAILABLE; }
	virtual HRESULT WINAPI SetSPCaps(const GUID*, void*, DWORD) { return DPNERR_NOTAVAILABLE; }
};

struct IDirectPlay8Server
{
	virtual HRESULT WINAPI QueryInterface(const GUID&, void**) { return DPNERR_NOTAVAILABLE; }
	virtual unsigned long WINAPI AddRef() = 0;
	virtual unsigned long WINAPI Release() = 0;

	virtual HRESULT WINAPI Initialize(PVOID pvUserContext, PFNDPMESSAGECALLBACK pMsgCallback, DWORD dwFlags) = 0;
	virtual HRESULT WINAPI Close(DWORD dwFlags) = 0;
	virtual HRESULT WINAPI Host(
		DPN_APPLICATION_DESC* pdnAppDesc,
		IDirectPlay8Address** paHostAddrList,
		DWORD dwHostAddrCount,
		void* pdnSecurity,
		void* pdnCredentials,
		const void* pvPlayerContext,
		DWORD dwFlags) = 0;
	virtual HRESULT WINAPI Shutdown(DPNHANDLE hAsync, DWORD dwFlags) { (void)hAsync; (void)dwFlags; return DPNERR_NOTAVAILABLE; }
	virtual HRESULT WINAPI DestroyClient(
		DPNID dpnidPlayer,
		const void* pvData,
		DWORD dwDataSize,
		DWORD dwFlags) = 0;
	virtual HRESULT WINAPI CreateGroup(DPN_GROUP_INFO*, void*, DPNHANDLE*, DWORD) { return DPNERR_NOTAVAILABLE; }
	virtual HRESULT WINAPI DestroyGroup(DPNID, void*, DPNHANDLE*, DWORD) { return DPNERR_NOTAVAILABLE; }
	virtual HRESULT WINAPI AddPlayerToGroup(DPNID, DPNID, void*, DPNHANDLE*, DWORD) { return DPNERR_NOTAVAILABLE; }
	virtual HRESULT WINAPI RemovePlayerFromGroup(DPNID, DPNID, DPNID, void*, DPNHANDLE*, DWORD) { return DPNERR_NOTAVAILABLE; }
	virtual HRESULT WINAPI SetGroupInfo(DPNID, DPN_GROUP_INFO*, void*, DWORD) { return DPNERR_NOTAVAILABLE; }
	virtual HRESULT WINAPI GetGroupInfo(DPNID, DPN_GROUP_INFO*, DWORD*, DWORD) { return DPNERR_NOTAVAILABLE; }
	virtual HRESULT WINAPI SetClientInfo(DPNID, DPN_PLAYER_INFO*, void*, DWORD) { return DPNERR_NOTAVAILABLE; }
	virtual HRESULT WINAPI GetClientInfo(DPNID dpnidPlayer, DPN_PLAYER_INFO* pdnPlayerInfo, DWORD* pdnPlayerInfoSize, DWORD dwFlags) = 0;
	virtual HRESULT WINAPI SetServerInfo(DPN_PLAYER_INFO* pdnPlayerInfo, const void* pvAckData, DWORD dwAckDataLen, DWORD dwFlags) = 0;
	virtual HRESULT WINAPI GetServerInfo(DPN_PLAYER_INFO*, DWORD*, DWORD) { return DPNERR_NOTAVAILABLE; }
	virtual HRESULT WINAPI SendTo(
		DPNID dpnidTarget,
		DPN_BUFFER_DESC* pdpBuffers,
		DWORD dwBufferCount,
		DWORD dwTimeout,
		void* pvContext,
		DPNHANDLE* phAsyncHandle,
		DWORD dwFlags) = 0;
	virtual HRESULT WINAPI SendToGroup(DPNID, DPN_BUFFER_DESC*, DWORD, DWORD, void*, DPNHANDLE*, DWORD) { return DPNERR_NOTAVAILABLE; }
	virtual HRESULT WINAPI SendToAll(DPNID, DPN_BUFFER_DESC*, DWORD, DWORD, void*, DPNHANDLE*, DWORD) { return DPNERR_NOTAVAILABLE; }
	virtual HRESULT WINAPI CancelAsyncOperation(DPNHANDLE hAsync, DWORD dwFlags) { (void)hAsync; (void)dwFlags; return DPNERR_NOTAVAILABLE; }
	virtual HRESULT WINAPI GetConnectionInfo(DPNID dpnidPlayer, DPN_CONNECTION_INFO* pConnectionInfo, DWORD dwFlags) = 0;
	virtual HRESULT WINAPI GetSendQueueInfo(DWORD* pdwPending, DWORD* pdwHigh, DWORD dwFlags) = 0;
	virtual HRESULT WINAPI GetClientAddress(DPNID, IDirectPlay8Address**, DWORD) { return DPNERR_NOTAVAILABLE; }
	virtual HRESULT WINAPI CreatePlayer(DPN_PLAYER_INFO*, void*, DPNHANDLE*, DWORD) { return DPNERR_NOTAVAILABLE; }
};

struct IDirectPlay8Peer
{
	virtual HRESULT WINAPI QueryInterface(const GUID&, void**) { return DPNERR_NOTAVAILABLE; }
	virtual unsigned long WINAPI AddRef() = 0;
	virtual unsigned long WINAPI Release() = 0;
};

// ---------------------------------------------------------------------------
// COM-like creation (implemented by the runtime stub)
// ---------------------------------------------------------------------------
#ifndef REFCLSID
#define REFCLSID const GUID&
#define REFIID const GUID&
#endif
#ifndef CLSCTX_INPROC_SERVER
#define CLSCTX_INPROC_SERVER 0x1
#define CLSCTX_ALL 0x17
#endif

HRESULT CoCreateInstance(REFCLSID rclsid, void* pUnkOuter, DWORD dwClsContext, REFIID riid, LPVOID* ppv);

#endif // XR_POSIX_DPLAY_DPLAY8_H
