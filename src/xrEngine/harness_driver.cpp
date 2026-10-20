// p4: visual regression harness driver — see harness_driver.h.
// Registered as a pureFrame right before Device.Run() so every line executes
// at a frame boundary, exactly like a typed console command.

#include "stdafx.h"
#include "harness_driver.h"
#include "x_ray.h" // pureFrame
#include "device.h"
#include "xr_win32_shim_sdl.h" // p4: xr_raw_input_push for `key` injection
#include "xr_ioconsole.h"

class CHarnessDriver : public pureFrame
{
    xr_vector<std::string> m_lines;
    size_t m_next{ 0 };
    float m_t0{ -1.f };
    float m_schedule{ 0.f };
    int m_grace{ 30 }; // frames to let the renderer/menu settle first
    int m_dbg_counter{ 0 };
    int m_pending_release{ 0 }; // p4: deferred button-up frame (see `click`)
    int m_hold_scancode{ 0 };  // p4: `hold` key with a key-up pending
    float m_hold_release_at{ -1.f };

public:
    explicit CHarnessDriver(LPCSTR path)
    {
        FILE* f = fopen(path, "rb");
        if (!f)
        {
            Msg("! harness: can't open '%s'", path);
            return;
        }
        char line[1024];
        while (fgets(line, sizeof(line), f))
        {
            char* s = line;
            while (*s == ' ' || *s == '\t')
                ++s;
            size_t n = strlen(s);
            while (n && (s[n - 1] == '\n' || s[n - 1] == '\r' || s[n - 1] == ' '))
                s[--n] = 0;
            if (!n || *s == '#')
                continue;
            m_lines.push_back(s);
        }
        fclose(f);
        Msg("* harness: %zu lines from %s", m_lines.size(), path);
    }

    virtual void OnFrame() override
    {
        // p4: staged click completion. Frame after the warp the UI cursor
        // update has consumed the new position, so the press (frame+1) and
        // release (frame+2) both land on the target widget — XRay buttons
        // need press AND release inside the window rect to activate.
        if (m_pending_release > 0)
        {
            --m_pending_release;
            if (m_pending_release == 1)
                xr_raw_input_push(XrRawInputEvent::MouseButtonDown, 1);
            else if (m_pending_release == 0)
                xr_raw_input_push(XrRawInputEvent::MouseButtonUp, 1);
        }
        if (m_lines.empty())
            return;
        // p4 debug: prove dispatch + timing state once, then every ~60s.
        ++m_dbg_counter;
        if (m_dbg_counter == 1 || (m_dbg_counter % 600) == 0)
            Msg("* harness dbg: calls=%d grace=%d t=%.2f t0=%.2f ready=%d active=%d",
                m_dbg_counter, m_grace, Device.fTimeGlobal, m_t0, (int)Device.b_is_Ready,
                (int)Device.b_is_Active);
        if (m_grace > 0)
        {
            --m_grace;
            return;
        }

        const float t = Device.fTimeGlobal;
        if (m_t0 < 0.f)
            m_t0 = t; // (re)base after level transitions reset the clock
        if (t < m_t0)
            m_t0 = t; // clock jumped back (level load) — rebase
        const float now = t - m_t0;

        // p4: pending `hold` release.
        if (m_hold_scancode && now >= m_hold_release_at)
        {
            xr_raw_input_push(XrRawInputEvent::KeyUp, m_hold_scancode);
            m_hold_scancode = 0;
        }

        while (m_next < m_lines.size())
        {
            const std::string& line = m_lines[m_next];
            if (line.compare(0, 5, "wait ") == 0)
            {
                const float w = (float)atof(line.c_str() + 5);
                if (now < m_schedule + w)
                    return;
                m_schedule += w;
                ++m_next;
                continue;
            }

            Msg("* harness: exec '%s'", line.c_str());
            // p4: `click <x> <y>` warps the OS cursor to engine-pixel coords
            // (SetCursorPos shim scales px→SDL points) and injects a left
            // button press+release through the raw-input queue — AXR dialogs
            // (newgame Start/Randomize) only react to mouse clicks, not keys.
            if (line.compare(0, 5, "click") == 0)
            {
                int cx = 0, cy = 0;
                if (2 == sscanf(line.c_str() + 5, "%d %d", &cx, &cy))
                {
                    SetCursorPos(cx, cy);
                    xr_cursor_freeze_now(500); // physical mouse cannot steal
                                               // the target during the click
                    // p4: staged — let the UI cursor consume the warped
                    // position for a frame before the button events; XRay
                    // buttons need press AND release inside the widget rect.
                    m_pending_release = 3; // down @N+2, up @N+3 (see OnFrame)
                }
                else
                    Msg("! harness: bad click '%s'", line.c_str());
                ++m_next;
                continue;
            }
            // p4: `key <NAME>` injects a synthetic key press+release through
            // the SDL raw-input queue (same path real keys take) so UI
            // navigation (menu, dialogs) is scriptable.
            // `hold <NAME> <secs>` presses the key and releases it secs
            // (wall-clock) later — movement (hold KEY_W 5) needs a real hold.
            static const struct
            {
                const char* name;
                int scancode;
            } s_keys[] = {
                {"RETURN", 40}, {"ESCAPE", 41}, {"SPACE", 44}, {"TAB", 43},
                {"RIGHT", 79}, {"LEFT", 80}, {"DOWN", 81}, {"UP", 82},
                {"KEY_W", 26}, {"KEY_A", 4}, {"KEY_S", 22}, {"KEY_D", 7},
                {"LSHIFT", 225},
            };
            const bool is_key = line.compare(0, 4, "key ") == 0;
            const bool is_hold = line.compare(0, 4, "hold") == 0;
            if (is_key || is_hold)
            {
                char nm[64] = "";
                float secs = 1.f;
                const char* args = line.c_str() + 4;
                if (is_hold)
                {
                    if (2 != sscanf(args, "%63s %f", nm, &secs) && 1 != sscanf(args, "%63s", nm))
                        nm[0] = 0;
                }
                else
                {
                    if (1 != sscanf(args, "%63s", nm))
                        nm[0] = 0;
                }
                const char* p = nm;
                while (*p == ' ')
                    ++p;
                if (*p == 'k' || *p == 'K') // tolerate kDOWN/DIK-style names
                    ++p;
                int sc = 0;
                for (auto& k : s_keys)
                    if (!xr_stricmp(p, k.name))
                    {
                        sc = k.scancode;
                        break;
                    }
                if (!sc)
                    Msg("! harness: unknown key '%s'", nm);
                else if (is_key)
                {
                    xr_raw_input_push(XrRawInputEvent::KeyDown, sc);
                    xr_raw_input_push(XrRawInputEvent::KeyUp, sc);
                }
                else
                {
                    xr_raw_input_push(XrRawInputEvent::KeyDown, sc);
                    m_hold_scancode = sc;
                    m_hold_release_at = now + (secs > 0.f ? secs : 1.f);
                    Msg("* harness: hold '%s' for %.1fs", p, (double)secs);
                }
                ++m_next;
                continue;
            }
            if (line.compare(0, 10, "screenshot") == 0)
                Msg("* harness: fps=%.1f at '%s'",
                    Device.fTimeDelta > 1e-6f ? 1.f / Device.fTimeDelta : 0.f, line.c_str());
            Console->ExecuteCommand(line.c_str(), false);
            ++m_next;
        }
    }
};

static CHarnessDriver* s_harness = nullptr;

void harness_init()
{
    LPCSTR p = strstr(Core.Params, "-harness ");
    if (!p)
        return;
    p += 9;
    while (*p == ' ')
        ++p;

    char path[512];
    path[0] = 0;
    if (*p == '"')
        sscanf(p + 1, "%[^\"]", path);
    else
        sscanf(p, "%511s", path);
    if (!path[0])
    {
        Msg("! harness: -harness needs a file path");
        return;
    }

    s_harness = xr_new<CHarnessDriver>(path);
    // CRenderDevice hides the override privately; dispatch via the interface.
    static_cast<IRenderDevice&>(Device).AddSeqFrame(s_harness, false);
    Msg("* harness dbg: obj=%p dev=%p seqFrame.size=%zu", (void*)s_harness, (void*)&Device,
        Device.seqFrame.R.size());
    Msg("* layout probe(xrEngine): dev=%p seqFrame=%+td seqRender=%+td", (void*)&Device,
        (char*)&Device.seqFrame - (char*)&Device, (char*)&Device.seqRender - (char*)&Device);
}
