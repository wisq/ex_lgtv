defmodule ExLgtv.Socket.Pointer do
  use WebSockex

  def start_link(uri) do
    WebSockex.start_link(uri, __MODULE__, :down, async: true)
  end

  def cast(pid, payload) do
    WebSockex.cast(pid, {:send, payload})
  end

  @impl true
  def handle_connect(_conn, _state) do
    IO.puts("pointer connected")
    {:ok, :up}
  end

  @impl true
  def handle_disconnect(_conn, _state) do
    {:ok, :down}
  end

  @impl true
  def handle_cast({:send, _payload}, :down) do
    {:ok, :down}
  end

  @impl true
  def handle_cast({:send, payload}, :up) do
    IO.inspect({__MODULE__, payload})

    message =
      Enum.map(payload, fn {key, value} -> "#{key}:#{value}" end)
      |> Enum.join("\n")

    {:reply, {:text, message <> "\n\n"}, :up}
  end
end
