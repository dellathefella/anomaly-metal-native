#include "xr_sha.h"
#include <openssl/sha.h>

// OpenSSL 1.0+ dropped the legacy SHA_* == SHA1_* aliases (this class is
// SHA1 despite its name).
#ifndef SHA_Init
#define SHA_Init   SHA1_Init
#define SHA_Update SHA1_Update
#define SHA_Final  SHA1_Final
#endif

namespace crypto
{

xr_sha256::xr_sha256()
{
	m_sha_ctx		= xr_new<SHA_CTX>();
}

xr_sha256::~xr_sha256()
{
	xr_delete		(m_sha_ctx);
}

void	xr_sha256::start_calculate		(u8 const * data, u32 data_size)
{
	SHA_Init		(m_sha_ctx);
	ZeroMemory		(m_result, sizeof(m_result));
	VERIFY			(data_size);
	m_data_src		= data;
	m_data_size		= data_size;
}

bool	xr_sha256::continue_calculate	()
{
	u32 const to_calc	= m_data_size >= calc_chunk_size ? calc_chunk_size : m_data_size;

	SHA_Update			(m_sha_ctx, m_data_src, to_calc);

	m_data_src			+= to_calc;
	m_data_size			-= to_calc;

	if (!m_data_size)
	{
		SHA_Final(m_result, m_sha_ctx);
		return true;
	}
	return false;
}

} //namespace crypto
