# SPDX-FileCopyrightText: 2026 Haruno Haru
#
# SPDX-License-Identifier: Apache-2.0
#
exclude = if match?({:unix, :linux}, :os.type()), do: [], else: [:linux]
exclude = if System.find_executable("dnsmasq"), do: exclude, else: [:dnsmasq | exclude]

exclude =
  if System.get_env("DNSMASQEX_NETWORK_TESTS") == "1", do: exclude, else: [:network | exclude]

Code.require_file("support/wired_technology_helper.exs", __DIR__)
Code.require_file("support/dns_stub_helper.exs", __DIR__)
ExUnit.start(exclude: exclude)
