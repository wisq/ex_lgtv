defmodule ExLgtv.ClientTest do
  use ExUnit.Case, async: true
  import ExUnit.CaptureLog

  alias ExLgtv.{Client, KeyStore}

  test "connects with the assigned client key" do
    key = random_key(32)
    me = self()

    {_, uri} =
      mock_server([
        fn :register, nil, payload ->
          send(me, {:payload, payload})
          {:registered, %{}}
        end
      ])

    {:ok, _} = Client.start_link(uri: uri, client_key: key)
    assert_receive {:payload, payload}, 500
    assert %{"client-key" => ^key} = payload
  end

  test "retrieves a key from KeyStore if not provided" do
    key = random_key(32)
    me = self()

    {_, uri} =
      mock_server([
        fn :register, nil, payload ->
          send(me, {:payload, payload})
          {:registered, %{}}
        end
      ])

    KeyStore.put(uri, key)

    {:ok, _} = Client.start_link(uri: uri)
    assert_receive {:payload, payload}, 500
    assert %{"client-key" => ^key} = payload
  end

  test "waits for user confirmation and stores new key on first pairing" do
    key = random_key(32)
    me = self()

    {server, uri} =
      mock_server([
        fn :register, nil, %{"pairingType" => "PROMPT"}, %{"id" => id} ->
          send(me, {:waiting, id})
          {:response, %{"pairingType" => "PROMPT"}}
        end
      ])

    KeyStore.put(uri, key)

    log =
      capture_log(fn ->
        {:ok, _} = Client.start_link(uri: uri)
        assert_receive {:waiting, reg_id}, 500
        reply(server, :registered, reg_id, %{"client-key" => key})

        # Allow enough time for logging & saving to KeyStore.
        # TODO: set up a consumer and assert on a "ready" event instead
        Process.sleep(500)
      end)

    assert log =~ "Pairing required"
    assert KeyStore.get(uri) == key
  end

  defp mock_server(expects) do
    {:ok, {pid, _} = server} = TestServer.websocket_init("/")
    expects |> Enum.each(&expect(server, &1))
    uri = TestServer.url(pid, "/") |> URI.parse()
    {server, uri}
  end

  defp expect(server, inner_fun) do
    outer_fun = fn {:text, json}, state ->
      %{
        "id" => id,
        "type" => request_type,
        "payload" => request_payload
      } = request = Poison.decode!(json)

      request_type = String.to_atom(request_type)
      uri = Map.get(request, "uri")

      inner_result =
        case Function.info(inner_fun) |> Keyword.get(:arity) do
          3 -> inner_fun.(request_type, uri, request_payload)
          4 -> inner_fun.(request_type, uri, request_payload, request)
        end

      reply =
        case inner_result do
          {reply_type, reply_payload} ->
            %{type: reply_type, id: id, payload: reply_payload}

          {reply_type, reply_payload, map} ->
            %{type: reply_type, id: id, payload: reply_payload} |> Map.merge(map)

          :noreply ->
            nil
        end

      if reply do
        {:reply, {:text, Poison.encode!(reply)}, state}
      else
        {:ok, state}
      end
    end

    :ok = TestServer.websocket_handle(server, to: outer_fun)
  end

  defp reply(server, reply_type, id, reply_payload) do
    reply =
      %{type: reply_type, id: id, payload: reply_payload}
      |> Poison.encode!()

    TestServer.websocket_info(server, fn state -> {:reply, {:text, reply}, state} end)
  end

  @hex [?0..?9, ?a..?f] |> Enum.flat_map(&Enum.to_list/1)

  defp random_key(size) do
    1..size
    |> Enum.map(fn _ -> Enum.random(@hex) end)
    |> String.Chars.to_string()
  end
end
