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
var _needs_sort: bool = false


func _init(concurrency: int = 0) -> void:
	max_in_flight = concurrency if concurrency > 0 else maxi(
		OS.get_processor_count() - 1, 2
	)


func enqueue(job: Job) -> void:
	_waiting.append(job)
	_needs_sort = true


## Nearest work first, so the ground under the player appears before the horizon.
func sort_waiting() -> void:
	_waiting.sort_custom(func(a: Job, b: Job) -> bool: return a.priority < b.priority)
	_needs_sort = false


## Refresh priorities from the caller's current focus (player chunk), then sort.
## Without this, "nearest" freezes at enqueue time and a moving player starves
## the ground ahead with obsolete near-work that is now behind them.
func retarget_waiting(update_priority: Callable) -> void:
	for job in _waiting:
		update_priority.call(job)
	sort_waiting()


func pump() -> void:
	if _needs_sort and not _waiting.is_empty():
		sort_waiting()
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


## Drops queued work the caller no longer wants and hands it back, so it can
## forget the jobs too. Jobs already on a worker are left alone; cancelling them
## mid-flight would cost more than letting them finish.
##
## A player moving faster than the world can be built outruns the queue, and
## without this the workers spend their time on ground that is already behind
## the player while the ground ahead stays empty.
func drop_waiting(should_drop: Callable) -> Array[Job]:
	var kept: Array[Job] = []
	var dropped: Array[Job] = []
	for job in _waiting:
		if should_drop.call(job):
			dropped.append(job)
		else:
			kept.append(job)
	_waiting = kept
	if not dropped.is_empty():
		_needs_sort = true
	return dropped


## Blocks until every dispatched job has finished. Only used on shutdown.
## Each task id must be waited exactly once ([method collect] already waits
## completed jobs and removes them from [_running]).
func drain() -> void:
	for job in _running:
		if job.task_id >= 0:
			WorkerThreadPool.wait_for_task_completion(job.task_id)
			job.task_id = -1
	_running.clear()
	_waiting.clear()
