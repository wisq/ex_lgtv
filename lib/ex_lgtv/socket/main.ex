defmodule ExLgtv.Socket.Main do
  use WebSockex

  def start_link(uri, parent) do
    WebSockex.start_link(uri, __MODULE__, parent, async: true)
  end

  def register(pid, id, payload) do
    cast_send(pid, %{type: :register, id: id, payload: payload})
  end

  def request(pid, id, uri, payload) do
    cast_send(pid, %{type: :request, id: id, uri: uri, payload: payload})
  end

  def subscribe(pid, id, uri, payload) do
    cast_send(pid, %{type: :subscribe, id: id, uri: uri, payload: payload})
  end

  defp cast_send(pid, params) do
    WebSockex.cast(pid, {:send, params})
  end

  @impl true
  def handle_connect(_conn, parent) do
    send(parent, {:socket_connect, self()})
    {:ok, parent}
  end

  @impl true
  def handle_disconnect(_conn, parent) do
    send(parent, {:socket_disconnect, self()})
    {:ok, parent}
  end

  @impl true
  def handle_frame({:text, json}, parent) do
    {:ok, data} = Poison.decode(json)

    type = Map.fetch!(data, "type")
    id = Map.fetch!(data, "id")
    payload = Map.fetch!(data, "payload")

    send(parent, {:socket_receive, self(), type, id, payload})
    {:ok, parent}
  end

  @impl true
  def handle_cast({:send, data}, parent) do
    {:ok, json} = Poison.encode(data)
    {:reply, {:text, json}, parent}
  end
end
