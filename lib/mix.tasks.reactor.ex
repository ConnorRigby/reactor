defmodule Mix.Tasks.Reactor do
  use Mix.Task

  @strict [
    node: :string
  ]

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

    ebin_dirs = Mix.Project.build_path() |> Path.join("lib/*/ebin/") |> Path.wildcard()
    src_dirs = Keyword.fetch!(mix_config, :elixirc_paths) |> Enum.map(&Path.expand/1)
    # ++ Keyword.fetch!(mix_config, :erlc_paths)
    {:ok, ebin} = FileSystem.start_link(dirs: ebin_dirs)
    {:ok, src} = FileSystem.start_link(dirs: src_dirs)
    FileSystem.subscribe(ebin)
    FileSystem.subscribe(src)
    reactor(node, ebin, src)
  end

  def reactor(node, ebin, src) do
    receive do
      {:file_event, ^ebin, {file_path, [:modified, :closed]}} ->
        Mix.shell().info("Reloading #{file_path} on #{node}")
        module = Path.rootname(file_path) |> Path.basename() |> String.to_atom()
        NervesReactor.reload_module(node, module)
        reactor(node, ebin, src)

      {:file_event, ^src, {file_path, [:modified, :closed]}} ->
        Mix.shell().info("Recompiling #{file_path} on #{node}")
        # TODO This is probably worth exposing as a function
        for {module, bin} <- Code.compile_file(file_path) do
          :rpc.call(node, :code, :load_binary, [module, to_charlist(file_path), bin])
          |> IO.inspect()
        end

        reactor(node, ebin, src)
    end
  end
end
