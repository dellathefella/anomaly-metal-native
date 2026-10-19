// xr_smoke — minimal xrCore runtime smoke test on macOS/arm64.
// Boots Core._initialize against real Anomaly data, reads a file out of an
// LZO-compressed db bundle and exercises core memory/string services.
// Usage: xr_smoke /path/to/Anomaly/fsgame.ltx [extra args...]
// Exit code 0 = all checks passed.
#include "xrCore.h"
#include "FS.h"
#include "LocatorAPI.h"

static bool g_failed = false;

#define SMOKE_CHECK(cond, msg)                                                                 \
	do                                                                                     \
	{                                                                                      \
		if (cond)                                                                          \
			Msg("* smoke: PASS " msg);                                                     \
		else                                                                               \
			Msg("* smoke: FAIL " msg), g_failed = true;                                    \
	} while (0)

int main(int argc, char** argv)
{
	if (argc < 2)
	{
		fprintf(stderr, "usage: %s /path/to/fsgame.ltx [engine args]\n", argv[0]);
		return 2;
	}

	xr_set_command_line(argc - 2, argv + 2);

	Core._initialize("xr_smoke", +[](const char* s) { fputs(s, stderr); }, TRUE, argv[1]);

	Msg("* smoke: ApplicationPath = %s", Core.ApplicationPath);
	Msg("* smoke: WorkingPath     = %s", Core.WorkingPath);
	Msg("* smoke: CPU             = %s / %s (%u cores, %u threads)", CPU::ID.model_name, CPU::ID.v_name,
	    CPU::ID.n_cores, CPU::ID.n_threads);

	// Path aliases must expand with real case preserved (case-sensitive APFS).
	string_path p = { 0 };
	FS.update_path(p, "$arch_dir$", "");
	SMOKE_CHECK(strstr(p, "db") != nullptr && strstr(p, "Anomaly") != nullptr, "$arch_dir$ expands");

	// Archive directories are registered lazily; the engine loads them after FS init.
	FS.load_all_unloaded_archives();

	// The registry must contain the contents of the configs bundle.
	FS_FileSet fset;
	int nf = FS.file_list(fset, "$game_config$", FS_ListFiles);
	Msg("* smoke: file_list($game_config$) -> %d entries", nf);
	SMOKE_CHECK(nf > 1000, "archive contents registered");

	// Read the first root-level .ltx out of the compressed bundle.
	xr_string first_root_ltx;
	for (const auto& f : fset)
		if (f.name.find('\\') == xr_string::npos && f.name.size() > 4 &&
		    f.name.compare(f.name.size() - 4, 4, ".ltx") == 0)
		{
			first_root_ltx = f.name;
			break;
		}
	IReader* reader =
	    first_root_ltx.empty() ? nullptr : FS.r_open("$game_config$", first_root_ltx.c_str());
	if (reader)
	{
		// Decompressed content sanity: .ltx files start with text.
		u8 head[64] = { 0 };
		const u32 take = reader->length() < sizeof(head) - 1 ? reader->length() : sizeof(head) - 1;
		reader->r(head, take);
		bool printable = true;
		for (u32 i = 0; i < take && i < 16; ++i)
		{
			const u8 c = head[i];
			if (c != '\t' && c != '\r' && c != '\n' && (c < ' ' || c > '~'))
				printable = false;
		}
		Msg("* smoke: %s -> %u bytes, head [%.32s]", first_root_ltx.c_str(), reader->length(),
		    (char*)head);
		SMOKE_CHECK(printable && reader->length() > 0, "LZO archive read + decompress");
		FS.r_close(reader);
	}
	else
		SMOKE_CHECK(false, "archive r_open");

	// Memory + string container sanity
	u8* block = (u8*)xr_malloc(4096);
	Memory.mem_fill32((u32*)block, 0xDEADBEEF, 1024);
	const bool mem_ok = block[0] == 0xEF && block[3] == 0xDE;
	xr_free(block);
	SMOKE_CHECK(mem_ok, "xr_malloc/mem_fill32");

	shared_str s = make_string("shared_str %d works", 42).c_str();
	SMOKE_CHECK(xr_strcmp(*s, "shared_str 42 works") == 0, "shared_str/make_string");

	Msg("* smoke: %s", g_failed ? "FAILURES PRESENT" : "ALL CHECKS PASSED");
	Core._destroy();
	return g_failed ? 1 : 0;
}
