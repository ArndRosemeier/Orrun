class_name GenQueue
extends RefCounted
## Background work scheduler.
##
## Jobs are plain objects that compute data and touch nothing in the SceneTree.
## The main thread pulls finished jobs and does all node, mesh and shape
## creation itself, which keeps generation off the frame budget without any of
## the failure modes of building nodes from a worker.

class Job extends RefCounted:
	var task_id: int = -1
	var priority: float = 0.0

	## Runs on a worker thread. Must not touch nodes, servers or shared state.
	func run() -> void:
		push_error("GenQueue.Job.run is abstract")


var max_in_flight: int = 4
var _running: Array[Job] = []
var _waiting: Array[Job] = []


func _init(concurrency: int = 0) -> void:
	max_in_flight = concurrency if concurrency > 0 else maxi(
		OS.get_processor_count() - 1, 2
	)


func enqueue(job: Job) -> void:
	_waiting.append(job)


## Nearest work first, so the ground under the player appears before the horizon.
func sort_waiting() -> void:
	_waiting.sort_custom(func(a: Job, b: Job) -> bool: return a.priority < b.priority)


func pump() -> void:
	while _running.size() < max_in_flight and not _waiting.is_empty():
		var job: Job = _waiting.pop_front()
		job.task_id = WorkerThreadPool.add_task(Callable(job, "run"))
		_running.append(job)


func collect() -> Array[Job]:
	var done: Array[Job] = []
	var still_running: Array[Job] = []
	for job in _running:
		if WorkerThreadPool.is_task_completed(job.task_id):
			WorkerThreadPool.wait_for_task_completion(job.task_id)
			done.append(job)
		else:
			still_running.append(job)
	_running = still_running
	return done


func waiting_count() -> int:
	return _waiting.size()


func running_count() -> int:
	return _running.size()


## Drops work that has not started yet and hands it back, so the caller can
## forget about it. Jobs already on a worker are left alone; cancelling them
## mid-flight would cost more than letting them finish.
func clear_waiting() -> Array[Job]:
	var dropped: Array[Job] = _waiting
	_waiting = []
	return dropped


## Blocks until every dispatched job has finished. Only used on shutdown.
func drain() -> void:
	for job in _running:
		WorkerThreadPool.wait_for_task_completion(job.task_id)
	_running.clear()
	_waiting.clear()
