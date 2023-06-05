defmodule ExLgtv.Pointer do
  use GenStage
  require Logger

  alias ExLgtv.{Socket, Client}

  @default_port 3000

  defmodule State do
    @enforce_keys [:client]
    defstruct(
      client: nil,
      socket: nil,
      ready: false,
      pending: :queue.new()
    )
  end

  def start_link(opts) do
    {client, opts} = Keyword.pop(opts, :client)
    GenStage.start_link(__MODULE__, client, opts)
  end

  def wait_for_ready(pid) do
    GenStage.call(pid, :wait_for_ready)
  end

  def button(pid, button) do
    GenStage.cast(pid, {:pointer, type: :button, name: button})
  end

  def click(pid) do
    GenStage.cast(pid, {:pointer, type: :click})
  end

  def move(pid, dx, dy, drag \\ false) do
    drag_n = if drag, do: 1, else: 0
    GenStage.cast(pid, {:pointer, type: :move, dx: dx, dy: dy, drag: drag_n})
  end

  @impl true
  def init(client) do
    GenStage.async_subscribe(self(), to: client)

    {:ok, %{"socketPath" => uri}} =
      Client.command(client, "ssap://com.webos.service.networkinput/getPointerInputSocket", %{})

    uri = Client.parse_uri(uri)
    {:ok, socket} = Socket.Pointer.start_link(uri, self())

    {:consumer, %State{client: client, socket: socket}}
  end

  @impl true
  def handle_call(:wait_for_ready, from, state) do
    {:noreply, [], exec_or_queue(state, {:wait_for_ready, from})}
  end

  @impl true
  def handle_cast({:pointer, _} = msg, state) do
    {:noreply, [], exec_or_queue(state, msg)}
  end

  @impl true
  def handle_info({:pointer_connect, socket}, %State{socket: socket} = state) do
    state.pending
    |> :queue.to_list()
    |> Enum.each(&execute(&1, state))

    {:noreply, [], %State{state | ready: true, pending: :queue.new()}}
  end

  defp exec_or_queue(%State{ready: true} = state, msg) do
    execute(msg, state)
    state
  end

  defp exec_or_queue(%State{ready: false, pending: pending} = state, msg) do
    %State{state | pending: :queue.in(msg, pending)}
  end

  defp execute({:wait_for_ready, from}, _state), do: GenStage.reply(from, :ok)
  defp execute({:pointer, payload}, state), do: Socket.Pointer.cast(state.socket, payload)
end
