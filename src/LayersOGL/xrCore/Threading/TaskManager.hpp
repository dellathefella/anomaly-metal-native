#pragma once
// p4 GL-renderer port shim: dev's xrCore/Threading/TaskManager.hpp.
// The port runs renderer tasking synchronously (single render thread) while
// preserving the lifecycle the staged sources rely on:
//   CreateTask(fn)          -> pending task (not yet run)
//   AddTask(fn)             -> runs fn immediately (DetailManager usage)
//   AddTask(pred, fn)       -> subtask chained after pred (runs with pred)
//   RunTask/PushTask/Wait   -> drive the task (and its chain) to completion
#include <deque>
#include <functional>
#include <utility>

class Task
{
	friend class sync_task_scheduler;

	std::function<void()> m_fn{};
	bool m_done{ true };
	int m_id{ 0 };

public:
	int id() const { return m_id; }
};

namespace xr_port
{
	class sync_task_scheduler
	{
		// Tasks are referenced by pointer across a frame at most; a small
		// stable ring is plenty (r2 phases hold ~2 tasks each).
		static constexpr size_t pool_size = 64;
		std::deque<Task> m_pool;
		size_t m_next{ 0 };
		int m_counter{ 0 };

		Task& acquire()
		{
			if (m_pool.size() < pool_size)
				m_pool.emplace_back();
			Task& t = m_pool[m_next];
			m_next = (m_next + 1) % pool_size;
			t.m_fn = nullptr;
			t.m_done = true;
			t.m_id = ++m_counter;
			return t;
		}

		static void run(Task& t)
		{
			if (t.m_done)
				return;
			t.m_done = true; // set before running: chains must not re-enter
			if (t.m_fn)
			{
				auto fn = std::move(t.m_fn);
				fn();
			}
		}

	public:
		template <class F>
		Task& CreateTask(F&& f)
		{
			Task& t = acquire();
			t.m_fn = std::forward<F>(f);
			t.m_done = false;
			return t;
		}

		// DetailManager style: fire immediately.
		template <class F>
		Task& AddTask(F&& f)
		{
			f();
			return acquire(); // trivial completed task handle
		}

		// r2 phase style: subtask chained after pred. Sequential execution
		// makes "after pred" simply "inside pred's continuation".
		template <class F>
		Task& AddTask(Task& pred, F&& f)
		{
			Task& t = acquire();
			t.m_fn = std::forward<F>(f);
			t.m_done = false;
			if (pred.m_done)
				run(t);
			else
			{
				pred.m_fn = [pred_fn = std::move(pred.m_fn), &t]() {
					pred_fn();
					run(t);
				};
			}
			return t;
		}

		void PushTask(Task& t) { run(t); }
		void RunTask(Task& t) { run(t); }
		void Wait(Task& t) { run(t); }

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
