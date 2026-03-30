# SPDX-FileCopyrightText: 2026 Haruno Haru
#
# SPDX-License-Identifier: Apache-2.0
#
exclude = if match?({:unix, :linux}, :os.type()), do: [], else: [:linux]
exclude = if System.find_executable("dnsmasq"), do: exclude, else: [:dnsmasq | exclude]
ExUnit.start(exclude: exclude)
