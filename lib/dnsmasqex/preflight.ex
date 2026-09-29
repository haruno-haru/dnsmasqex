# SPDX-FileCopyrightText: 2026 Haruno Haru
#
# SPDX-License-Identifier: Apache-2.0
#
defmodule Dnsmasqex.Preflight do
  @moduledoc false

  @spec check(String.t(), Path.t(), [atom()], [{atom(), Path.t()}], pos_integer()) ::
          :ok | {:error, term()}
  def check(command, config_path, features, runtime_files, timeout \\ 5_000) do
    with {:ok, capabilities} <- Dnsmasqex.capabilities(command, timeout),
         :ok <- require_features(capabilities, features),
         :ok <- check_kernel(features),
         {:ok, contents} <- read_runtime_files(runtime_files) do
      check_syntax(
        command,
        ["--test", "-C", config_path],
        contents,
        Path.dirname(config_path),
        timeout
      )
    end
  end

  @spec runtime(String.t(), atom(), String.t(), Path.t(), pos_integer()) :: :ok | {:error, term()}
  def runtime(command, option, contents, tmpdir, timeout \\ 5_000)
  def runtime(_command, :records, _contents, _tmpdir, _timeout), do: :ok
  def runtime(_command, _option, "", _tmpdir, _timeout), do: :ok

  def runtime(command, option, contents, tmpdir, timeout),
    do:
      check_syntax(
        command,
        ["--test", "-C", "/dev/null"],
        directives(option, contents),
        tmpdir,
        timeout
      )

  defp require_features(capabilities, features) do
    case Enum.reject(features, &Map.fetch!(capabilities, &1)) do
      [] -> :ok
      missing -> {:error, {:missing_features, missing}}
    end
  end

  defp check_kernel(features) do
    if :nftset in features and not Dnsmasqex.nftables_available?(),
      do: {:error, {:missing_kernel_feature, :nf_tables}},
      else: :ok
  end

  defp read_runtime_files(files) do
    Enum.reduce_while(files, {:ok, ""}, &append_file/2)
  end

  defp append_file({option, path}, {:ok, contents}) do
    case read_file(option, path) do
      {:ok, value} when option != :directives -> {:cont, {:ok, contents <> value}}
      {:ok, _value} -> {:cont, {:ok, contents}}
      {:error, _reason} = error -> {:halt, error}
    end
  end

  defp read_file(option, path) do
    if File.dir?(path) do
      read_directory(option, path)
    else
      case File.read(path) do
        {:ok, value} -> {:ok, directives(option, value)}
        {:error, reason} -> {:error, {:read_file, path, reason}}
      end
    end
  end

  defp read_directory(option, path) do
    case File.ls(path) do
      {:ok, names} ->
        files =
          for name <- Enum.sort(names),
              config_file?(path, name),
              do: {option, Path.join(path, name)}

        read_runtime_files(files)

      {:error, reason} ->
        {:error, {:read_file, path, reason}}
    end
  end

  defp config_file?(path, name) do
    not String.starts_with?(name, ".") and not String.ends_with?(name, "~") and
      not (String.starts_with?(name, "#") and String.ends_with?(name, "#")) and
      File.regular?(Path.join(path, name))
  end

  # --test does not read dhcp-hostsfile or dhcp-optsfile. Check their contents
  # using the equivalent directives in a separate, temporary configuration.
  defp directives(:records, _contents), do: ""
  defp directives(option, contents) when option in [:directives, :upstreams], do: contents

  defp directives(option, contents) do
    directive =
      if option in [:static_leases, :static_leases6, :dhcp_hosts],
        do: "dhcp-host",
        else: "dhcp-option"

    contents
    |> String.split("\n", trim: true)
    |> Enum.reject(&(String.trim(&1) == "" or String.starts_with?(String.trim_leading(&1), "#")))
    |> Enum.map_join(&"#{directive}=#{&1}\n")
  end

  @doc false
  @spec replacement(
          String.t(),
          Path.t(),
          Path.t(),
          String.t(),
          [atom()],
          [{atom(), Path.t()}],
          pos_integer()
        ) :: :ok | {:error, term()}
  def replacement(command, config_path, native_path, contents, features, runtime_files, timeout) do
    with {:ok, capabilities} <- Dnsmasqex.capabilities(command, timeout),
         :ok <- require_features(capabilities, features),
         :ok <- check_kernel(features),
         {:ok, main} <- File.read(config_path),
         {:ok, runtime} <- read_runtime_files(runtime_files) do
      directive = "conf-file=#{native_path}\n"

      if String.contains?(main, directive) do
        configuration = String.replace(main, directive, contents) <> runtime

        check_syntax(
          command,
          ["--test", "-C", "/dev/null"],
          configuration,
          Path.dirname(config_path),
          timeout
        )
      else
        {:error, :unmanaged_configuration}
      end
    end
  end

  defp check_syntax(command, args, contents, tmpdir, timeout) do
    path =
      Path.join(tmpdir, ".dnsmasq-check-#{System.pid()}-#{System.unique_integer([:positive])}")

    with :ok <- File.write(path, contents, [:exclusive]) do
      try do
        case Dnsmasqex.Command.run(command, args ++ ["--conf-file=#{path}"], timeout) do
          {_output, 0} -> :ok
          {_output, :timeout} -> {:error, :preflight_timeout}
          {:error, reason} -> {:error, {:executable, command, reason}}
          {output, _status} -> {:error, {:invalid_configuration, String.trim(output)}}
        end
      after
        File.rm(path)
      end
    end
  end
end
