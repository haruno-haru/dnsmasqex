# SPDX-FileCopyrightText: 2026 Haruno Haru
#
# SPDX-License-Identifier: Apache-2.0
#
ExUnit.start(exclude: if(match?({:unix, :linux}, :os.type()), do: [], else: [:linux]))
