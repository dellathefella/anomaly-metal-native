#pragma once

#include "../states/monster_state_rest_sleep.h"
#include "../states/state_move_to_restrictor.h"
#include "../ai_monster_squad.h"
#include "../ai_monster_squad_manager.h"
#include "../monster_home.h"
#include "../anomaly_detector.h"
#include "../states/monster_state_home_point_rest.h"
#include "../states/monster_state_smart_terrain_task.h"
#include "group_state_rest_idle.h"
#include "group_state_custom.h"

#define TEMPLATE_SPECIALIZATION template <\
	typename _Object\
>

#define CStateGroupRestAbstract CStateGroupRest<_Object>

TEMPLATE_SPECIALIZATION
CStateGroupRestAbstract::CStateGroupRest(_Object* obj) : inherited(obj)
{
	add_state(eStateRest_Sleep, xr_new<CStateMonsterRestSleep<_Object>>(obj));
	add_state(eStateCustomMoveToRestrictor, xr_new<CStateMonsterMoveToRestrictor<_Object>>(obj));
	add_state(eStateRest_MoveToHomePoint, xr_new<CStateMonsterRestMoveToHomePoint<_Object>>(obj));
	add_state(eStateSmartTerrainTask, xr_new<CStateMonsterSmartTerrainTask<_Object>>(obj));
	add_state(eStateRest_Idle, xr_new<CStateGroupRestIdle<_Object>>(obj));
	add_state(eStateCustom, xr_new<CStateCustomGroup<_Object>>(obj));
}

TEMPLATE_SPECIALIZATION
CStateGroupRestAbstract::~CStateGroupRest()
{
}

TEMPLATE_SPECIALIZATION
void CStateGroupRestAbstract::initialize()
{
	inherited::initialize();
	time_for_sleep = 0;
	time_for_life = time() + object->m_min_life_time + Random.randI(10) * object->m_min_life_time;
	this->object->anomaly_detector().activate();
}

TEMPLATE_SPECIALIZATION
void CStateGroupRestAbstract::finalize()
{
	inherited::finalize();

	this->object->anomaly_detector().deactivate();
}

TEMPLATE_SPECIALIZATION
void CStateGroupRestAbstract::critical_finalize()
{
	inherited::critical_finalize();

	this->object->anomaly_detector().deactivate();
}

TEMPLATE_SPECIALIZATION
void CStateGroupRestAbstract::execute()
{
	// check alife control

	bool captured_by_smart_terrain = false;

	if (prev_substate == eStateSmartTerrainTask)
	{
		if (!get_state(eStateSmartTerrainTask)->check_completion())
			captured_by_smart_terrain = true;
	}
	else if (get_state(eStateSmartTerrainTask)->check_start_conditions())
		captured_by_smart_terrain = true;

	if (captured_by_smart_terrain) select_state(eStateSmartTerrainTask);
	else
	{
		// check restrictions
		bool move_to_restrictor = false;

		if (prev_substate == eStateCustomMoveToRestrictor)
		{
			if (!get_state(eStateCustomMoveToRestrictor)->check_completion())
				move_to_restrictor = true;
		}
		else if (get_state(eStateCustomMoveToRestrictor)->check_start_conditions())
			move_to_restrictor = true;

		if (move_to_restrictor) select_state(eStateCustomMoveToRestrictor);
		else
		{
			// check home point
			bool move_to_home_point = false;

			if (prev_substate == eStateRest_MoveToHomePoint)
			{
				if (!get_state(eStateRest_MoveToHomePoint)->check_completion())
					move_to_home_point = true;
			}
			else if (get_state(eStateRest_MoveToHomePoint)->check_start_conditions())
				move_to_home_point = true;

			if (move_to_home_point) select_state(eStateRest_MoveToHomePoint);
			else
			{
				// check squad behaviour
				if (object->saved_state == eStateRest_Sleep)
				{
					switch (object->get_number_animation())
					{
					case u32(8):
						this->object->set_current_animation(13);
						break;
					case u32(14):
						this->object->set_current_animation(12);
						break;
					case u32(12):
						this->object->set_current_animation(7);
						this->object->saved_state = u32(-1);
						break;
					default:
						break;
					}
					if (object->b_state_check)
					{
						this->object->b_state_check = false;
						this->select_state(eStateCustom);
						get_state_current()->execute();
						this->prev_substate = current_substate;
						return;
					}
				}
				if (time() < time_for_sleep && object->saved_state == eStateRest_Sleep && object->get_number_animation()
					== u32(13))
				{
					this->select_state(eStateRest_Sleep);
					get_state_current()->execute();
					this->prev_substate = current_substate;
					return;
				}
				bool use_to_do = false;
				if (prev_substate == eStateRest_Sleep)
				{
					if (time() <= time_for_sleep)
					{
						use_to_do = true;
					}
					else
					{
						time_for_life = time() + object->m_min_life_time + Random.randI(10) * object->m_min_life_time;
						this->object->set_current_animation(14);
						this->select_state(eStateCustom);
						this->object->b_state_check = false;
						get_state_current()->execute();
						this->prev_substate = current_substate;
						return;
					}
				}
				if (!use_to_do)
				{
					if (time() > time_for_life && object->Home->at_min_home(object->Position()))
					{
						this->object->set_current_animation(8);
						this->select_state(eStateCustom);
						this->object->saved_state = eStateRest_Sleep;
						time_for_sleep = time() + object->m_min_sleep_time + Random.randI(5) * object->m_min_sleep_time;
						use_to_do = true;
						this->object->b_state_check = false;
						get_state_current()->execute();
						this->prev_substate = current_substate;
						return;
					}
					else
					{
						if (object->saved_state != eStateRest_Sleep && prev_substate == eStateCustom && object->
							get_number_animation() >= u32(8) && object->get_number_animation() < u32(12))
						{
							this->object->set_current_animation(object->get_number_animation() + u32(1));
							this->select_state(eStateCustom);
							this->object->b_state_check = false;
							get_state_current()->execute();
							this->prev_substate = current_substate;
							return;
						}
						if (object->b_state_check)
						{
							this->select_state(eStateCustom);
							this->object->b_state_check = false;
						}
						else
						{
							this->select_state(eStateRest_Idle);
						}
					}
				}
			}
		}
	}

	get_state_current()->execute();
	this->prev_substate = current_substate;
}

#undef TEMPLATE_SPECIALIZATION
#undef CStateGroupRestAbstract
