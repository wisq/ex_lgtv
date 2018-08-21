defmodule ExLgtv.Client do
  use GenServer
  alias ExLgtv.Socket

  defmodule State do
    @enforce_keys [:socket, :socket_state, :client_key, :subscribers]
    defstruct(
      socket: nil,
      socket_state: nil,
      pointer_socket: nil,
      pointer_ready: false,
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

  def call_command(pid, uri, payload) do
    GenServer.call(pid, {:command, uri, payload})
  end

  def call_pointer(pid, payload) do
    GenServer.call(pid, {:pointer, payload})
  end

  def subscribe(pid, token, uri, payload) do
    GenServer.call(pid, {:subscribe, token, self(), uri, payload})
  end

  @impl true
  def init({uri, client_key, subscribers}) do
    {:ok, socket} = Socket.Main.start_link(uri, self())

    {:ok,
     %State{
       socket: socket,
       socket_state: :connecting,
       client_key: client_key,
       subscribers: subscribers
     }}
  end

  @impl true
  def handle_call({:command, uri, payload}, from, state) do
    case send_main(:request, state, uri, payload, {:reply, from}) do
      {:ok, new_state} -> {:noreply, new_state}
      {:error, error} -> {:reply, {:error, error}, state}
    end
  end

  @impl true
  def handle_call({:subscribe, token, pid, uri, payload}, from, state) do
    case send_main(:subscribe, state, uri, payload, {:subscription, token, pid, from}) do
      {:ok, new_state} -> {:noreply, new_state}
      {:error, error} -> {:reply, {:error, error}, state}
    end
  end

  @impl true
  def handle_call({:pointer, payload}, _from, state) do
    {:reply, send_pointer(state, payload), state}
  end

  @impl true
  def handle_info({:socket_connect, pid}, state) do
    ^pid = state.socket
    Socket.Main.register(state.socket, "reg0", handshake_payload(state.client_key))
    {:noreply, %State{state | socket_state: :registering}}
  end

  @impl true
  def handle_info({:socket_disconnect, pid}, state) do
    ^pid = state.socket
    {:noreply, %State{state | socket_state: :offline}}
  end

  @impl true
  def handle_info({:pointer_connect, pid}, state) do
    if pid == state.pointer_socket do
      IO.puts("pointer ready")
      {:noreply, %State{state | pointer_ready: true}}
    else
      {:noreply, state}
    end
  end

  @impl true
  def handle_info({:pointer_disconnect, pid}, state) do
    if pid == state.pointer_socket do
      IO.puts("pointer lost")
      {:noreply, %State{state | pointer_ready: false}}
    else
      {:noreply, state}
    end
  end

  @impl true
  def handle_info({:socket_receive, pid, type, id, payload}, state) do
    ^pid = state.socket
    handle_receive(type, id, payload, state)
  end

  # Send a request to the main socket.
  # This generates and registers a new command ID, then sends it.
  defp send_main(mode, %State{socket_state: :ready} = state, uri, payload, reply_to) do
    {command_id, state} = register_next_command_id(state, reply_to)

    case mode do
      :request -> Socket.Main.request(state.socket, command_id, uri, payload)
      :subscribe -> Socket.Main.subscribe(state.socket, command_id, uri, payload)
    end

    {:ok, state}
  end

  # If the socket isn't ready, return an error immediately,
  # without registering anything.
  defp send_main(_mode, %State{socket_state: ss}, _uri, _payload, _reply_to) do
    {:error, "Socket state is #{inspect(ss)}"}
  end

  # Send a pointer event, on the separate pointer socket.
  defp send_pointer(state, payload) do
    if state.pointer_ready do
      Socket.Pointer.cast(state.pointer_socket, payload)
      {:ok, nil}
    else
      {:error, :pointer_not_ready}
    end
  end

  # Pick the next command ID, then increment it.
  # Stick the reply_to into state.pending.
  defp register_next_command_id(state, reply_to) do
    id = state.command_id
    pending = Map.put(state.pending, id, reply_to)
    state = %State{state | command_id: id + 1, pending: pending}
    {id, state}
  end

  # Dispatch an internal command, with a callback to process the result.
  defp internal_command(state, uri, payload, callback) do
    send_main(:request, state, uri, payload, {:internal, callback})
  end

  # Bang version, to make for easier pipelining.
  defp internal_command!(state, uri, payload \\ %{}, callback) do
    {:ok, state} = internal_command(state, uri, payload, callback)
    state
  end

  # Handle various types of messages received over the socket.
  #
  # The initial registration event, once pairing is complete:
  defp handle_receive("registered", _id, %{"client-key" => client_key}, state) do
    IO.inspect({"connected", state.client_key, client_key})

    state =
      %State{state | socket_state: :ready, client_key: client_key}
      |> internal_command!(
        "ssap://com.webos.service.networkinput/getPointerInputSocket",
        &handle_pointer_socket/2
      )

    {:noreply, state}
  end

  # A response to our "reg0" event, indicating that confirmation is required:
  defp handle_receive("response", "reg0", %{"pairingType" => "PROMPT"}, state) do
    IO.inspect({"prompting"})
    {:noreply, %State{state | socket_state: :prompting}}
  end

  # A positive response to a standard command:
  defp handle_receive("response", command_id, payload, state) do
    dispatch_response(command_id, {:ok, payload}, state)
  end

  # An error with a standard command:
  defp handle_receive("error", command_id, payload, state) do
    dispatch_response(command_id, {:error, payload}, state)
  end

  # Determine who a response should be sent to,
  # then send it to them.
  #
  # There are currently four different types:
  #
  # {:internal, callback} ->
  #   A response to a special command internal to this module.
  #   `callback` is a function that accepts the response.
  #
  # {:reply, from} ->
  #   A standard `call`-style command.
  #   We use `GenServer.reply` to reply to `from`.
  #
  # {:subscription, token, pid} ->
  #   An ongoing subscription.  Send `{token, payload}` to `pid`.
  #
  # {:subscription, token, pid, from} ->
  #   A new subscription.  In addition to the above behaviour,
  #   also use `GenServer.reply`, then remove `from`.
  #
  # TODO: Refactor into a list?  So the last case becomes a
  # combination of `{:subscription, token, pid}` and `{:reply, from}`.
  defp dispatch_response(command_id, response, state) do
    {reply_to, pending} = Map.pop(state.pending, command_id)
    IO.inspect({"response", command_id, reply_to})

    case reply_to do
      {:internal, callback} ->
        # Internal command: Run the callback, leave state.pending unchanged.
        callback.(response, state)

      {:reply, from} ->
        # External command: Reply, and drop from state.pending.
        GenServer.reply(from, response)
        {:noreply, %State{state | pending: pending}}

      {:subscription, token, pid} ->
        # Ongoing subscription: Send to target, leave state.pending unchanged.
        if {:ok, payload} = response do
          send(pid, {token, payload})
        end

        {:noreply, state}

      {:subscription, token, pid, from} ->
        # New subscription: Send to target ...
        if {:ok, payload} = response do
          send(pid, {token, payload})
        end

        # ... reply once to satisfy the call ...
        GenServer.reply(from, response)
        # ... then switch to an "ongoing" subscription, above.
        pending = Map.put(pending, command_id, {:subscription, token, pid})
        {:noreply, %State{state | pending: pending}}
    end
  end

  # Internal callback for a `getPointerInputSocket` call.
  # This sets up the pointer socket once we have a URI for it.
  # Issued once registration is complete.
  defp handle_pointer_socket({:ok, %{"socketPath" => uri}}, state) do
    if state.pointer_socket do
      Socket.Pointer.close(state.pointer_socket)
    end

    {:ok, pid} = Socket.Pointer.start_link(uri, self())
    IO.inspect({"socketPath", uri, pid})
    {:noreply, %State{state | pointer_socket: pid, pointer_ready: false}}
  end

  # Generate the initial handshake payload.
  # This version is without an initial client key:
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

  # This version adds an existing client key to the handshake:
  defp handshake_payload(client_key) when is_bitstring(client_key) do
    handshake_payload(nil)
    |> Map.put(:"client-key", client_key)
  end
end
