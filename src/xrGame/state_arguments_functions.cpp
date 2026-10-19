#include "stdafx.h"
#include "state_arguments_functions.h"

namespace award_system
{
	//definitions of static members of functions_cf
	// p4: explicit specialization static-member definitions need template<>
	// and brace-initializers — clang otherwise treats the bare declaration as
	// a declaration and emits no symbol (MSVC emitted a COMDAT).

	template<> ge_function<float> functions_cf<float>::ge_function{};
	template<> le_function<float> functions_cf<float>::le_function{};

	template<> ge_function<u32> functions_cf<u32>::ge_function{};
	template<> le_function<u32> functions_cf<u32>::le_function{};
} //namespace award_system
