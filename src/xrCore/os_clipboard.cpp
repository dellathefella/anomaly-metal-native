////////////////////////////////////////////////////////////////////////////
// Module : os_clipboard.cpp
// Created : 21.02.2008
// Author : Evgeniy Sokolov
// Description : os clipboard class implementation
//
// POSIX branch uses the SDL2 clipboard API (platform port).
////////////////////////////////////////////////////////////////////////////

#include "stdafx.h"
#pragma hdrstop
#include "os_clipboard.h"

#ifdef XR_PLATFORM_WINDOWS

void os_clipboard::copy_to_clipboard(LPCSTR buf)
{
	if (!OpenClipboard(0))
		return;
	u32 handle_size = (xr_strlen(buf) + 1) * sizeof(char);
	HGLOBAL handle = GlobalAlloc(GHND, handle_size);
	if (!handle)
	{
		CloseClipboard();
		return;
	}

	char* memory = (char*)GlobalLock(handle);
	xr_strcpy(memory, handle_size, buf);
	GlobalUnlock(handle);
	EmptyClipboard();
	SetClipboardData(CF_TEXT, handle);
	CloseClipboard();
}

void os_clipboard::paste_from_clipboard(LPSTR buffer, u32 const& buffer_size)
{
	VERIFY(buffer);
	VERIFY(buffer_size > 0);

	if (!OpenClipboard(0))
		return;

	HGLOBAL hmem = GetClipboardData(CF_TEXT);
	if (!hmem)
		return;

	LPCSTR clipdata = (LPCSTR)GlobalLock(hmem);
	strncpy_s(buffer, buffer_size, clipdata, buffer_size - 1);
	buffer[buffer_size - 1] = 0;
	for (u32 i = 0; i < strlen(buffer); ++i)
	{
		char c = buffer[i];
		if (((isprint(c) == 0) && (c != char(-1))) || c == '\t' || c == '\n') // "я" = -1
		{
			buffer[i] = ' ';
		}
	}

	GlobalUnlock(hmem);
	CloseClipboard();
}

void os_clipboard::update_clipboard(LPCSTR string)
{
	if (!OpenClipboard(0))
		return;

	HGLOBAL handle = GetClipboardData(CF_TEXT);
	if (!handle)
	{
		CloseClipboard();
		copy_to_clipboard(string);
		return;
	}

	LPSTR memory = (LPSTR)GlobalLock(handle);
	int memory_length = (int)strlen(memory);
	int string_length = (int)strlen(string);
	int buffer_size = (memory_length + string_length + 1) * sizeof(char);
#ifndef _EDITOR
	LPSTR buffer = (LPSTR)_alloca(buffer_size);
#else // #ifndef _EDITOR
    LPSTR buffer = (LPSTR)xr_alloc<char>( buffer_size );
#endif // #ifndef _EDITOR
	xr_strcpy(buffer, buffer_size, memory);
	GlobalUnlock(handle);

	xr_strcat(buffer, buffer_size, string);
	CloseClipboard();
	copy_to_clipboard(buffer);
#ifdef _EDITOR
    xr_free (buffer);
#endif // #ifdef _EDITOR
}

#else // POSIX

#include <SDL.h>

void os_clipboard::copy_to_clipboard(LPCSTR buf)
{
	const int result = SDL_SetClipboardText(buf);
	if (result < 0)
	{
		Msg("! Failed to copy text to the clipboard: %s", SDL_GetError());
	}
}

void os_clipboard::paste_from_clipboard(LPSTR buffer, u32 const& buffer_size)
{
	VERIFY(buffer);
	VERIFY(buffer_size > 0);

	if (!SDL_HasClipboardText())
		return;

	char* clipdata = SDL_GetClipboardText();
	if (!clipdata)
	{
		Msg("! Failed to paste text from the clipboard: %s", SDL_GetError());
		return;
	}

	strncpy_s(buffer, buffer_size, clipdata, buffer_size - 1);
	buffer[buffer_size - 1] = 0;
	for (u32 i = 0; i < strlen(buffer); ++i)
	{
		char c = buffer[i];
		if (((isprint(c) == 0) && (c != char(-1))) || c == '\t' || c == '\n')
		{
			buffer[i] = ' ';
		}
	}

	SDL_free(clipdata);
}

void os_clipboard::update_clipboard(LPCSTR string)
{
	if (!string)
	{
		Msg("! Why are you trying to copy nullptr to the clipboard?!");
		return;
	}

	if (!SDL_HasClipboardText())
	{
		copy_to_clipboard(string);
		return;
	}

	char* clipdata = SDL_GetClipboardText();
	if (!clipdata)
	{
		copy_to_clipboard(string);
		return;
	}

	const size_t buffer_size = (xr_strlen(clipdata) + xr_strlen(string) + 1) * sizeof(char);
	LPSTR buffer = (LPSTR)xr_alloc<char>(static_cast<u32>(buffer_size));
	xr_strcpy(buffer, buffer_size, clipdata);
	xr_strcat(buffer, buffer_size, string);
	SDL_free(clipdata);

	copy_to_clipboard(buffer);
	xr_free(buffer);
}

#endif // XR_PLATFORM_WINDOWS
