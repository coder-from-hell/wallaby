defmodule Wallaby.SessionStore do
  @moduledoc false
  use GenServer
  use EventEmitter, :emitter

  alias Wallaby.WebdriverClient

  def start_link(opts \\ []) do
    {opts, args} = Keyword.split(opts, [:name])

    GenServer.start_link(__MODULE__, args, opts)
  end

  def monitor(store \\ __MODULE__, session) do
    GenServer.call(store, {:monitor, session}, 10_000)
  end

  def demonitor(store \\ __MODULE__, session) do
    GenServer.call(store, {:demonitor, session})
  end

  def list_sessions_for(opts \\ []) do
    name = Keyword.get(opts, :name, :session_store)
    owner_pid = Keyword.get(opts, :owner_pid, self())

    :ets.select(name, [{{{:_, :_, :"$1"}, :"$2"}, [{:==, :"$1", owner_pid}], [:"$2"]}])
  end

  def init(args) do
    name = Keyword.get(args, :ets_name, :session_store)

    opts =
      if(name == :session_store, do: [:named_table], else: []) ++
        [:set, :public, read_concurrency: true]

    Process.flag(:trap_exit, true)
    tid = :ets.new(name, opts)

    Application.ensure_all_started(:ex_unit)

    ExUnit.after_suite(fn _ ->
      try do
        IO.puts("CLEARE SESSIONS AFTER SUITE")
        :ets.tab2list(tid)
        |> then(fn sessions -> Enum.count(sessions)|> IO.inspect(label: "count"); sessions end)
        |> Enum.each(&delete_sessions/1)
      rescue
        _ -> nil
      end
    end)

    {:ok, %{ets_table: tid}}
  end

  def handle_call({:monitor, session}, {pid, _ref}, state) do
    IO.puts("Session added to Storage")

    ref = Process.monitor(pid)

    :ets.insert(state.ets_table, {{ref, session.id, pid}, session})

    emit(%{module: __MODULE__, name: :monitor, metadata: %{monitored_session: session}})

    IO.puts("Total number of sessions #{total_number_of_sessions(state)}")

    {:reply, :ok, state}
  end

  def handle_call({:demonitor, session}, _from, state) do
    IO.puts("Manual deleting session")

    result =
      :ets.select(state.ets_table, [
        {{{:"$1", :"$2", :"$3"}, :_}, [{:==, :"$2", session.id}], [{{:"$1", :"$3"}}]}
      ])

    case result do
      [{ref, pid}] ->
        true = Process.demonitor(ref)
        :ets.delete(state.ets_table, {ref, session.id, pid})

      [] ->
        :ok
    end

    IO.puts("total sessions after deleting #{total_number_of_sessions(state)}")

    {:reply, :ok, state}
  end

  def handle_info({:DOWN, ref, :process, pid, _reason}, state) do
    IO.puts("Test process is down deleting session")

    [session] =
      :ets.select(state.ets_table, [
        {{{:"$1", :_, :_}, :"$4"}, [{:==, :"$1", ref}], [:"$4"]}
      ])

    WebdriverClient.delete_session(session)

    :ets.delete(state.ets_table, {ref, session.id, pid})

    emit(%{module: __MODULE__, name: :DOWN, metadata: %{monitored_session: session}})

    IO.puts("total sessions after deleting #{total_number_of_sessions(state)}")

    {:noreply, state}
  end

  defp delete_sessions({_, session}) do
    WebdriverClient.delete_session(session)
  end

  defp total_number_of_sessions(state) do
    :ets.tab2list(state.ets_table) |> Enum.count()
  end
end
