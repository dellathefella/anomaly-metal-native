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
        const float now = t - m_t0;

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
            // p4: `key <NAME>` injects a synthetic key press+release through
            // the SDL raw-input queue (same path real keys take) so UI
            // navigation (menu, dialogs) is scriptable.
            if (line.compare(0, 4, "key ") == 0)
            {
                static const struct
                {
                    const char* name;
                    int scancode;
                } s_keys[] = {
                    {"RETURN", 40}, {"ESCAPE", 41}, {"SPACE", 44}, {"TAB", 43},
                    {"RIGHT", 79}, {"LEFT", 80}, {"DOWN", 81}, {"UP", 82},
                };
                const char* nm = line.c_str() + 4;
                while (*nm == ' ')
                    ++nm;
                if (nm[0] == 'k' || nm[0] == 'K') // tolerate kDOWN/DIK-style names
                    ++nm;
                bool hit = false;
                for (auto& k : s_keys)
                    if (!xr_stricmp(nm, k.name))
                    {
                        xr_raw_input_push(XrRawInputEvent::KeyDown, k.scancode);
                        xr_raw_input_push(XrRawInputEvent::KeyUp, k.scancode);
                        hit = true;
                        break;
                    }
                if (!hit)
                    Msg("! harness: unknown key '%s'", nm);
                ++m_next;
                continue;
            }
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
