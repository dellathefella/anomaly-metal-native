// p4 (user request): in-game control server ("game MCP").
//
// A localhost-only line protocol that lets an external driver (the agent's
// test automation) control the engine deterministically WITHOUT synthetic
// mouse/keyboard input:
//   ping                      -> pong <frame>
//   state                     -> key=value (frame, fps, in_game, level, script)
//   exec <console command>    -> Console->ExecuteCommand at frame boundary
//   lua <chunk>               -> run a Lua chunk in the game script engine
//   screenshot <name>         -> deferred capture to appdata/screenshots
//   quit
// Enabled with `-mcp [port]` (default 27846). One client; commands execute on
// the main thread at frame boundaries (same safety envelope as -harness).
// Responses: `OK ...` / `ERR ...` lines.
#include "stdafx.h"
#include "xr_mcp.h"
#include "xr_ioconsole.h"
#include "device.h"
#include "x_ray.h"
#include "IGame_Level.h"
#include "../xrGame/ai_space.h"
#include "../xrServerEntities/script_engine.h"
#include "../xrServerEntities/script_storage.h"
#include "xr_win32_shim_sdl.h" // PostQuitMessage

#include <atomic>
#include <mutex>
#include <string>
#include <deque>
#include <thread>
#include <chrono>
#include <cstdio>
#include <cstring>

#include <sys/socket.h>
#include <netinet/in.h>
#include <arpa/inet.h>
#include <unistd.h>
#include <errno.h>
#include <dlfcn.h>

// lua.h/lauxlib.h arrive via script_engine.h -> lua.hpp (LuaJIT)

namespace
{
    constexpr int DEFAULT_PORT = 27846;
    int g_port = DEFAULT_PORT;

    std::mutex g_cmd_mtx;
    std::deque<std::string> g_cmds;
    std::mutex g_resp_mtx;
    std::deque<std::string> g_resps;
    std::atomic<int> g_client_fd{ -1 };
    std::atomic<bool> g_stop{ false };

    // pending key/mouse release for `hold` (wall-clock seconds, steady)
    double g_release_due = 0.0;
    bool g_release_mouse = false;
    int g_release_sc = 0;

    // staged `click`: XRay buttons need press AND release inside the widget
    // rect while CUICursor's once-per-frame cache refreshes AFTER input —
    // so: warp @N, down @N+2, up @N+3 (same scheme as the file harness).
    int g_click_countdown = 0;

    void push_resp(std::string s)
    {
        std::lock_guard<std::mutex> l(g_resp_mtx);
        g_resps.push_back(std::move(s));
    }

    std::string trim(std::string s)
    {
        while (!s.empty() && (s.back() == '\r' || s.back() == '\n' || s.back() == ' '))
            s.pop_back();
        size_t b = s.find_first_not_of(" \t");
        return b == std::string::npos ? std::string{} : s.substr(b);
    }

    void server_thread()
    {
        int ls = ::socket(AF_INET, SOCK_STREAM, 0);
        if (ls < 0)
            return;
        int on = 1;
        setsockopt(ls, SOL_SOCKET, SO_REUSEADDR, &on, sizeof on);
        sockaddr_in a{};
        a.sin_family = AF_INET;
        a.sin_port = htons(u16(g_port));
        inet_pton(AF_INET, "127.0.0.1", &a.sin_addr);
        if (::bind(ls, (sockaddr*)&a, sizeof a) < 0 || ::listen(ls, 2) < 0)
        {
            Msg("! xr_mcp: bind/listen failed (%s)", strerror(errno));
            ::close(ls);
            return;
        }
        Msg("* xr_mcp: control server on 127.0.0.1:%d", g_port);

        timeval tv{ 0, 200000 }; // 200 ms poll so shutdown is prompt
        setsockopt(ls, SOL_SOCKET, SO_RCVTIMEO, &tv, sizeof tv);

        std::string linebuf;
        while (!g_stop)
        {
            int fd = g_client_fd.load();
            if (fd < 0)
            {
                fd = ::accept(ls, nullptr, nullptr);
                if (fd >= 0)
                {
                    setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &tv, sizeof tv);
                    g_client_fd = fd;
                    Msg("* xr_mcp: client connected");
                }
                else
                    continue; // accept timeout → loop
            }

            for (;;)
            {
                std::string r;
                {
                    std::lock_guard<std::mutex> l(g_resp_mtx);
                    if (g_resps.empty())
                        break;
                    r = std::move(g_resps.front());
                    g_resps.pop_front();
                }
                r += "\n";
                if (::write(fd, r.data(), r.size()) < 0)
                {
                    ::close(fd);
                    g_client_fd = -1;
                    break;
                }
            }

            char buf[4096];
            ssize_t n = ::recv(fd, buf, sizeof buf - 1, 0);
            if (n == 0)
            {
                Msg("* xr_mcp: client disconnected");
                ::close(fd);
                g_client_fd = -1;
                linebuf.clear();
                continue;
            }
            if (n < 0)
            {
                if (errno == EAGAIN || errno == EWOULDBLOCK || errno == EINTR)
                    continue;
                ::close(fd);
                g_client_fd = -1;
                linebuf.clear();
                continue;
            }
            buf[n] = 0;
            linebuf += buf;
            for (size_t pos; (pos = linebuf.find('\n')) != std::string::npos;)
            {
                std::string line = trim(linebuf.substr(0, pos));
                linebuf.erase(0, pos + 1);
                if (!line.empty())
                {
                    std::lock_guard<std::mutex> l(g_cmd_mtx);
                    g_cmds.push_back(std::move(line));
                }
            }
        }
        if (g_client_fd >= 0)
            ::close(g_client_fd);
        ::close(ls);
    }

    std::thread g_thread;

    // xrEngine must NOT reference the xrGame global `g_ai_space` directly:
    // xrGame.dylib loads after xrEngine.dylib, so a load-time data binding
    // aborts dyld ("symbol not found in flat namespace"). Resolve lazily once
    // xrGame is present. Same rationale as the vid_quality_token milestone.
    CAI_Space* mcp_ai()
    {
        static void* sym = nullptr;
        if (!sym)
            sym = dlsym(RTLD_DEFAULT, "g_ai_space");
        if (!sym)
            return nullptr;
        return *reinterpret_cast<CAI_Space**>(sym);
    }

    void run_line(const std::string& raw)
    {
        if (raw.compare(0, 4, "exec") == 0)
        {
            std::string cmd = trim(raw.substr(4));
            if (cmd.empty())
                return push_resp("ERR empty exec");
            Console->ExecuteCommand(cmd.c_str(), false);
            return push_resp("OK exec");
        }
        if (raw.compare(0, 3, "lua") == 0)
        {
            std::string chunk = trim(raw.substr(3));
            if (chunk.empty())
                return push_resp("ERR empty lua");
            CAI_Space* ai_space = mcp_ai();
            if (!ai_space)
                return push_resp("ERR ai not ready");
            lua_State* L = ai_space->script_engine().lua();
            if (!L)
                return push_resp("ERR no lua state");
            // p4 fix: 'top' MUST be captured BEFORE loadstring pushes the chunk —
            // pcall pops the chunk, so return values start at top+1. Capturing it
            // after loadstring made nret = k-1 and silently swallowed the first
            // return value (pcall's status boolean -> 'OK lua' for true,"").
            const int top = lua_gettop(L);
            if (luaL_loadstring(L, chunk.c_str()))
            {
                string256 err;
                snprintf(err, sizeof err, "%s", lua_tostring(L, -1) ? lua_tostring(L, -1) : "?");
                lua_pop(L, 1);
                Msg("! xr_mcp lua load: %s", err);
                return push_resp(std::string("ERR load: ") + err);
            }
            if (lua_pcall(L, 0, LUA_MULTRET, 0))
            {
                // NOTE: must NOT call script_engine().lua_pcall_failed() here —
                // it raises the engine's fatal error path and kills the game.
                // Report the error to the client instead.
                string256 err;
                snprintf(err, sizeof err, "%s", lua_tostring(L, -1) ? lua_tostring(L, -1) : "?");
                lua_pop(L, 1);
                return push_resp(std::string("ERR run: ") + err);
            }
            // return values -> single reply line
            const int nret = lua_gettop(L) - top;
            std::string out;
            for (int k = 1; k <= nret; ++k)
            {
                const int idx = top + k;
                const int t = lua_type(L, idx);
                std::string piece;
                if (t == LUA_TNUMBER)
                {
                    char nb[64];
                    snprintf(nb, sizeof nb, "%.14g", lua_tonumber(L, idx));
                    piece = nb;
                }
                else if (t == LUA_TBOOLEAN)
                    piece = lua_toboolean(L, idx) ? "true" : "false";
                else if (t == LUA_TSTRING)
                    piece = lua_tostring(L, idx) ? lua_tostring(L, idx) : "?";
                else
                {
                    const bool pushed = luaL_callmeta(L, idx, "__tostring") != 0;
                    if (pushed && lua_isstring(L, -1))
                        piece = lua_tostring(L, -1);
                    else
                        piece = std::string("<") + lua_typename(L, t) + ">";
                    if (pushed)
                        lua_pop(L, 1);
                }
                if (k > 1)
                    out += " | ";
                out += piece;
            }
            lua_settop(L, top);
            // protocol is line-based: keep multi-line lua errors on one line
            for (auto& ch : out)
                if (ch == '\n')
                    ch = ' ';
            return push_resp(out.empty() ? "OK lua" : "OK " + out);
        }
        if (raw.compare(0, 10, "mouse_move") == 0)
        {
            int dx = 0, dy = 0;
            if (sscanf(raw.c_str() + 10, " %d %d", &dx, &dy) < 1)
                return push_resp("ERR mouse_move <dx> [dy]");
            xr_raw_input_push(XrRawInputEvent::MouseMotion, dx, dy);
            return push_resp("OK motion");
        }
        if (raw.compare(0, 6, "cursor") == 0)
        {
            int cx = 0, cy = 0;
            if (sscanf(raw.c_str() + 6, " %d %d", &cx, &cy) < 2)
                return push_resp("ERR cursor <x> <y>");
            SetCursorPos(cx, cy);
            xr_cursor_freeze_now(500);
            return push_resp("OK cursor");
        }
        if (raw.compare(0, 5, "click") == 0)
        {
            int cx = 0, cy = 0;
            if (sscanf(raw.c_str() + 5, " %d %d", &cx, &cy) < 2)
                return push_resp("ERR click <x> <y>");
            SetCursorPos(cx, cy);
            xr_cursor_freeze_now(500); // physical mouse cannot steal the target
            g_click_countdown = 3;     // down @N+2, up @N+3 (see xr_mcp_frame)
            return push_resp("OK click");
        }
        if (raw.compare(0, 4, "hold") == 0 || raw.compare(0, 3, "key") == 0)
        {
            struct { const char* name; int sc; } keys[] = {
                {"W", 26}, {"A", 4}, {"S", 22}, {"D", 7},
                {"KEY_W", 26}, {"KEY_A", 4}, {"KEY_S", 22}, {"KEY_D", 7},
                {"LSHIFT", 225}, {"SPRINT", 225},
                {"I", 12}, {"P", 19}, {"E", 8}, {"R", 21}, {"F", 9}, {"Q", 20}, {"G", 10},
                {"TAB", 43}, {"ESC", 41}, {"SPACE", 44}, {"ENTER", 40}, {"RETURN", 40},
                {"LMB", -1}, {"MOUSE1", -1},
                {"1", 30}, {"2", 31}, {"3", 32}, {"4", 33}, {"5", 34},
                {"M", 16}, {"K", 14}, {"N", 17}, {"J", 13}, {"O", 18}, {"L", 15},
            };
            char nm[64] = "";
            float secs = 1.f;
            // p4 fix: the command is "key ..." or "hold ..." — the discriminator
            // is the FIRST char ('k' vs 'h'); index 3 is 'd'/space, so the old
            // test made every 'hold' fall through to the tap path.
            const bool is_hold = raw[0] == 'h';
            const char* args = raw.c_str() + 4; // skip "key " / "hold "
            if (sscanf(args, " %63s %f", nm, &secs) < 1)
                nm[0] = 0;
            int sc = 0;
            bool named = false;
            for (auto& k : keys)
                if (!xr_stricmp(nm, k.name))
                {
                    sc = k.sc;
                    named = true;
                    break;
                }
            if (!sc && !named && nm[0] >= '0' && nm[0] <= '9')
                sc = std::atoi(nm); // raw dik passthrough: 'key 337' = MOUSE_1 (fire), etc.
            if (!sc)
                return push_resp("ERR unknown key");
            const bool raw_dik = !named; // numeric values are DIK codes verbatim
            const int wire_sc = raw_dik ? (0x10000 | sc) : sc; // marker: use value as DIK directly
            const bool is_mouse = sc < 0;
            auto press = [&](bool down)
            {
                if (is_mouse)
                    xr_raw_input_push(down ? XrRawInputEvent::MouseButtonDown : XrRawInputEvent::MouseButtonUp, 1);
                else
                    xr_raw_input_push(down ? XrRawInputEvent::KeyDown : XrRawInputEvent::KeyUp, wire_sc);
            };
            if (!is_hold)
            {
                press(true);
                press(false);
                return push_resp("OK tap");
            }
            press(true);
            g_release_due = std::chrono::duration<double>(
                                std::chrono::steady_clock::now().time_since_epoch())
                                .count() +
                            (secs > 0.f ? secs : 1.f);
            g_release_mouse = is_mouse;
            g_release_sc = wire_sc;
            return push_resp("OK hold");
        }
        if (raw.compare(0, 10, "screenshot") == 0)
        {
            std::string name = trim(raw.substr(10));
            if (name.empty())
                name = "mcp_shot";
            std::string cmd = "screenshot " + name + " CCC";
            Console->ExecuteCommand(cmd.c_str(), false);
            return push_resp("OK screenshot " + name);
        }
        if (raw == "newgame") // AXR ui_main_menu.script:255 verbatim
        {
            Console->ExecuteCommand("start server(all/single/alife/new) client(localhost)", false);
            return push_resp("OK newgame deferred");
        }
        if (raw == "ping")
            return push_resp("pong " + std::to_string(Device.dwFrame));
        if (raw == "state")
        {
            char buf[512];
            snprintf(buf, sizeof buf,
                "OK frame=%u fps=%.1f in_game=%d level=%s script=%d",
                Device.dwFrame, Device.fTimeDelta > 1e-6f ? 1.f / Device.fTimeDelta : 0.f,
                g_pGameLevel ? 1 : 0, g_pGameLevel ? *(g_pGameLevel->name()) : "-",
                mcp_ai() ? 1 : 0);
            return push_resp(buf);
        }
        if (raw == "quit")
        {
            push_resp("OK quit");
            PostQuitMessage(0);
            return;
        }
        return push_resp("ERR unknown command");
    }
}

void xr_mcp_init()
{
    Msg("* xr_mcp: init probe (params='%s')", Core.Params ? Core.Params : "(null)");
    LPCSTR p = strstr(Core.Params, "-mcp");
    if (!p)
        return;
    p += 4;
    while (*p == ' ')
        ++p;
    if (*p >= '0' && *p <= '9')
        g_port = atoi(p);

    g_thread = std::thread(server_thread);
    g_thread.detach(); // dev tool: no join at teardown
    Msg("* xr_mcp: initialized");
}

void xr_mcp_frame()
{
    // pending `hold` release must fire even with no client / empty queue
    if (g_click_countdown > 0)
    {
        --g_click_countdown;
        if (g_click_countdown == 1)
            xr_raw_input_push(XrRawInputEvent::MouseButtonDown, 1);
        else if (g_click_countdown == 0)
            xr_raw_input_push(XrRawInputEvent::MouseButtonUp, 1);
    }
    if (g_release_due > 0.0 &&
        std::chrono::duration<double>(std::chrono::steady_clock::now().time_since_epoch()).count() >=
            g_release_due)
    {
        if (g_release_mouse)
            xr_raw_input_push(XrRawInputEvent::MouseButtonUp, 1);
        else
            xr_raw_input_push(XrRawInputEvent::KeyUp, g_release_sc);
        g_release_due = 0.0;
    }

    if (g_client_fd < 0)
        return;
    std::string line;
    {
        std::lock_guard<std::mutex> l(g_cmd_mtx);
        if (g_cmds.empty())
            return;
        line = std::move(g_cmds.front());
        g_cmds.pop_front();
    }
    run_line(line);
}

void xr_mcp_shutdown()
{
    g_stop = true;
}
