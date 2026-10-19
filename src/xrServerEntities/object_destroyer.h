////////////////////////////////////////////////////////////////////////////
//	Module 		: object_destroyer.h
//	Created 	: 21.01.2003
//  Modified 	: 09.07.2004
//	Author		: Dmitriy Iassenev
//	Description : Object destroyer
////////////////////////////////////////////////////////////////////////////

#pragma once

struct CDestroyer
{
	IC static void delete_data(LPCSTR data)
	{
	}

	IC static void delete_data(LPSTR data)
	{
		xr_free(data);
	}

	template <typename T1, typename T2>
	IC static void delete_data(std::pair<T1, T2>& data)
	{
		delete_data(data.first);
		delete_data(data.second);
	}

	template <typename T, int size>
	IC static void delete_data(svector<T, size>& data)
	{
		typename svector<T, size>::iterator I = data.begin();
		typename svector<T, size>::iterator E = data.end();
		for (; I != E; ++I)
			delete_data(*I);
		data.clear();
	}

	template <typename T, int n>
	IC static void delete_data(T (&array)[n])
	{
		T* I = array;
		T* E = array + n;
		for (; I != E; ++I)
			delete_data(*I);
	}

	template <typename T1, typename T2>
	IC static void delete_data(std::queue<T1, T2>& data)
	{
		std::queue<T1, T2> temp = data;
		for (; !temp.empty(); temp.pop())
			delete_data(temp.front());
	}

	template <template <typename _1, typename _2> class T1, typename T2, typename T3>
	IC static void delete_data(T1<T2, T3>& data, bool)
	{
		T1<T2, T3> temp = data;
		for (; !temp.empty(); temp.pop())
			delete_data(temp.top());
	}

	template <template <typename _1, typename _2, typename _3> class T1, typename T2, typename T3, typename T4>
	IC static void delete_data(T1<T2, T3, T4>& data, bool)
	{
		T1<T2, T3, T4> temp = data;
		for (; !temp.empty(); temp.pop())
			delete_data(temp.top());
	}

	template <typename T1, typename T2>
	IC static void delete_data(xr_stack<T1, T2>& data)
	{
		delete_data(data, true);
	}

	template <typename T1, typename T2, typename T3>
	IC static void delete_data(std::priority_queue<T1, T2, T3>& data)
	{
		delete_data(data, true);
	}

	template <typename T>
	struct CHelper1
	{
		// tag-dispatch: nested explicit specialization is an MSVC extension
		IC static void delete_data_impl(T&, std::false_type /*a*/)
		{
		}

		IC static void delete_data_impl(T& data, std::true_type /*a==true*/)
		{
			data.destroy();
		}

		template <bool a>
		IC static void delete_data(T& data)
		{
			delete_data_impl(data, std::integral_constant<bool, a>());
		}
	};

	template <typename T>
	struct CHelper2
	{
		IC static void delete_data_impl(T& data, std::false_type /*not pointer*/)
		{
			CHelper1<T>::template delete_data < object_type_traits::is_base_and_derived<IPureDestroyableObject, T>::value > (data
			);
		}

		IC static void delete_data_impl(T& data, std::true_type /*is pointer*/)
		{
			if (data)
				CDestroyer::delete_data(*data);
			xr_delete(data);
		}

		template <bool a>
		IC static void delete_data(T& data)
		{
			delete_data_impl(data, std::integral_constant<bool, a>());
		}
	};

	struct CHelper3
	{
		template <typename T>
		IC static void delete_data(T& data)
		{
			typename T::iterator I = data.begin();
			typename T::iterator E = data.end();
			for (; I != E; ++I)
				CDestroyer::delete_data(*I);
			data.clear();
		}
	};

	template <typename T>
	struct CHelper4
	{
		IC static void delete_data_impl(T& data, std::false_type /*not stl container*/)
		{
			CHelper2<T>::template delete_data < object_type_traits::is_pointer<T>::value > (data);
		}

		IC static void delete_data_impl(T& data, std::true_type /*is stl container*/)
		{
			CHelper3::delete_data(data);
		}

		template <bool a>
		IC static void delete_data(T& data)
		{
			delete_data_impl(data, std::integral_constant<bool, a>());
		}
	};

	template <typename T>
	IC static void delete_data(T& data)
	{
		CHelper4<T>::template delete_data < object_type_traits::is_stl_container<T>::value > (data);
	}
};

template <typename T>
IC void delete_data(const T& data)
{
	T* temp = const_cast<T*>(&data);
	CDestroyer::delete_data(*temp);
}
