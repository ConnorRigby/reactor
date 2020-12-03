defmodule Mix.Tasks.Reactor do
  @moduledoc """
  Usage:

      iex --name reactor@hostname.local --cookie democookie -S mix reactor --node remote@hostname.local
  """
  use Mix.Task

  @strict [
    node: :string
  ]

  defmodule Server do
    use GenServer

    def start_link(node, mix_project_config) do
      GenServer.start_link(__MODULE__, [node, mix_project_config])
    end

    @impl GenServer
    def init([node, mix_project_config]) do
      app = mix_project_config[:app]
      version = mix_project_config[:version]

      # not sure why this is required. Must be a Mix thing?
      :ok = :application.load(app)

      # See below for why we watch the ebin directories.
      ebin_dirs = Mix.Project.build_path() |> Path.join("lib/*/ebin/") |> Path.wildcard()
      src_dirs = Keyword.fetch!(mix_project_config, :elixirc_paths) |> Enum.map(&Path.expand/1)

      with {:ok, ebin_pid} <- FileSystem.start_link(dirs: ebin_dirs),
           {:ok, src_pid} <- FileSystem.start_link(dirs: src_dirs) do
        FileSystem.subscribe(ebin_pid)
        FileSystem.subscribe(src_pid)
        {:ok, %{node: node, app: app, version: version, ebin_pid: ebin_pid, src_pid: src_pid}}
      else
        {:error, reason} ->
          {:stop, reason}
      end
    end

    @impl GenServer
    # this makes it so when you `mix deps.compile` for example, it will reload a sub dep's beam files.
    # ISSUE: priv files of course.
    def handle_info(
          {:file_event, ebin, {file_path, [:modified, :closed]}},
          %{ebin_pid: ebin} = state
        ) do
      Mix.shell().info("Reloading #{file_path} on #{state.node}")
      # I don't think module names are *required* to be in this shape,
      # but I've never once seen one that doesn't follow this convention...
      module = Path.rootname(file_path) |> Path.basename() |> String.to_atom()
      NervesReactor.reload_module(state.node, module)
      {:noreply, state}
    end

    def handle_info(
          {:file_event, src, {file_path, [:modified, :closed]}},
          %{src_pid: src} = state
        ) do
      Mix.shell().info("Recompiling #{state.app} #{file_path} on #{state.node}")

      # Recompile the project. This seems like a big hammer, but mix tracks recompiling efficiently
      Mix.Task.rerun("compile")

      # this doesn't really even need to be called since the beam reloader will do it
      # anyway. Not exactly sure which is better
      NervesReactor.reload_app(state.node, state.app, state.version)
      {:noreply, state}
    end

    def handle_info(_, state), do: {:noreply, state}
  end

  def run(args) do
    {opts, _} = OptionParser.parse!(args, strict: @strict)
    unless opts[:node], do: Mix.raise("No node provided")
    node = String.to_atom(opts[:node])
    unless Node.connect(node), do: Mix.raise("Could not connect to #{node}")

    unless NervesReactor.install(node) == :ok,
      do: Mix.raise("Could not install Reactor on remote node")

    unless NervesReactor.bootstrap(node) == :ok,
      do: Mix.raise("Coudl not bootstrap Reactor on remote node")

    Mix.Project.get!()
    mix_config = Mix.Project.config()
    {:ok, pid} = Server.start_link(node, mix_config)
    # Monitor prevents the process from being garbage collected.
    Process.monitor(pid)
  end
end
