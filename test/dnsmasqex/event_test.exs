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

  test "reports the client's request metadata" do
    env = %{
      "DNSMASQ_REQUESTED_OPTIONS" => "1,3,6,15,119",
      "DNSMASQ_USER_CLASS0" => "iPXE",
      "DNSMASQ_USER_CLASS1" => "lab",
      "DNSMASQ_USER_CLASS3" => "after a gap",
      "DNSMASQ_MUD_URL" => "https://example.com/mud",
      "DNSMASQ_CPEWAN_OUI" => "001122",
      "DNSMASQ_CPEWAN_SERIAL" => "ABC123"
    }

    assert %Event{
             requested_options: [1, 3, 6, 15, 119],
             user_classes: ["iPXE", "lab"],
             mud_url: "https://example.com/mud",
             cpewan: %{oui: "001122", serial: "ABC123", class: nil}
           } = Event.new(["add", "aa:bb:cc:dd:ee:ff", "192.168.24.10"], env)
  end

  test "leaves request metadata nil when dnsmasq doesn't report it" do
    assert %Event{requested_options: nil, user_classes: nil, mud_url: nil, cpewan: nil} =
             Event.new(["old", "aa:bb:cc:dd:ee:ff", "192.168.24.10"], %{
               "DNSMASQ_DATA_MISSING" => "1"
             })
  end

  test "ignores malformed requested options" do
    for options <- ["1,,3", "1,256", "one", "1;3"] do
      event =
        Event.new(["add", "aa:bb:cc:dd:ee:ff", "192.168.24.10"], %{
          "DNSMASQ_REQUESTED_OPTIONS" => options
        })

      assert event.requested_options == nil
    end
  end
end
