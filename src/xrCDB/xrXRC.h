// xrXRC.h: interface for the xrXRC class.
//
//////////////////////////////////////////////////////////////////////

#if !defined(AFX_XRXRC_H__9AA25268_621F_4FCA_BD75_AF2E9822B8E3__INCLUDED_)
#define AFX_XRXRC_H__9AA25268_621F_4FCA_BD75_AF2E9822B8E3__INCLUDED_
//#pragma once

#include "xrCDB.h"

#ifdef	DEBUG
extern	XRCDB_API	CStatTimer	*cdb_clRAY;				// total: ray-testing
extern	XRCDB_API	CStatTimer	*cdb_clBOX;				// total: box query
extern	XRCDB_API	CStatTimer	*cdb_clFRUSTUM;			// total: frustum query
#endif

class XRCDB_API xrXRC
{
	CDB::COLLIDER CL;
public:
	IC void ray_options(u32 f)
	{
		CL.ray_options(f);
	}

	IC void ray_query(const CDB::MODEL* m_def, const Fvector& r_start, const Fvector& r_dir, float r_range = 10000.f)
	{
#ifdef DEBUG
		cdb_clRAY->Begin();
#endif
		CL.ray_query(m_def, r_start, r_dir, r_range);
#ifdef DEBUG
		cdb_clRAY->End	();
#endif
	}

	IC void box_options(u32 f)
	{
		CL.box_options(f);
	}

	IC void box_query(const CDB::MODEL* m_def, const Fvector& b_center, const Fvector& b_dim)
	{
#ifdef DEBUG
		cdb_clBOX->Begin();
#endif
		CL.box_query(m_def, b_center, b_dim);
#ifdef DEBUG
		cdb_clBOX->End	();
#endif
	}

	IC void frustum_options(u32 f)
	{
		CL.frustum_options(f);
	}

	IC void frustum_query(const CDB::MODEL* m_def, const CFrustum& F)
	{
#ifdef DEBUG
		cdb_clFRUSTUM->Begin();
#endif
		CL.frustum_query(m_def, F);
#ifdef DEBUG
		cdb_clFRUSTUM->End	();
#endif
	}

	IC CDB::RESULT* r_begin() { return CL.r_begin(); };
	IC CDB::RESULT* r_end() { return CL.r_end(); };
	IC void r_free() { CL.r_free(); }
	IC int r_count() { return CL.r_count(); };
	IC void r_clear() { CL.r_clear(); };
	IC void r_clear_compact() { CL.r_clear_compact(); };

	// p4: dev's xrXRC carries an instance label for the stats overlay and
	// exposes DumpStatistics; the overlay itself is not ported (no-op stub).
	IC void DumpStatistics(class IGameFont& /*font*/, class IPerformanceAlert* /*alert*/) {}

	// p4: dev's per-call options form — the monolith COLLIDER keeps options as
	// state, so apply them before the query (call sites pass explicit options
	// on every query, so no restore is needed).
	IC void ray_query(u32 options, const CDB::MODEL* m_def, const Fvector& r_start, const Fvector& r_dir, float r_range = 10000.f)
	{
		CL.ray_options(options);
		ray_query(m_def, r_start, r_dir, r_range);
	}
	IC void box_query(u32 options, const CDB::MODEL* m_def, const Fvector& b_center, const Fvector& b_dim)
	{
		CL.box_options(options);
		box_query(m_def, b_center, b_dim);
	}
	IC void frustum_query(u32 options, const CDB::MODEL* m_def, const CFrustum& F)
	{
		CL.frustum_options(options);
		frustum_query(m_def, F);
	}

	xrXRC(const char* stat_name = nullptr);
	~xrXRC();
private:
	const char* m_stat_name;
};

XRCDB_API extern xrXRC XRC;

#endif // !defined(AFX_XRXRC_H__9AA25268_621F_4FCA_BD75_AF2E9822B8E3__INCLUDED_)
