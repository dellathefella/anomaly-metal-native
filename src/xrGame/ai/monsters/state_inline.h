#pragma once

#define TEMPLATE_SPECIALIZATION template <\
	typename _Object\
>

#define CStateAbstract CState<_Object>

TEMPLATE_SPECIALIZATION
CStateAbstract::CState(_Object* obj, void* data)
{
	reset();

	this->object = obj;
	this->_data = data;
}

TEMPLATE_SPECIALIZATION
CStateAbstract::~CState()
{
	this->free_mem();
}

TEMPLATE_SPECIALIZATION
void CStateAbstract::reinit()
{
	if (this->current_substate != u32(-1)) this->get_state_current()->critical_finalize();

	for (STATE_MAP_IT it = this->substates.begin(); it != this->substates.end(); it++)
		it->second->reinit();

	reset();
}


TEMPLATE_SPECIALIZATION
void CStateAbstract::initialize()
{
	this->time_state_started = Device.dwTimeGlobal;

	this->current_substate = u32(-1); // means need reselect state
	this->prev_substate = u32(-1);
}

TEMPLATE_SPECIALIZATION
void CStateAbstract::execute()
{
	VERIFY(this->object->g_Alive());
	// проверить внешние условия изменения состояния
	check_force_state();

	// если состояние не выбрано, перевыбрать
	if (this->current_substate == u32(-1))
	{
		reselect_state();

#ifdef DEBUG
		// Lain: added
			if ( this->current_substate == u32(-1) )
			{
				debug::text_tree tree;
				if ( CBaseMonster* p_monster = smart_cast<CBaseMonster*>(this->object) )
				{
					p_monster->add_debug_info(tree);
				}
				
				debug::log_text_tree(tree);
				VERIFY(this->current_substate != u32(-1)); 
			}
#endif
	}

	// выполнить текущее состояние
	CSState* state = this->get_state(this->current_substate);
	state->execute();

	// сохранить текущее состояние
	this->prev_substate = this->current_substate;

	// проверить на завершение текущего состояния
	if (state->check_completion())
	{
		state->finalize();
		this->current_substate = u32(-1);
	}
}

TEMPLATE_SPECIALIZATION
void CStateAbstract::finalize()
{
	reset();
}

TEMPLATE_SPECIALIZATION
void CStateAbstract::critical_finalize()
{
	if (this->current_substate != u32(-1)) this->get_state_current()->critical_finalize();
	reset();
}

TEMPLATE_SPECIALIZATION
void CStateAbstract::reset()
{
	this->current_substate = u32(-1);
	this->prev_substate = u32(-1);
	this->time_state_started = 0;
}

TEMPLATE_SPECIALIZATION
void CStateAbstract::select_state(u32 new_state_id)
{
	if (this->current_substate == new_state_id) return;
	CSState* state;

	// если предыдущее состояние активно, завершить его
	if (this->current_substate != u32(-1))
	{
		state = this->get_state(this->current_substate);
		state->critical_finalize();
	}

	// установить новое состояние
	state = this->get_state(this->current_substate = new_state_id);

	// инициализировать новое состояние
	setup_substates();

	state->initialize();
}

TEMPLATE_SPECIALIZATION
CStateAbstract* CStateAbstract::get_state(u32 state_id)
{
	STATE_MAP_IT it = this->substates.find(state_id);
	VERIFY(it != this->substates.end());

	return it->second;
}

TEMPLATE_SPECIALIZATION
void CStateAbstract::add_state(u32 state_id, CSState* s)
{
	this->substates.insert(mk_pair(state_id, s));
}

TEMPLATE_SPECIALIZATION
void CStateAbstract::free_mem()
{
	for (STATE_MAP_IT it = this->substates.begin(); it != this->substates.end(); it++) xr_delete(it->second);
}

TEMPLATE_SPECIALIZATION
void CStateAbstract::fill_data_with(void* ptr_src, u32 size)
{
	VERIFY(ptr_src);
	VERIFY(this->_data);

	CopyMemory(this->_data, ptr_src, size);
}

#ifdef DEBUG

TEMPLATE_SPECIALIZATION
void   CStateAbstract::add_debug_info (debug::text_tree& root_s)
{
	typedef debug::text_tree TextTree;
	if ( !this->substates.size() )
	{
		root_s.add_line("Current");		
	}
	else
	{
		for ( SubStates::const_iterator i=this->substates.begin(), e=this->substates.end();
			  i!=e; ++i )
		{
			TextTree& current_state_s = root_s.add_line(EMonsterState((*i).first));
			if ( this->current_substate == (*i).first )
			{
				if ( (*i).second )
				{
					(*i).second->add_debug_info(current_state_s);
				}
				else
				{
					current_state_s.add_line("Current");
				}
			}
		}
	}
}

#endif

TEMPLATE_SPECIALIZATION
CStateAbstract*CStateAbstract::get_state_current()
{
	if (this->substates.empty() || (this->current_substate == u32(-1))) return 0;

	STATE_MAP_IT it = this->substates.find(this->current_substate);
	VERIFY(it != this->substates.end());

	return it->second;
}

TEMPLATE_SPECIALIZATION
EMonsterState CStateAbstract::get_state_type()
{
	if (this->substates.empty() || (this->current_substate == u32(-1))) return eStateUnknown;

	EMonsterState state = this->get_state_current()->get_state_type();
	return ((state == eStateUnknown) ? EMonsterState(this->current_substate) : state);
}

TEMPLATE_SPECIALIZATION
void CStateAbstract::remove_links(CObject* object)
{
	typename SubStates::iterator i = this->substates.begin();
	typename SubStates::iterator e = this->substates.end();
	for (; i != e; ++i)
		(*i).second->remove_links(object);;
}

TEMPLATE_SPECIALIZATION
bool CStateAbstract::check_control_start_conditions(ControlCom::EControlType type)
{
	CState* child = this->get_state_current();
	if (child && !child->check_control_start_conditions(type))
	{
		return false;
	}

	return true;
}

#undef TEMPLATE_SPECIALIZATION
