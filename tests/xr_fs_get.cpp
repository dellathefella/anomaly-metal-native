// xr_fs_get — dump or list one logical file through the engine FS (loose
// files shadow archive entries exactly like the game sees them).
// Usage: xr_fs_get /path/to/fsgame.ltx <alias> <path> [outfile]
//        xr_fs_get /path/to/fsgame.ltx <alias> - [substring-filter]
#include "xrCore.h"
#include "FS.h"

int main(int argc, char** argv)
{
	if (argc < 4)
	{
		fprintf(stderr, "usage: %s /path/to/fsgame.ltx <alias> <path|-> [outfile|filter]\n", argv[0]);
		return 2;
	}

	xr_set_command_line(0, argv + 2);
	Core._initialize("xr_fs_get", +[](const char* s) { fputs(s, stderr); }, TRUE, argv[1]);
	FS.load_all_unloaded_archives();

	if (xr_strcmp(argv[3], "-") == 0)
	{
		const char* filter = argc > 4 ? argv[4] : "";
		FS_FileSet fset;
		const int nf = FS.file_list(fset, argv[2], FS_ListFiles);
		for (const auto& f : fset)
			if (!filter[0] || f.name.find(filter) != xr_string::npos)
				printf("%s\n", f.name.c_str());
		fprintf(stderr, "%d entries under %s\n", nf, argv[2]);
		Core._destroy();
		return 0;
	}

	IReader* r = FS.r_open(argv[2], argv[3]);
	if (!r)
	{
		fprintf(stderr, "not found: %s ! %s\n", argv[2], argv[3]);
		Core._destroy();
		return 1;
	}

	const u32 sz = r->length();
	u8* buf = (u8*)xr_malloc(sz);
	r->r(buf, sz);
	FILE* out = argc > 4 ? fopen(argv[4], "wb") : stdout;
	if (!out)
	{
		fprintf(stderr, "cannot open %s\n", argv[4]);
		return 1;
	}
	fwrite(buf, 1, sz, out);
	if (out != stdout)
		fclose(out);
	fprintf(stderr, "%u bytes -> %s\n", sz, argc > 4 ? argv[4] : "stdout");
	xr_free(buf);
	FS.r_close(r);
	Core._destroy();
	return 0;
}
