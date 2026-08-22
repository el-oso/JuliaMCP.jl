# state.jl — Application state

mutable struct AppState
    workspace::Union{Nothing,JuliaWorkspaces.JuliaWorkspace}
    # The TestItemRuns session: controller, process pool and run bookkeeping.
    session::Union{Nothing,TIR.TestSession}
    runs::Dict{String,TestRunRecord}          # the MCP-facing projection of every run
    active_runs::Dict{String,TIR.TestRun}     # testrun_id → run, while it is running
    endpoint::JSONRPC.JSONRPCEndpoint
    subscriptions::Set{String}
    log_level::Symbol  # MCP log level: :debug, :info, :notice, :warning, :error, :critical, :alert, :emergency
    session_controller::Union{Nothing,JSC.JuliaSessionController}
    session_reactor_task::Union{Nothing,Task}
    sessions::Dict{String,SessionRecord}
    lock::ReentrantLock
    # The Salsa runtime behind `workspace` is not safe for concurrent access, and
    # both the message loop and the file watcher touch it — so every call into
    # JuliaWorkspaces must hold this lock.
    workspace_lock::ReentrantLock
    folders::Vector{String}
    watcher_task::Union{Nothing,Task}
    watcher_stop::Union{Nothing,Ref{Bool}}
    watcher_snapshot::Dict{String,Float64}
end

function AppState(endpoint::JSONRPC.JSONRPCEndpoint)
    return AppState(
        nothing,
        nothing,
        Dict{String,TestRunRecord}(),
        Dict{String,TIR.TestRun}(),
        endpoint,
        Set{String}(),
        :info,
        nothing,
        nothing,
        Dict{String,SessionRecord}(),
        ReentrantLock(),
        ReentrantLock(),
        String[],
        nothing,
        nothing,
        Dict{String,Float64}(),
    )
end

"""
Run `f` while holding the workspace lock.
"""
with_workspace_lock(f, state::AppState) = lock(f, state.workspace_lock)
