defmodule ExLgtv.Socket.Pointer do
  use WebSockex

  def start_link(uri, parent) do
    WebSockex.start_link(uri, __MODULE__, parent, async: true)
  end

  def cast(pid, payload) do
    WebSockex.cast(pid, {:send, payload})
  end

  def close(pid) do
    WebSockex.cast(pid, :close)
  end

  @impl true
  def handle_connect(_conn, parent) do
    send(parent, {:pointer_connect, self()})
    {:ok, parent}
  end

  @impl true
  def handle_disconnect(_conn, parent) do
    send(parent, {:pointer_disconnect, self()})
    {:ok, parent}
  end

  @impl true
  def handle_cast({:send, payload}, parent) do
    message =
      Enum.map(payload, fn {key, value} -> "#{key}:#{value}" end)
      |> Enum.join("\n")

    {:reply, {:text, message <> "\n\n"}, parent}
  end

  @impl true
  def handle_cast(:close, parent) do
    {:close, parent}
  end
end
