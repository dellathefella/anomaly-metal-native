#pragma once
// p4 GL-renderer port shim: dev's xrCore/Threading/TaskManager.hpp.
// The port runs renderer tasking synchronously (single render thread); the
// surface mirrors the call shapes the staged sources use:
//   TaskScheduler->AddTask(callable) -> Task& (runs immediately)
//   TaskScheduler->Wait(task)        -> no-op (already complete)
//   TaskManager::AddTask(callable)   -> Task&
#include <utility>

class Task
{
	int m_id{ 0 };

public:
	int id() const { return m_id; }
};

namespace xr_port
{
	class sync_task_scheduler
	{
		Task m_done{};

	public:
		template <class F>
		Task& AddTask(F&& f)
		{
			f();
			return m_done;
		}

		void Wait(Task&) {}

		size_t GetWorkersCount() { return 1; }
	};

	inline sync_task_scheduler& task_scheduler()
	{
		static sync_task_scheduler instance;
		return instance;
	}
} // namespace xr_port

#define TaskScheduler (&xr_port::task_scheduler())

namespace TaskManager
{
	template <class F>
	Task& AddTask(F&& f)
	{
		return xr_port::task_scheduler().AddTask(std::forward<F>(f));
	}
} // namespace TaskManager
