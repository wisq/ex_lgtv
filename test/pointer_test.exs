defmodule ExLgtv.PointerTest do
  use ExUnit.Case, async: true

  alias ExLgtv.Pointer
  alias ExLgtv.Test.MockGenStage

  describe "init" do
    setup [:test_server, :mock_client]

    test "connects to socket returned by getPointerInputSocket command", %{client: client} do
      {:ok, pointer} = Pointer.start_link(client: client)
      Pointer.wait_for_ready(pointer)
    end
  end

  describe "init with long connect delay" do
    setup do
      [socket_startup_delay: 500]
    end

    setup [:test_server, :mock_client]

    test "buffers commands and sends when connected", %{client: client, server: server} do
      expect(server, "type:move\ndx:-5\ndy:5\ndrag:0\n\n", :move1)
      expect(server, "type:move\ndx:5\ndy:-5\ndrag:1\n\n", :move2)
      expect(server, "type:click\n\n", :done)

      {:ok, pointer} = Pointer.start_link(client: client)
      Pointer.move(pointer, -5, 5)
      Pointer.move(pointer, 5, -5, true)
      Pointer.click(pointer)

      Pointer.wait_for_ready(pointer)
      assert_receive :move1
      assert_receive :move2
      assert_receive :done
    end
  end

  describe "once ready" do
    setup [:test_server, :mock_client, :connect_pointer]

    test "sends move events", %{pointer: pointer, server: server} do
      expect(server, "type:move\ndx:-1\ndy:1\ndrag:0\n\n", :move1)
      Pointer.move(pointer, -1, 1)
      assert_receive :move1

      expect(server, "type:move\ndx:5\ndy:-10\ndrag:1\n\n", :move2)
      Pointer.move(pointer, 5, -10, true)
      assert_receive :move2
    end

    test "sends click events", %{pointer: pointer, server: server} do
      expect(server, "type:click\n\n", :click)
      Pointer.click(pointer)
      assert_receive :click
    end
  end

  defp test_server(ctx) do
    delay = Map.get(ctx, :socket_startup_delay, 0)
    path = "/resources/#{random_hex(40)}/netinput.pointer.sock"
    {:ok, server} = TestServer.websocket_init(path, match: fn _ -> Process.sleep(delay) end)
    uri = TestServer.url(path)
    [server: server, pointer_uri: uri]
  end

  defp mock_client(%{pointer_uri: uri}) do
    {:ok, client} = start_supervised({MockGenStage, mode: :producer})

    MockGenStage.add_response(client, fn
      {:command, "ssap://com.webos.service.networkinput/getPointerInputSocket", %{}} ->
        {:reply, {:ok, %{"socketPath" => uri}}}
    end)

    [client: client]
  end

  defp connect_pointer(%{client: client}) do
    {:ok, pointer} = Pointer.start_link(client: client)
    Pointer.wait_for_ready(pointer)
    [pointer: pointer]
  end

  defp expect(server, text, msg) do
    me = self()

    fun = fn {:text, ^text}, state ->
      if msg, do: send(me, msg)
      {:ok, state}
    end

    :ok = TestServer.websocket_handle(server, to: fun)
  end

  @hex [?0..?9, ?a..?f] |> Enum.flat_map(&Enum.to_list/1)

  defp random_hex(size) do
    1..size
    |> Enum.map(fn _ -> Enum.random(@hex) end)
    |> String.Chars.to_string()
  end
end
