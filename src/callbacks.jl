# callbacks.jl — TestItemRuns event sink: MCP notifications, progress and run bookkeeping

# Every event of the session (all runs plus the process pool) arrives here, off the
# controller's reactor task, one at a time.
handle_event(state::AppState, ::TIR.RunEvent) = nothing

function _run_item(state::AppState, run::TIR.TestRun, item::TIR.TestItem)
    rec = get(state.runs, run.id, nothing)
    rec === nothing && return nothing
    return get(rec.items, item.id, nothing)
end

function handle_event(state::AppState, ev::TIR.TestItemStarted)
    lock(state.lock) do
        item = _run_item(state, ev.run, ev.item)
        item === nothing && return
        item.status = :running
    end
    mcp_info(state, "testitem", "Started: $(ev.item.name)")
    notify_resource_updated(state, "testrun://$(ev.run.id)/summary")
end

function handle_event(state::AppState, ev::TIR.TestItemFinished)
    lock(state.lock) do
        item = _run_item(state, ev.run, ev.item)
        item === nothing && return
        item.status = ev.status
        item.duration = ev.duration
        if ev.messages !== nothing
            item.messages = [testmessage_to_dict(m) for m in ev.messages]
        end
    end
    label = ev.item.name
    dur_str = ev.duration !== nothing ? " ($(round(ev.duration, digits=2))ms)" : ""
    msg_summary = ev.messages === nothing || isempty(ev.messages) ? "" : ": $(first(ev.messages).message)"
    if ev.status === :passed
        mcp_info(state, "testitem", "Passed: $label$dur_str")
    elseif ev.status === :failed
        mcp_warn(state, "testitem", "Failed: $label$dur_str$msg_summary")
    elseif ev.status === :errored
        mcp_error(state, "testitem", "Errored: $label$dur_str$msg_summary")
    else
        mcp_info(state, "testitem", "Skipped: $label")
    end
    report_run_progress(state, ev.run.id)
    notify_resource_updated(state, "testrun://$(ev.run.id)/summary")
    ev.status in (:passed, :failed, :errored) && notify_resource_updated(state, "testrun://$(ev.run.id)/failures")
end

function handle_event(state::AppState, ev::TIR.OutputAppended)
    lock(state.lock) do
        item = _run_item(state, ev.run, ev.item)
        item === nothing && return
        push!(item.output, ev.output)
    end
    notify_resource_updated(state, "testrun://$(ev.run.id)/items/$(ev.item.id)/output")
end

function handle_event(state::AppState, ev::TIR.ProcessCreated)
    mcp_notice(state, "controller", "Process created for $(ev.package_name) (id=$(ev.id))")
    note_run_progress(state, "starting test process for $(ev.package_name)")
    notify_resource_list_changed(state)
end

function handle_event(state::AppState, ev::TIR.ProcessTerminated)
    mcp_notice(state, "controller", "Process terminated (id=$(ev.id))")
    notify_resource_list_changed(state)
end

function handle_event(state::AppState, ev::TIR.ProcessStatusChanged)
    mcp_debug(state, "controller", "Process $(ev.id): $(ev.status)")
    note_run_progress(state, "test process $(ev.status)")
end

function handle_event(state::AppState, ev::TIR.ProcessOutput)
    mcp_debug(state, "controller", ev.output)
end

function report_run_progress(state::AppState, testrun_id::String)
    run = lock(state.lock) do
        get(state.runs, testrun_id, nothing)
    end
    run === nothing && return
    report_progress!(state, run)
end

# Process events carry no testrun id, so the note goes to whichever runs are active.
function note_run_progress(state::AppState, note::String)
    lock(state.lock) do
        for run in values(state.runs)
            run.status === :running && (run.progress_note = note)
        end
    end
end

"""
    init_controller!(state)

Create the TestItemRuns session (controller, reactor, process pool) on first use. Runs are
retained without limit: every past run stays addressable as an MCP resource.
"""
function init_controller!(state::AppState)
    s = state.session
    s !== nothing && isopen(s) && return
    state.session = TIR.TestSession(; on_event = ev -> handle_event(state, ev), max_history = nothing)
    mcp_notice(state, "transport", "TestItemController initialized")
end

function shutdown_controller!(state::AppState)
    s = state.session
    s === nothing && return
    close(s)
    state.session = nothing
    lock(state.lock) do
        empty!(state.active_runs)
    end
end
