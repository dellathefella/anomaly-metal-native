// rmtl_shaders.cpp — CRender::shader_compile for Metal (p5 t2).
//
// Mirror of rgl_shaders.cpp: the same option/define matrix drives the cache
// key (so cache filenames track the same settings as the GL path), but the
// compilation chain is DX9 HLSL -> TranslateDx9Shader (include-inline +
// SM6 rewrite) -> DXC (-Zpr, SPIR-V) -> reflection + SPIRV-Cross -> MSL ->
// id<MTLFunction> (mtlShaderCompile.mm). The on-disk cache stores the MSL
// text + serialized reflection blob, so a cache hit only pays newLibraryWithSource.
#include "stdafx.h"
#include "r2.h"

#include "Layers/xrRender/ShaderResourceTraits.h"
#include "Layers/xrRenderMetal/mtlShader.h"
#include "Layers/xrRenderMetal/mtlHW.h"
#include "xrCore/FileCRC32.h"

#include "mtl_dx9_translate.h"

namespace xray::render::RENDER_NAMESPACE
{
void CRender::addShaderOption(const char* name, const char* value)
{
    // Kept for the shared r2.cpp surface; the Metal path re-derives its
    // defines from the option flags below (GL-parity), m_ShaderOptions is
    // informational.
    m_ShaderOptions += "#define ";
    m_ShaderOptions += name;
    m_ShaderOptions += " ";
    m_ShaderOptions += value;
    m_ShaderOptions += "\n";
}

namespace
{
// Heap stage-reflection records: SShader::sh (void*) points here. Shaders are
// session-lifetime; freed with the process (DestroyShader keeps the GL
// no-op semantics for the borrowed handle).
std::vector<std::unique_ptr<MtlStageRefl>>& stage_refl_registry()
{
    static std::vector<std::unique_ptr<MtlStageRefl>> registry;
    return registry;
}

MtlStageRefl* hold_stage_refl(MtlStageRefl&& refl)
{
    auto& reg = stage_refl_registry();
    reg.push_back(std::make_unique<MtlStageRefl>(std::move(refl)));
    return reg.back().get();
}

class shader_name_holder
{
    size_t pos{};
    string_path name;

public:
    void append(cpcstr string)
    {
        const size_t size = xr_strlen(string);
        for (size_t i = 0; i < size; ++i)
        {
            name[pos] = string[i];
            ++pos;
        }
    }

    void append(u32 value)
    {
        name[pos] = '0' + char(value); // NOLINT
        ++pos;
    }

    void finish()
    {
        name[pos] = '\0';
    }

    pcstr c_str() const { return name; }
};

// Physical POSIX path for the translator's file/include resolution:
// update_path yields the fsRoot prefix with native slashes plus a
// backslash-normalized relative part — normalize the rest.
std::string physical_path(pcstr fsPath)
{
    std::string out(fsPath);
    std::replace(out.begin(), out.end(), '\\', '/');
    return out;
}
} // namespace

HRESULT CRender::shader_compile(pcstr name, IReader* fs, pcstr pFunctionName,
    pcstr pTarget, u32 Flags, void*& result)
{
    shader_name_holder sh_name;
    std::vector<std::string> defines; // DXC -D args (also seen by DXC's preprocessor)

    const auto addDefine = [&](cpcstr macro, cpcstr value)
    {
        defines.push_back(std::string(macro) + "=" + value);
    };
    const auto appendShaderOption = [&](u32 option, cpcstr macro, cpcstr value)
    {
        if (option)
            addDefine(macro, value);
        sh_name.append(option);
    };

    // No "#version"/"#pragma optimize" — HLSL has neither; DXC optimizes at -O1.
#ifdef DEBUG
    sh_name.append(0u);
#else
    sh_name.append(1u);
#endif

    // Shadow map size
    {
        string32 c_smapsize;
        xr_itoa(m_SMAPSize, c_smapsize, 10);
        addDefine("SMAP_size", c_smapsize);
        sh_name.append(c_smapsize);
    }

    appendShaderOption(o.fp16_filter, "FP16_FILTER", "1");
    appendShaderOption(o.fp16_blend, "FP16_BLEND", "1");
    appendShaderOption(o.HW_smap, "USE_HWSMAP", "1");
    appendShaderOption(o.HW_smap_PCF, "USE_HWSMAP_PCF", "1");
    appendShaderOption(o.HW_smap_FETCH4, "USE_FETCH4", "1");
    appendShaderOption(o.sjitter, "USE_SJITTER", "1");
    appendShaderOption(HW.Caps.raster_major >= 3, "USE_BRANCHING", "1");
    appendShaderOption(HW.Caps.geometry.bVTF, "USE_VTF", "1");
    appendShaderOption(o.Tshadows, "USE_TSHADOWS", "1");
    appendShaderOption(o.mblur, "USE_MBLUR", "1");
    appendShaderOption(o.sunfilter, "USE_SUNFILTER", "1");
    appendShaderOption(o.sunstatic, "USE_R2_STATIC_SUN", "1");
    {
        string32 c_gloss;
        xr_sprintf(c_gloss, "%f", o.forcegloss_v);
        appendShaderOption(o.forcegloss, "FORCE_GLOSS", c_gloss);
    }
    appendShaderOption(o.forceskinw, "SKIN_COLOR", "1");
    appendShaderOption(o.ssao_blur_on, "USE_SSAO_BLUR", "1");

    // SSAO HDAO/HBAO — both disabled on Metal (GL parity: r2.cpp forces
    // ssao_hdao/ssao_hbao off under USE_METAL); the key slots are still
    // appended so the cache layout stays uniform.
    if (o.ssao_hdao)
    {
        addDefine("HDAO", "1");
        sh_name.append(static_cast<u32>(1));
        sh_name.append(static_cast<u32>(0));
        sh_name.append(static_cast<u32>(0));
    }
    else
    {
        sh_name.append(static_cast<u32>(0));
        sh_name.append(o.ssao_hbao);
        appendShaderOption(o.ssao_hbao, "USE_HBAO", "1");
        appendShaderOption(o.hbao_vectorized, "VECTORIZED_CODE", "1");
    }

    if (o.ssao_opt_data)
        addDefine("SSAO_OPT_DATA", o.ssao_half_data ? "2" : "1");
    sh_name.append(o.ssao_opt_data ? (o.ssao_half_data ? u32(2) : u32(1)) : u32(0));

    appendShaderOption(m_skinning < 0, "SKIN_NONE", "1");
    appendShaderOption(0 == m_skinning, "SKIN_0", "1");
    appendShaderOption(1 == m_skinning, "SKIN_1", "1");
    appendShaderOption(2 == m_skinning, "SKIN_2", "1");
    appendShaderOption(3 == m_skinning, "SKIN_3", "1");
    appendShaderOption(4 == m_skinning, "SKIN_4", "1");

    {
        const bool softWater = RImplementation.o.advancedpp && ps_r2_ls_flags.test(R2FLAG_SOFT_WATER);
        appendShaderOption(softWater, "USE_SOFT_WATER", "1");
    }

    if (RImplementation.o.advancedpp && ps_r_water_reflection)
    {
        string32 c_water_reflection;
        xr_sprintf(c_water_reflection, "%d", ps_r_water_reflection);
        addDefine("SSR_QUALITY", c_water_reflection);
        sh_name.append(ps_r_water_reflection);
        const bool sshHalfDepth = ps_r2_ls_flags_ext.test(R3FLAGEXT_SSR_HALF_DEPTH);
        appendShaderOption(sshHalfDepth, "SSR_HALF_DEPTH", "1");
        const bool ssrJitter = ps_r2_ls_flags_ext.test(R3FLAGEXT_SSR_JITTER);
        appendShaderOption(ssrJitter, "SSR_JITTER", "1");
    }
    else
    {
        sh_name.append(static_cast<u32>(0));
    }

    {
        const bool useSoftParticles = RImplementation.o.advancedpp && ps_r2_ls_flags.test(R2FLAG_SOFT_PARTICLES);
        appendShaderOption(useSoftParticles, "USE_SOFT_PARTICLES", "1");
    }
    {
        const bool dof = RImplementation.o.advancedpp && ps_r2_ls_flags.test(R2FLAG_DOF);
        appendShaderOption(dof, "USE_DOF", "1");
    }

    if (RImplementation.o.advancedpp && ps_r_sun_shafts)
    {
        string32 c_sun_shafts;
        xr_sprintf(c_sun_shafts, "%d", ps_r_sun_shafts);
        addDefine("SUN_SHAFTS_QUALITY", c_sun_shafts);
        sh_name.append(ps_r_sun_shafts);
    }
    else
        sh_name.append(static_cast<u32>(0));

    if (RImplementation.o.advancedpp && ps_r_ssao)
    {
        string32 c_ssao;
        xr_sprintf(c_ssao, "%d", ps_r_ssao);
        addDefine("SSAO_QUALITY", c_ssao);
        sh_name.append(ps_r_ssao);
    }
    else
        sh_name.append(static_cast<u32>(0));

    if (RImplementation.o.advancedpp && ps_r_sun_quality)
    {
        string32 c_sun_quality;
        xr_sprintf(c_sun_quality, "%d", ps_r_sun_quality);
        addDefine("SUN_QUALITY", c_sun_quality);
        sh_name.append(ps_r_sun_quality);
    }
    else
        sh_name.append(static_cast<u32>(0));

    {
        const bool steepParallax = RImplementation.o.advancedpp && ps_r2_ls_flags.test(R2FLAG_STEEP_PARALLAX);
        appendShaderOption(steepParallax, "ALLOW_STEEPPARALLAX", "1");
    }

    appendShaderOption(o.gbuffer_opt, "GBUFFER_OPTIMIZATION", "1");

    // Shader Model 4.1: Metal has textureGather; offset variants are emulated
    // by SPIRV-Cross, so the SM_4_1 corpus paths are available (unlike the GL
    // mac path which had to disable gather-offset).
    appendShaderOption(o.dx11_sm4_1, "SM_4_1", "1");

    appendShaderOption(o.minmax_sm, "USE_MINMAX_SM", "1");
    appendShaderOption(ShadowOfChernobylMode, "USE_SHOC_RESOURCES", "1");

    // MSAA stays off on Metal (GL parity) — key slots keep the uniform shape.
    if (o.msaa)
    {
        appendShaderOption(o.msaa, "USE_MSAA", "1");
        static char samples[2];
        samples[0] = char(o.msaa_samples) + '0';
        samples[1] = 0;
        appendShaderOption(o.msaa_samples, "MSAA_SAMPLES", samples);
        {
            string32 c_isample;
            xr_sprintf(c_isample, "%d", m_MSAASample);
            addDefine("ISAMPLE", c_isample);
        }
        sh_name.append(static_cast<u32>(0));
        appendShaderOption(o.msaa_opt, "MSAA_OPTIMIZATION", "1");
        sh_name.append(static_cast<u32>(0));
        sh_name.append(static_cast<u32>(0));
        sh_name.append(static_cast<u32>(0));
    }
    else
    {
        for (int i = 0; i < 7; i++)
            sh_name.append(static_cast<u32>(0)); // MSAA/samples/ISAMPLE/opt/ATOC trio
    }

    sh_name.finish();

    char extension[3];
    strncpy_s(extension, pTarget, 2);
    extension[2] = 0;

    u32 fileCrc = 0;
    string_path filename, full_path{};
    strconcat(sizeof(filename), filename, "metal" DELIMITER, name, ".", extension, DELIMITER, sh_name.c_str());
    {
        string_path file;
        strconcat(sizeof(file), file, "shaders_cache_metal" DELIMITER, filename);
        FS.update_path(full_path, "$app_data_root$", file);
    }

    string_path shadersFolder;
    FS.update_path(shadersFolder, "$game_shaders$", RImplementation.getShaderPath());
    getFileCrc32(fs, shadersFolder, fileCrc);
    fs->seek(0);

    MtlStageRefl refl;
    std::string msl;
    string256 entry{};
    xr_strcpy(entry, pFunctionName);

    // ---- cache read -------------------------------------------------------
    if (FS.exist(full_path))
    {
        IReader* file = FS.r_open(full_path);
        if (file->length() > 16)
        {
            xr_string adapter, metalVer, cachedEntry;
            file->r_string(adapter);
            file->r_string(metalVer);
            file->r_string(cachedEntry);
            const u32 savedFileCrc = file->r_u32();
            const u32 savedBytecodeCrc = file->r_u32();
            const u32 payloadLen = file->elapsed();
            const u32 payloadCrc = crc32(file->pointer(), payloadLen);
            if (0 == xr_strcmp(adapter.c_str(), HW.AdapterName) &&
                0 == xr_strcmp(metalVer.c_str(), HW.MetalVersionString) &&
                savedFileCrc == fileCrc && savedBytecodeCrc == payloadCrc)
            {
                // Binary-safe payload framing (matches the write side:
                // u32 length + raw bytes; the reflection blob embeds NULs).
                std::string mslText, blobText;
                const u32 remaining = file->length() - file->elapsed();
                if (remaining > 8)
                {
                    const u32 mslLen = file->r_u32();
                    if (mslLen && mslLen + 8 <= remaining)
                    {
                        mslText.resize(mslLen);
                        file->r(mslText.data(), mslLen);
                        const u32 blobLen = file->r_u32();
                        if (blobLen && blobLen + 4 <= file->length() - file->elapsed())
                        {
                            blobText.resize(blobLen);
                            file->r(blobText.data(), blobLen);
                        }
                    }
                }
                std::string error;
                if (!mslText.empty() && !blobText.empty() &&
                    MtlDeserializeReflection(blobText, refl, error) &&
                    MetalCreateStageFromMsl(refl, name, mslText.c_str(), cachedEntry.c_str(), error))
                {
                    msl = std::move(mslText);
                    xr_strcpy(entry, cachedEntry.c_str());
                }
                else
                {
                    Msg("! Metal shader cache load failed for %s: %s", filename, error.c_str());
                    refl = MtlStageRefl{};
                }
            }
        }
        file->close();
    }

    // ---- compile ----------------------------------------------------------
    if (!refl.function)
    {
#ifdef DEBUG
        Log("- Compile shader:", filename);
#endif
        const std::string source(static_cast<cpcstr>(fs->pointer()), fs->length());

        // Physical paths for the translator's include resolution.
        string_path shaderFsPath;
        strconcat(sizeof(shaderFsPath), shaderFsPath, RImplementation.getShaderPath(), name, ".", extension);
        string_path updated;
        FS.update_path(updated, _game_shaders_, shaderFsPath);
        const std::string sourcePath = physical_path(updated);
        const std::vector<std::string> includeDirs = { physical_path(shadersFolder) };

        const xray::metal::ShaderStage stage =
            pTarget[0] == 'v' ? xray::metal::ShaderStage::Vertex : xray::metal::ShaderStage::Pixel;

        xray::metal::Dx9TranslateOptions topts;
        xray::metal::Dx9Translation tr = xray::metal::TranslateDx9Shader(source, sourcePath, stage, includeDirs, topts);

        std::string error;
        bool compiled = false;
        for (int attempt = 0; attempt < 2 && !compiled; attempt++)
        {
            if (attempt == 1)
            {
                // PS inputs with COLOR* semantics: retry mapping them to high
                // TEXCOORD slots (batch-validator-proven recovery).
                topts.colorInputsAsTexcoord = true;
                tr = xray::metal::TranslateDx9Shader(source, sourcePath, stage, includeDirs, topts);
            }
            if (!tr.ok)
            {
                error = tr.error;
                continue;
            }
            // Feed the option matrix to the compiler (GL parity: rgl's
            // apply_options prepends #define lines). Many entries and code
            // paths exist only behind #ifdef SKIN_*/USE_R2_STATIC_SUN/..., so
            // compiling without them picks the wrong variant or finds no
            // entry at all (deffer_model_bump, shadow_direct_model...).
            std::string prefixed;
            for (const auto& d : defines)
            {
                const size_t eq = d.find('=');
                prefixed += "#define ";
                prefixed.append(d, 0, eq);
                if (eq != std::string::npos)
                {
                    prefixed += " ";
                    prefixed.append(d, eq + 1, std::string::npos);
                }
                prefixed += "\n";
            }
            prefixed += tr.hlsl;
            std::string mslOut;
            if (MetalCompileStage(refl, &mslOut, pTarget[0], name, prefixed.c_str(), pFunctionName, error))
            {
                msl = std::move(mslOut);
                compiled = true;
            }
        }
        if (!compiled)
        {
            Msg("! Metal shader compile FAILED: %s (%s): %s", name, pTarget, error.c_str());
            for (const auto& note : tr.notes)
                Msg("    note: %s", note.c_str());
            return E_FAIL;
        }
        xr_strcpy(entry, pFunctionName);

        // ---- cache write ----------------------------------------------------
        const std::string blob = MtlSerializeReflection(refl);
        try
        {
            IWriter* file = FS.w_open(full_path);
            file->w_string(HW.AdapterName);
            file->w_string(HW.MetalVersionString);
            file->w_string(entry);
            file->w_u32(fileCrc);
            // crc covers exactly the bytes that follow (r_string x2)
            {
                const u32 mslLen = static_cast<u32>(msl.size());
                const u32 blobLen = static_cast<u32>(blob.size());
                u32 crc = 0;
                crc = crc32(&mslLen, 4, crc);
                crc = crc32(msl.data(), msl.size(), crc);
                crc = crc32(&blobLen, 4, crc);
                crc = crc32(blob.data(), blob.size(), crc);
                file->w_u32(crc);
                // binary-safe r_string-compatible framing (u32 length + raw
                // bytes; the reflection blob embeds NULs so w_string(pcstr)
                // would truncate at the first one)
                file->w_u32(mslLen);
                file->w(msl.data(), msl.size());
                file->w_u32(blobLen);
                file->w(blob.data(), blob.size());
            }
            FS.w_close(file);
        }
        catch (...)
        {
            // cache write failure is not fatal
        }
    }

    // ---- attach to the stage resource -------------------------------------
    refl.name = std::string(name) + "." + extension; // p5 diag identity
    auto* held = hold_stage_refl(std::move(refl));
    switch (pTarget[0])
    {
    case 'p':
    {
        SPS*& S = (SPS*&)result;
        S->sh = held;
        S->constants.parse(held, ShaderTypeTraits<SPS>::GetShaderDest());
        break;
    }
    case 'v':
    {
        SVS*& S = (SVS*&)result;
        S->sh = held;
        S->constants.parse(held, ShaderTypeTraits<SVS>::GetShaderDest());
        break;
    }
    default:
        Msg("! Metal renderer: shader stage '%s' is not supported ('%s')", pTarget, name);
        return E_FAIL;
    }
    return S_OK;
}
} // namespace xray::render::RENDER_NAMESPACE
