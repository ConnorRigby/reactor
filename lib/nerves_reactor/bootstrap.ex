defmodule NervesReactor.Bootstrap do
  @moduledoc """
  Initial module loaded by the reactor onto a remote node.

  Special care should be taken here to only use stdlib modules.
  I've used `Elixir.File` below, but only because I am lazy.
  It should be replaced with `:file`.
  """

  def loaded_applications do
    for {app, _, version} <- :application.loaded_applications(), do: {app, version}
  end

  def load(app, _version) do
    :application.load(app)
  end

  def unload(app, _version) do
    # _ = :application.stop(app)
    case :application.unload(app) do
      :ok -> :ok
      {:error, {:not_loaded, ^app}} -> :ok
      error -> error
    end
  end

  def remove_codepath(app, _version) do
    :code.del_path(app)
  end

  def add_codepath(path) do
    :code.add_patha(to_charlist(path))
  end

  def create_temp_dir(app, version) do
    File.mkdir_p("/tmp/reactor/#{app}-#{version}")
    "/tmp/reactor/#{app}-#{version}"
  end
end
