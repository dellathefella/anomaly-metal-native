////////////////////////////////////////////////////////////////////////////
//	Module 		: stalker_animation_manager_impl.h
//	Created 	: 16.11.2003
//  Modified 	: 16.11.2005
//	Author		: Dmitriy Iassenev
//	Description : Stalker animation manager inline functions
////////////////////////////////////////////////////////////////////////////

#pragma once

#include "CharacterPhysicsSupport.h"

IC CStalkerAnimationManager::EBodyState CStalkerAnimationManager::body_state() const
{
	return (object().movement().body_state());
}

// p4: standing() definition moved to stalker_animation_global.cpp — several
// TUs include this header, so an out-of-line definition here would be a
// duplicate, and an `inline` one risks no emitted copy (fully inlined) while
// other TUs still reference it out-of-line under clang.

IC void CStalkerAnimationManager::fill_object_info()
{
	CInventoryItem* item = object().inventory().ActiveItem();
	VERIFY(item);
	m_weapon = smart_cast<CWeapon*>(item);
	m_missile = smart_cast<CMissile*>(item);
}

IC bool CStalkerAnimationManager::strapped() const
{
	VERIFY(m_weapon);
	return (object().CObjectHandler::weapon_strapped(m_weapon));
}

IC u32 CStalkerAnimationManager::object_slot() const
{
	if (m_weapon)
		return (m_weapon->animation_slot());

	if (m_missile)
		return (m_missile->animation_slot());

	return (0);
}
