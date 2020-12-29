# Copyright 2020 elixir-lsp team

# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at

#   http://www.apache.org/licenses/LICENSE-2.0

# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.
defmodule Vendored.ElixirLS.LanguageServer.Build do
  def build(_parent, root_path, opts) do
    if Path.absname(File.cwd!()) != Path.absname(root_path) do
      IO.puts("Skipping build because cwd changed from #{root_path} to #{File.cwd!()}")
      {nil, nil}
    else
      with_build_lock(fn ->
        {_us, _} =
          :timer.tc(fn ->
            IO.puts("MIX_ENV: #{Mix.env()}")
            IO.puts("MIX_TARGET: #{Mix.target()}")

            case reload_project() do
              {:ok, mixfile_diagnostics} ->
                # FIXME: Private API
                # if Keyword.get(opts, :fetch_deps?) and
                #      Mix.Dep.load_on_environment([]) != cached_deps() do
                #   # NOTE: Clear deps cache when deps in mix.exs has change to prevent
                #   # formatter crash from clearing deps during build.
                #   :ok = Mix.Project.clear_deps_cache()
                #   fetch_deps()
                # end

                {status, diagnostics} = compile()

                if status in [:ok, :noop] and Keyword.get(opts, :load_all_modules?) do
                  load_all_modules()
                end

                {status, mixfile_diagnostics, diagnostics}

              {:error, mixfile_diagnostics} ->
                {:error, mixfile_diagnostics}
            end
          end)
      end)
    end
  end

  def mixfile_diagnostic({file, line, message}, severity) do
    %Mix.Task.Compiler.Diagnostic{
      compiler_name: "ElixirLS",
      file: file,
      position: line,
      message: message,
      severity: severity
    }
  end

  def exception_to_diagnostic(error) do
    msg =
      case error do
        {:shutdown, 1} ->
          "Build failed for unknown reason. See output log."

        _ ->
          Exception.format_exit(error)
      end

    %Mix.Task.Compiler.Diagnostic{
      compiler_name: "ElixirLS",
      file: Path.absname(System.get_env("MIX_EXS") || "mix.exs"),
      position: nil,
      message: msg,
      severity: :error,
      details: error
    }
  end

  def with_build_lock(func) do
    :global.trans({__MODULE__, self()}, func)
  end

  defp reload_project do
    mixfile = Path.absname(System.get_env("MIX_EXS") || "mix.exs")

    if File.exists?(mixfile) do
      # FIXME: Private API
      case Mix.ProjectStack.peek() do
        %{file: ^mixfile, name: module} ->
          # FIXME: Private API
          Mix.Project.pop()
          :code.purge(module)
          :code.delete(module)

        _ ->
          :ok
      end

      Mix.Task.clear()

      # Override build directory to avoid interfering with other dev tools
      # FIXME: Private API
      Mix.ProjectStack.post_config(build_path: ".nerves_reactor/build")

      # We can get diagnostics if Mixfile fails to load
      {status, diagnostics} =
        case Kernel.ParallelCompiler.compile([mixfile]) do
          {:ok, _, warnings} ->
            {:ok, Enum.map(warnings, &mixfile_diagnostic(&1, :warning))}

          {:error, errors, warnings} ->
            {
              :error,
              Enum.map(warnings, &mixfile_diagnostic(&1, :warning)) ++
                Enum.map(errors, &mixfile_diagnostic(&1, :error))
            }
        end

      if status == :ok do
        # The project may override our logger config, so we reset it after loading their config
        logger_config = Application.get_all_env(:logger)
        Mix.Task.run("loadconfig")
        # NOTE: soft-deprecated in v1.10
        Mix.Config.persist(logger: logger_config)
      end

      {status, diagnostics}
    else
      msg =
        "No mixfile found in project. " <>
          "To use a subdirectory, set `elixirLS.projectDir` in your settings"

      {:error, [mixfile_diagnostic({Path.absname(mixfile), nil, msg}, :error)]}
    end
  end

  def load_all_modules do
    apps =
      cond do
        Mix.Project.umbrella?() ->
          Mix.Project.apps_paths() |> Map.keys()

        app = Keyword.get(Mix.Project.config(), :app) ->
          [app]

        true ->
          []
      end

    Enum.each(apps, fn app ->
      true = Code.prepend_path(Path.join(Mix.Project.build_path(), "lib/#{app}/ebin"))

      case Application.load(app) do
        :ok -> :ok
        {:error, {:already_loaded, _}} -> :ok
      end
    end)
  end

  defp compile do
    case Mix.Task.run("compile", ["--return-errors", "--ignore-module-conflict"]) do
      {status, diagnostics} when status in [:ok, :error, :noop] and is_list(diagnostics) ->
        {status, diagnostics}

      status when status in [:ok, :noop] ->
        {status, []}

      _ ->
        {:ok, []}
    end
  end
end
