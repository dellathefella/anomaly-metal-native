////////////////////////////////////////////////////////////////////////////
//	Module 		: property_evaluator_const.h
//	Created 	: 12.03.2004
//  Modified 	: 26.03.2004
//	Author		: Dmitriy Iassenev
//	Description : Property evaluator const
////////////////////////////////////////////////////////////////////////////

#pragma once

#include "property_evaluator.h"

template <typename _object_type>
class CPropertyEvaluatorConst : public CPropertyEvaluator<_object_type>
{
protected:
	typedef CPropertyEvaluator<_object_type> inherited;
	// clang: dependent base typedefs must be re-exposed for unqualified use
	typedef typename inherited::_condition_type _condition_type;
	typedef typename inherited::_value_type _value_type;

protected:
	_value_type m_value;

public:
	IC CPropertyEvaluatorConst(_value_type value, LPCSTR evaluator_name = "");
	virtual _value_type evaluate();
};


#include "property_evaluator_const_inline.h"
