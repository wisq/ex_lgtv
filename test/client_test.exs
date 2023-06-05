defmodule ExLgtv.ClientTest do
  use ExUnit.Case, async: true

  alias ExLgtv.Client

  test "something" do
    {:ok, server} = TestServer.websocket_init("/")

    expect(server, fn :register, _, %{"pairingType" => "PROMPT"} ->
      {:registered, %{"client-key" => "abcde"}}
    end)

    expect(server, fn :request, "ssap://system/turnOff", _ ->
      {:response, %{}}
    end)

    {:ok, client} = Client.start_link(uri: TestServer.url("/"))
    assert {:ok, %{}} = Client.command(client, "ssap://system/turnOff", %{})
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
end
