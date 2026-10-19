// winsock2.h — POSIX (macOS) shim for Winsock2. Maps onto BSD sockets; only
// the surface xrNetServer's address helpers use.
#ifndef XR_POSIX_WINSOCK2_H
#define XR_POSIX_WINSOCK2_H

#include <sys/types.h>
#include <sys/socket.h>
#include <netinet/in.h>
#include <netdb.h>
#include <arpa/inet.h>
#include <unistd.h>
#include <errno.h>

typedef int SOCKET;
#ifndef INVALID_SOCKET
#define INVALID_SOCKET (-1)
#endif
#ifndef SOCKET_ERROR
#define SOCKET_ERROR (-1)
#endif

// Winsock error codes referenced by the engine (subset)
#define WSAMAC_ERROR_BASE 10000
#ifndef WSAEACCES
#define WSAEACCES (WSAMAC_ERROR_BASE + 13)
#endif
#ifndef WSAEADDRINUSE
#define WSAEADDRINUSE (WSAMAC_ERROR_BASE + 98)
#endif
#ifndef WSAECONNREFUSED
#define WSAECONNREFUSED (WSAMAC_ERROR_BASE + 111)
#endif
#ifndef WSAECONNRESET
#define WSAECONNRESET (WSAMAC_ERROR_BASE + 104)
#endif
#ifndef WSAETIMEDOUT
#define WSAETIMEDOUT (WSAMAC_ERROR_BASE + 110)
#endif

#endif // XR_POSIX_WINSOCK2_H
