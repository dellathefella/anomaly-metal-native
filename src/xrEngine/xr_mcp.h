#pragma once

// p4: in-game control server (see xr_mcp.cpp). Enabled with `-mcp [port]`.
void xr_mcp_init();
void xr_mcp_frame();
void xr_mcp_shutdown();
