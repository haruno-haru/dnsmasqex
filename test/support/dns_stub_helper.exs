# SPDX-FileCopyrightText: 2026 Haruno Haru
#
# SPDX-License-Identifier: Apache-2.0
#
defmodule Dnsmasqex.Test.DNSStub do
  @moduledoc false
  use GenServer

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(options), do: GenServer.start_link(__MODULE__, options)
  @spec port(pid()) :: pos_integer()
  def port(pid), do: GenServer.call(pid, :port)

  @impl true
  def init(options) do
    {:ok, tcp} = :gen_tcp.listen(0, [:binary, active: false, ip: {127, 0, 0, 1}, packet: 2])
    {:ok, port} = :inet.port(tcp)
    {:ok, udp} = :gen_udp.open(port, [:binary, active: true, ip: {127, 0, 0, 1}])
    spawn_link(fn -> accept(tcp, options) end)
    {:ok, %{tcp: tcp, udp: udp, port: port, options: options}}
  end

  @impl true
  def handle_call(:port, _from, state), do: {:reply, state.port, state}

  @impl true
  def handle_info({:udp, socket, address, port, query}, state) do
    :ok = :gen_udp.send(socket, address, port, reply(query, :udp, state.options))
    {:noreply, state}
  end

  defp accept(listener, options) do
    case :gen_tcp.accept(listener) do
      {:ok, socket} ->
        case :gen_tcp.recv(socket, 0, 2000) do
          {:ok, query} -> :gen_tcp.send(socket, reply(query, :tcp, options))
          {:error, _} -> :ok
        end

        :gen_tcp.close(socket)
        accept(listener, options)

      {:error, :closed} ->
        :ok
    end
  end

  defp reply(query, transport, options) do
    {:ok, message} = :inet_dns.decode(query)
    header = :inet_dns.msg(message, :header)
    [question] = questions = :inet_dns.msg(message, :qdlist)
    domain = :inet_dns.dns_query(question, :domain)
    type = :inet_dns.dns_query(question, :type)
    send(Keyword.fetch!(options, :owner), {:upstream_query, transport, domain, type})
    truncated? = transport == :udp and Keyword.get(options, :truncate_udp, false)
    address = Keyword.get(options, :address, {203, 0, 113, 9})

    address = if type == :aaaa, do: {0x2001, 0xDB8, 0, 0, 0, 0, 0, 9}, else: address

    record =
      :inet_dns.make_rr(
        domain: domain,
        type: type,
        class: :in,
        ttl: Keyword.get(options, :ttl, 60),
        data: address
      )

    answers = if truncated? or type not in [:a, :aaaa], do: [], else: [record]

    header =
      :inet_dns.make_header(
        id: :inet_dns.header(header, :id),
        qr: true,
        rd: true,
        ra: true,
        tc: truncated?
      )

    response =
      :inet_dns.encode(:inet_dns.make_msg(header: header, qdlist: questions, anlist: answers))

    # Some OTP decoders lowercase names. Echo the original wire question so
    # dnsmasq's randomized-case check sees the exact question it sent.
    question_size = question_size(binary_part(query, 12, byte_size(query) - 12), 0)
    <<header::binary-size(12), _::binary-size(question_size), rest::binary>> = response
    header <> binary_part(query, 12, question_size) <> rest
  end

  defp question_size(<<0, _::binary>>, size), do: size + 5

  defp question_size(<<length, _label::binary-size(length), rest::binary>>, size),
    do: question_size(rest, size + length + 1)
end
