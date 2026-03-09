# SPDX-FileCopyrightText: 2026 Haruno Haru
#
# SPDX-License-Identifier: Apache-2.0
#
defmodule Dnsmasqex do
  @moduledoc """
  Run dnsmasq on an interface managed by another technology

  See `Dnsmasqex.Config` for the `:dnsmasq` options.

  ```elixir
  %{
    type: Dnsmasqex,
    technology: VintageNetEthernet,
    ipv4: %{method: :static, address: "192.168.24.1", prefix_length: 24},
    dnsmasq: %{
      start: "192.168.24.10",
      end: "192.168.24.99",
      static_leases: [{"aa:bb:cc:dd:ee:ff", "192.168.24.100"}],
      records: [{"device.example.com", "192.168.24.1"}]
    }
  }
  ```
  """
  @behaviour VintageNet.Technology

  alias Dnsmasqex.Config

  @impl VintageNet.Technology
  def normalize(%{type: __MODULE__, technology: technology} = config) do
    %{config | type: technology}
    |> technology.normalize()
    |> Map.merge(%{type: __MODULE__, technology: technology})
    |> Config.normalize()
  end

  @impl VintageNet.Technology
  def to_raw_config(ifname, %{type: __MODULE__, technology: technology} = config, opts) do
    normalized_config = normalize(config)
    raw_config = technology.to_raw_config(ifname, %{normalized_config | type: technology}, opts)

    Config.add_config(
      %{raw_config | type: __MODULE__, source_config: normalized_config},
      normalized_config,
      opts
    )
  end

  @impl VintageNet.Technology
  def ioctl(ifname, command, args) do
    %{technology: technology} = VintageNet.get_configuration(ifname)
    technology.ioctl(ifname, command, args)
  end

  @impl VintageNet.Technology
  def check_system(_opts) do
    dnsmasq = Config.dnsmasq_path()

    if System.find_executable(dnsmasq) do
      :ok
    else
      {:error, "Can't find #{dnsmasq}"}
    end
  end
end
