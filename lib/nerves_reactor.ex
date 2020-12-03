defmodule NervesReactor do
  @moduledoc """
  Handles remote code loading for distributed Erlang nodes

  Usage:

    {:ok, _} = Node.start(:"reactor@hostname.local")
    _ = Node.set_cookie(:super_secret)
    true = Node.connect(:"remote@remote-hostname.local")
    NervesReactor.install(:"remote@remote-hostname.local")
    NervesReactor.bootstrap(:"remote@remote-hostname.local")

  After that's done, applications can be reloaded:

    NervesReactor.reload_app(:"remote@remote-hostname.local", :some_app)

  Or individual modules:

    NervesReactor.reload_module(:"remote@remote-hostname.local", SomeMod)
  """
  require Logger
  alias NervesReactor.Bootstrap

  @doc """
  Installs the reactor bootstrap module onto a remote node.
  Required to bootstrap the reactor.
  """
  def install(node) do
    {Bootstrap, bin, beam_path} = :code.get_object_code(Bootstrap)

    case :rpc.call(node, :code, :load_binary, [Bootstrap, beam_path, bin]) do
      {:module, Bootstrap} -> :ok
      {:badrpc, error} -> {:error, error}
    end
  end

  @doc """
  Bootstraps a node to prepare it for code reloads.
  This essentially syncs the local node's application tree with the remote one
  ensuring all the local versions are the same as the remote. Can be thought of as
  a "reset" of the existing code on the remote end. After a fresh deploy, there will
  likely be no changes, but this syncronizes both systems.
  Currently only syncs application specs and code. anything in `priv` is currently
  ignored. See TODO for more information.
  """
  def bootstrap(node) do
    missing_apps = calculate_missing_apps(node)

    for {app, version} <- missing_apps do
      Logger.info("Syncing #{app}:#{version}")

      # Logger.info("Unloading #{app}")
      # :ok = :rpc.call(node, Bootstrap, :unload, [app, version])

      # Logger.info("Deletting app path: #{app}")
      # # try to unload the old version if it exits. This doesn't purge the code.
      # _ = :rpc.call(node, :Bootstrap, :remove_codepath, [app, version])

      # this will be the new codepath for this app on the remote node
      remote_path = :rpc.call(node, Bootstrap, :create_temp_dir, [app, version])

      # code and assets to be coppied
      app_dir = :code.lib_dir(app)
      ebin_path = :code.lib_dir(app, :ebin)
      priv_path = :code.lib_dir(app, :priv)

      # priv is optional
      # ISSUE: objects in priv can be compiled for the current node's architecture.
      #        This will be a **huge** problem for Nerves. Unsure how to handle as of right now
      if File.dir?(priv_path), do: copy_file_or_dir(node, "priv", app_dir, remote_path)
      # ebin isnt. this dir check isn't really necessary
      if File.dir?(ebin_path), do: copy_file_or_dir(node, "ebin", app_dir, remote_path)

      # Add the newly created codepath to the code server. See below note about this.
      true = :rpc.call(node, Bootstrap, :add_codepath, [Path.join(remote_path, "ebin")])
      _ = :rpc.call(node, Bootstrap, :load, [app, version])
      # test
      # looading the application doesn't load the code, so do that first.
      _ = reload_app(node, app)
      # once code is loaded, load the app spec
      # TODO: this could all be done in one spec without adding codepaths
      #       by just getting the app spec, passing that spec to the remote application:load/1
      #       and then loading the modules for it
      #       Code paths don't actually get honored in embedded mode after the VM boots anyway
      #       Except for loading the .app file.
      Logger.info("Synced #{app}:#{version}")
    end

    for {app, _} <- missing_apps do
      _ = :rpc.call(node, :application, :ensure_all_started, [app])
    end

    :ok
  end

  # TODO: The remote `File` calls here have a few problems:
  #       1) they should use the erlang versions
  #       2) exceptions get swollowed
  #       3) there was one more thing, but i don't remember it.
  defp copy_file_or_dir(node, name, local_path, remote_path) do
    local_object = Path.join(local_path, name)
    remote_object = Path.join(remote_path, name)

    if File.dir?(local_object) do
      Logger.info("Creating #{remote_object}")
      _ = :rpc.call(node, File, :mkdir, [remote_object])
      local_filenames = File.ls!(local_object)

      for local_filename <- local_filenames do
        copy_file_or_dir(node, local_filename, local_object, remote_object)
      end
    else
      Logger.info("Coppying #{local_object} to #{remote_object}")
      :rpc.call(node, File, :write!, [remote_object, File.read!(local_object)])
    end
  end

  @doc """
  Reload all modules for an application on the remote node.
  Does a simple version compare, checking if module versions are different.
  No comparision is done, if the remote version doesn't exist or is different than the local
  node's copy, the module will be reloaded.
  This does **not** load/unload the application spec.
  """
  def reload_app(node, app) do
    # TODO: There is a potential garbage collection issue here where this only loads the
    #       local modules. If a module was deleted, it won't get cleaned up.
    #       Not a huge deal, but something like:
    #         {:ok, modules} = :rpc.call(node, :application, :get_key, [app, :modules])
    #       And then diffing the modules should fix it. I think there's a function in `:code` to purge
    #       unaccounted modules.

    {:ok, modules} = :application.get_key(app, :modules)

    for module <- modules do
      # Checks local and remote version; assumes local version is the "correct" one.
      us_version = get_local_module_version(module)
      them_version = get_remote_module_version(node, module)

      if us_version != them_version do
        reload_module(node, module)
      else
        {:module, module}
      end
    end
  end

  @doc """
  Reload a single module. Keep in mind this won't load anything other than a single module.
  This means if the module you are reloading requires changes in a different module, you will need
  to reload that module as well. If in doubt, it's probably better to use `reload_application/2`
  """
  def reload_module(node, module) do
    # use `load_binary` becuase a remote device using: `embedded` mode for the code
    # server fail on using this function:
    #        {:module, ^module} = :rpc.call(node, :code, :load_file, [module])
    {^module, bin, beam_path} = :code.get_object_code(module)
    {:module, ^module} = :rpc.call(node, :code, :load_binary, [module, beam_path, bin])
  end

  @doc false
  def get_local_module_version(module) do
    module.module_info[:attributes][:vsn]
    |> _get_module_version()
  end

  @doc false
  def get_remote_module_version(node, module) do
    case :rpc.call(node, module, :module_info, [:attributes]) do
      result when is_list(result) -> _get_module_version(result)
      # check for this modules not being defined. This happens if a `reload` happens
      # on a module that hasn't been loaded in the first place.
      # Example: adding a new dependency to an application
      # Example: adding a new module to an application
      {:badrpc, {:EXIT, {:undef, [{^module, :module_info, [:attributes], []}]}}} -> nil
    end
  end

  defp _get_module_version([vsn]), do: vsn
  defp _get_module_version(_), do: nil

  @doc """
  Returns a list of applications and versions that have diverged between the local
  and remote node. No side effects, only calculations. Certain "important" applications are
  ignored including `kernel`, `stdlib` etc as those are assumed to be tied to the current
  remote node runtime.

  Requires remote node to be bootstrapped. See `bootstrap/1` for info.
  """
  def calculate_missing_apps(node) when is_atom(node) do
    us = Bootstrap.loaded_applications()
    them = :rpc.call(node, Bootstrap, :loaded_applications, [])
    _calculate_missing_apps(us, them)
  end

  defp _calculate_missing_apps(us, them) do
    Enum.reject(us, fn {app, us_version} ->
      case them[app] do
        ^us_version -> true
        nil -> false
        _them_version -> false
      end
    end)
    |> reject_special_cases()
  end

  # All apps are created equal (except these ones)
  defp reject_special_cases(apps) do
    apps
    |> Enum.reject(fn {app, _version} ->
      # apps that live in sticky directories can't be reloaded without
      # unsticking them. There's no way to tell if an `app` is sticky, so just
      # check all the modules. only one is probably required in all reality.
      {:ok, modules} = :application.get_key(app, :modules)
      Enum.any?(modules, &:code.is_sticky(&1))
    end)
    # This is a special list of apps that we don't want/need to be reloaded.
    # there's probably discussion to be had here.
    |> Enum.reject(fn
      {:nerves_reactor, _} -> true
      {:elixir, _} -> true
      {:hex, _} -> true
      {:iex, _} -> true
      {:logger, _} -> true
      _ -> false
    end)
  end
end
