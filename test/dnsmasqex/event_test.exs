# SPDX-FileCopyrightText: 2026 Haruno Haru
#
# SPDX-License-Identifier: Apache-2.0
#
defmodule Dnsmasqex.EventTest do
  use ExUnit.Case, async: true

  alias Dnsmasqex.Event

  doctest Event

  test "accepts nonnegative lease durations and ignores invalid values" do
    args = ["add", "aa:bb:cc:dd:ee:ff", "192.168.24.10"]

    for {input, expected} <- [
          {"0", 0},
          {"3600", 3600},
          {"4294967295", 4_294_967_295},
          {"-1", nil},
          {"3600s", nil},
          {"", nil}
        ] do
      assert Event.new(args, %{"DNSMASQ_TIME_REMAINING" => input}).time_remaining == expected
    end
  end
end
