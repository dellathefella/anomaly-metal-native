#pragma once

#include "chimera_state_hunting_move_to_cover.h"
#include "chimera_state_hunting_come_out.h"

#define TEMPLATE_SPECIALIZATION template <\
	typename _Object\
>

#define CStateChimeraHuntingAbstract CStateChimeraHunting<_Object>

TEMPLATE_SPECIALIZATION
CStateChimeraHuntingAbstract::CStateChimeraHunting(_Object* obj) : inherited(obj)
{
	this->add_state(eStateMoveToCover, xr_new<CStateChimeraHuntingMoveToCover<_Object>>(obj));
	this->add_state(eStateComeOut, xr_new<CStateChimeraHuntingComeOut<_Object>>(obj));
}


TEMPLATE_SPECIALIZATION
bool CStateChimeraHuntingAbstract::check_start_conditions()
{
	return true;
}

TEMPLATE_SPECIALIZATION
bool CStateChimeraHuntingAbstract::check_completion()
{
	return false;
}

TEMPLATE_SPECIALIZATION
void CStateChimeraHuntingAbstract::reselect_state()
{
	if (this->prev_substate == u32(-1)) this->select_state(eStateMoveToCover);
	else if (this->prev_substate == eStateMoveToCover) this->select_state(eStateComeOut);
	else this->select_state(eStateMoveToCover);
}


#undef TEMPLATE_SPECIALIZATION
#undef CStateChimeraHuntingAbstract
