defmodule ExLgtv.ClientTest do
  use ExUnit.Case, async: true

  alias ExLgtv.Client

  test "something" do
    {:ok, {main_pid, _} = main} = TestServer.websocket_init("/")
    {:ok, {pointer_pid, _} = pointer} = TestServer.websocket_init("/pointer")
    main_url = TestServer.url(main_pid, "/")
    pointer_url = TestServer.url(pointer_pid, "/pointer")
    me = self()

    expect(main, fn :register, _, %{"pairingType" => "PROMPT"} ->
      {:registered, %{"client-key" => "abcde"}}
    end)

    expect(main, fn :request, _, %{} ->
      send(me, :pointer)
      {:response, %{"socketPath" => pointer_url}}
    end)

    :ok =
      TestServer.websocket_handle(pointer,
        to: fn {:text, "type:click\n\n"}, state ->
          send(me, :clicked)
          {:ok, state}
        end
      )

    {:ok, client} = Client.start_link(uri: main_url)
    assert_receive :pointer, 500
    pointer_loop(fn -> Client.click(client) end)
    assert_receive :clicked, 500
  end

  defp expect(socket, inner_fun) do
    outer_fun = fn {:text, json}, state ->
      %{
        "id" => id,
        "type" => request_type,
        "payload" => request_payload
      } = request = Poison.decode!(json)

      {reply_type, reply_payload} =
        inner_fun.(
          String.to_existing_atom(request_type),
          Map.get(request, "uri"),
          request_payload
        )

      reply =
        %{type: reply_type, id: id, payload: reply_payload}
        |> Poison.encode!()

      {:reply, {:text, reply}, state}
    end

    :ok = TestServer.websocket_handle(socket, to: outer_fun)
  end

  defp pointer_loop(fun), do: spawn_link(fn -> pointer_loop_inside(fun) end)

  defp pointer_loop_inside(fun) do
    case fun.() do
      {:ok, nil} ->
        :ok

      {:error, :pointer_not_ready} ->
        Process.sleep(10)
        pointer_loop_inside(fun)
    end
  end
end
