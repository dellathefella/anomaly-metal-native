// xr_smoke — minimal xrCore runtime smoke test on macOS.
// Usage: xr_smoke /path/to/Anomaly/fsgame.ltx [extra args...]
#include "xrCore.h"
#include "FS.h"
#include "LocatorAPI.h"

int main(int argc, char** argv)
{
	fprintf(stderr, "[smoke] enter main\n");
	if (argc < 2)
	{
		fprintf(stderr, "usage: %s /path/to/fsgame.ltx [engine args]\n", argv[0]);
		return 2;
	}

	xr_set_command_line(argc - 2, argv + 2);

	fprintf(stderr, "[smoke] before Core._initialize\n");
	Core._initialize("xr_smoke", +[](const char* s) { fputs(s, stderr); }, TRUE, argv[1]);
	fprintf(stderr, "[smoke] after Core._initialize\n");

	Msg("* smoke: ApplicationPath = %s", Core.ApplicationPath);
	Msg("* smoke: WorkingPath     = %s", Core.WorkingPath);
	Msg("* smoke: CPU             = %s / %s (%u cores, %u threads)", CPU::ID.model_name, CPU::ID.v_name,
	    CPU::ID.n_cores, CPU::ID.n_threads);

	string_path p = { 0 };
	FS.update_path(p, "$arch_dir$", "");
	Msg("* smoke: $arch_dir$       = %s", p);

	// Read a known loose file through the FS layer (a db bundle container).
	const file* e1 = FS.exist("$arch_dir$", "configs\\\\configs.db0");
	Msg("* smoke: exist(2arg)      = %s", e1 ? e1->name : "(null)");
	const file* e2 = FS.exist("$arch_dir$\\\\configs\\\\configs.db0");
	Msg("* smoke: exist(1arg)      = %s", e2 ? e2->name : "(null)");
	const file* e3 = FS.exist("$arch_dir$", "configs\\\\CONFIGS.DB0");
	Msg("* smoke: exist(upper)     = %s", e3 ? e3->name : "(null)");

	IReader* reader = FS.r_open("$arch_dir$", "configs\\\\configs.db0");
	if (!reader)
		reader = FS.r_open("fsgame.ltx");
	if (reader)
	{
		Msg("* smoke: configs.db0 opened via FS, %u bytes", reader->length());
		FS.r_close(reader);
	}
	else
		Msg("* smoke: FAILED to open configs.db0 via FS");

	// Memory + string container sanity
	u8* block = (u8*)xr_malloc(4096);
	Memory.mem_fill32((u32*)block, 0xDEADBEEF, 1024);
	VERIFY(block[0] == 0xEF && block[3] == 0xDE);
	xr_free(block);
	Msg("* smoke: xr_malloc/mem_fill32 OK");

	shared_str s = make_string("shared_str %d works", 42).c_str();
	Msg("* smoke: %s", *s);

	Core._destroy();
	Msg("* smoke: OK");
	return 0;
}
