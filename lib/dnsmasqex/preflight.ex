# SPDX-FileCopyrightText: 2026 Haruno Haru
#
# SPDX-License-Identifier: Apache-2.0
#
defmodule Dnsmasqex.Preflight do
  @moduledoc false

  @spec check(String.t(), Path.t(), [atom()], [{atom(), Path.t()}]) :: :ok | {:error, term()}
  def check(command, config_path, features, runtime_files) do
    with {:ok, capabilities} <- Dnsmasqex.capabilities(command),
         :ok <- require_features(capabilities, features),
         :ok <- check_kernel(features),
         {:ok, contents} <- read_runtime_files(runtime_files) do
      check_syntax(command, ["--test", "-C", config_path], contents, Path.dirname(config_path))
    end
  end

  @spec runtime(String.t(), atom(), String.t(), Path.t()) :: :ok | {:error, term()}
  def runtime(_command, :records, _contents, _tmpdir), do: :ok
  def runtime(_command, _option, "", _tmpdir), do: :ok

  def runtime(command, option, contents, tmpdir),
    do: check_syntax(command, ["--test", "-C", "/dev/null"], directives(option, contents), tmpdir)

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
    Enum.reduce_while(files, {:ok, ""}, fn {option, path}, {:ok, contents} ->
      case File.read(path) do
        {:ok, value} -> {:cont, {:ok, contents <> directives(option, value)}}
        {:error, reason} -> {:halt, {:error, {:read_file, path, reason}}}
      end
    end)
  end

  # --test does not read dhcp-hostsfile or dhcp-optsfile. Check their contents
  # using the equivalent directives in a separate, temporary configuration.
  defp directives(:records, _contents), do: ""

  defp directives(option, contents) do
    directive =
      if option in [:static_leases, :static_leases6], do: "dhcp-host", else: "dhcp-option"

    contents |> String.split("\n", trim: true) |> Enum.map_join(&"#{directive}=#{&1}\n")
  end

  defp check_syntax(command, args, contents, tmpdir) do
    path =
      Path.join(tmpdir, ".dnsmasq-check-#{System.pid()}-#{System.unique_integer([:positive])}")

    with :ok <- File.write(path, contents, [:exclusive]) do
      try do
        case System.cmd(command, args ++ ["--conf-file=#{path}"],
               stderr_to_stdout: true,
               env: [{"LC_ALL", "C"}]
             ) do
          {_output, 0} -> :ok
          {output, _status} -> {:error, {:invalid_configuration, String.trim(output)}}
        end
      rescue
        error in ErlangError -> {:error, {:executable, command, error.original}}
      after
        File.rm(path)
      end
    end
  end
end
