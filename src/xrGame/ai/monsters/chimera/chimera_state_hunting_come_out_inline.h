#pragma once

#define TEMPLATE_SPECIALIZATION template <\
	typename _Object\
>

#define CStateChimeraHuntingMoveToCoverAbstract CStateChimeraHuntingMoveToCover<_Object>

TEMPLATE_SPECIALIZATION
CStateChimeraHuntingMoveToCoverAbstract::CStateChimeraHuntingMoveToCover(_Object* obj) : inherited(obj)
{
}


TEMPLATE_SPECIALIZATION
bool CStateChimeraHuntingMoveToCoverAbstract::check_start_conditions()
{
	return true;
}

TEMPLATE_SPECIALIZATION
bool CStateChimeraHuntingMoveToCoverAbstract::check_completion()
{
	return false;
}

TEMPLATE_SPECIALIZATION
void CStateChimeraHuntingMoveToCoverAbstract::reselect_state()
{
	if (this->prev_substate == u32(-1)) this->select_state(eStateMoveToCover);
	else if (this->prev_substate == eStateMoveToCover) this->select_state(eStateComeOut);
	else this->select_state(eStateMoveToCover);
}


#undef TEMPLATE_SPECIALIZATION
#undef CStateChimeraHuntingMoveToCoverAbstract
