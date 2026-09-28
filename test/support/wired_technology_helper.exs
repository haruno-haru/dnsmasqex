# SPDX-FileCopyrightText: 2026 Haruno Haru
#
# SPDX-License-Identifier: Apache-2.0
#
defmodule Dnsmasqex.Test.WiredTechnology do
  @moduledoc false
  @behaviour VintageNet.Technology

  alias VintageNet.Interface.RawConfig
  alias VintageNet.IP.IPv4Config

  @impl VintageNet.Technology
  def normalize(config), do: IPv4Config.normalize(config)

  @impl VintageNet.Technology
  def to_raw_config(ifname, config, _opts) do
    %RawConfig{
      ifname: ifname,
      type: __MODULE__,
      source_config: config,
      required_ifnames: [ifname],
      up_cmds: [:wired_up]
    }
  end

  @impl VintageNet.Technology
  def ioctl(_ifname, _command, _args), do: {:error, :unsupported}

  @impl VintageNet.Technology
  def check_system(_opts), do: :ok
end
