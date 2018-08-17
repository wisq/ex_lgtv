defmodule ExLgtv.Socket do
  use WebSockex

  def start_link(url, parent) do
    WebSockex.start_link(url, __MODULE__, parent, async: true)
  end

  def cast(pid, data) do
    WebSockex.cast(pid, {:send, data})
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
    send(parent, {:socket_receive, self(), data})
    {:ok, parent}
  end

  @impl true
  def handle_cast({:send, data}, parent) do
    {:ok, json} = Poison.encode(data)
    {:reply, {:text, json}, parent}
  end
end
