defmodule ExLgtv.Client do
  use GenServer
  alias ExLgtv.Socket

  defmodule State do
    @enforce_keys [:socket, :socket_state, :client_key, :subscribers]
    defstruct(
      socket: nil,
      socket_state: nil,
      client_key: nil,
      command_id: 1,
      subscribers: MapSet.new(),
      pending: %{}
    )
  end

  def start_link(ip, opts) do
    URI.default_port("ws", 3000)
    uri = URI.parse("ws://#{ip}")

    client_key = Keyword.get(opts, :client_key)
    subscribers = Keyword.get(opts, :subscribers, []) |> MapSet.new()

    GenServer.start_link(__MODULE__, {uri, client_key, subscribers})
  end

  def command(pid, uri, payload) do
    GenServer.call(pid, {:command, uri, payload})
  end

  @impl true
  def init({uri, client_key, subscribers}) do
    {:ok, socket} = Socket.start_link(uri, self())

    {:ok,
     %State{
       socket: socket,
       socket_state: :connecting,
       client_key: client_key,
       subscribers: subscribers
     }}
  end

  @impl true
  def handle_info({:socket_connect, pid}, state) do
    ^pid = state.socket
    Socket.cast_register(state.socket, "reg0", handshake_payload(state.client_key))
    {:noreply, %State{state | socket_state: :registering}}
  end

  @impl true
  def handle_info({:socket_receive, pid, type, id, payload}, state) do
    ^pid = state.socket
    handle_receive(type, id, payload, state)
  end

  @impl true
  def handle_call({:command, uri, payload}, from, state) do
    case state.socket_state do
      :ready ->
        {command_id, state} = register_next_command_id(state, from)
        Socket.cast_request(state.socket, command_id, uri, payload)
        {:noreply, state}

      other ->
        {:reply, {:error, other}, state}
    end
  end

  defp register_next_command_id(state, from) do
    id = state.command_id
    pending = Map.put(state.pending, id, from)
    state = %State{state | command_id: id + 1, pending: pending}
    {id, state}
  end

  defp handle_receive("registered", _id, %{"client-key" => client_key}, state) do
    IO.inspect({"connected", state.client_key, client_key})
    {:noreply, %State{state | socket_state: :ready, client_key: client_key}}
  end

  defp handle_receive("response", "reg0", %{"pairingType" => "PROMPT"}, state) do
    IO.inspect({"prompting"})
    {:noreply, %State{state | socket_state: :prompting}}
  end

  defp handle_receive("response", command_id, payload, state) do
    {from, pending} = Map.pop(state.pending, command_id)
    IO.inspect({"response", command_id})
    GenServer.reply(from, {:ok, payload})
    {:noreply, %State{state | pending: pending}}
  end

  defp handshake_payload(nil) do
    %{
      forcePairing: false,
      pairingType: "PROMPT",
      manifest: %{
        manifestVersion: 1,
        permissions: ~w(
          APP_TO_APP
          CLOSE
          CONTROL_AUDIO
          CONTROL_DISPLAY
          CONTROL_INPUT_JOYSTICK
          CONTROL_INPUT_MEDIA_PLAYBACK
          CONTROL_INPUT_MEDIA_RECORDING
          CONTROL_INPUT_TEXT
          CONTROL_INPUT_TV
          CONTROL_MOUSE_AND_KEYBOARD
          CONTROL_POWER
          LAUNCH
          LAUNCH_WEBAPP
          READ_APP_STATUS
          READ_COUNTRY_INFO
          READ_CURRENT_CHANNEL
          READ_INPUT_DEVICE_LIST
          READ_INSTALLED_APPS
          READ_LGE_SDX
          READ_LGE_TV_INPUT_EVENTS
          READ_NETWORK_STATE
          READ_NOTIFICATIONS
          READ_POWER_STATE
          READ_RUNNING_APPS
          READ_TV_CHANNEL_LIST
          READ_TV_CURRENT_TIME
          READ_UPDATE_INFO
          SEARCH
          TEST_OPEN
          TEST_PROTECTED
          TEST_SECURE
          UPDATE_FROM_REMOTE_APP
          WRITE_NOTIFICATION_ALERT
          WRITE_NOTIFICATION_TOAST
          WRITE_SETTINGS
        )
      }
    }
  end

  defp handshake_payload(client_key) when is_bitstring(client_key) do
    handshake_payload(nil)
    |> Map.put(:"client-key", client_key)
  end
end
