defmodule ExLgtv.Client do
  use GenStage
  require Logger
  alias ExLgtv.{Socket, KeyStore}

  @default_port 3000

  defmodule State do
    @enforce_keys [:uri, :client_key, :socket]
    defstruct(
      uri: nil,
      client_key: nil,
      socket: nil,
      ready: false,
      command_id: 1,
      pending_commands: :queue.new(),
      pending_replies: %{}
    )
  end

  def start_link(opts) do
    {host, opts} = Keyword.pop(opts, :host)
    {port, opts} = Keyword.pop(opts, :port, @default_port)
    {uri, opts} = Keyword.pop(opts, :uri, %URI{scheme: "ws", host: host, port: port})
    {key, opts} = Keyword.pop(opts, :client_key)

    GenStage.start_link(__MODULE__, {parse_uri(uri), key}, opts)
  end

  def command(pid, uri, payload) do
    GenStage.call(pid, {:command, uri, payload})
  end

  def subscribe(pid, token, uri, payload) do
    GenStage.call(pid, {:subscribe, token, uri, payload})
  end

  @impl true
  def init({%URI{} = uri, client_key}) do
    Logger.info("Connecting to LGTV at #{uri} ...")
    {:ok, socket} = Socket.Main.start_link(uri, self())

    {:producer,
     %State{
       uri: uri,
       socket: socket,
       client_key: client_key || KeyStore.get(uri)
     }}
  end

  @impl true
  def handle_call({:command, uri, payload}, from, state) do
    {:noreply, [], send_command(:request, state, uri, payload, {:reply, from})}
  end

  @impl true
  def handle_call({:subscribe, token, uri, payload}, from, state) do
    {:noreply, [], send_command(:subscribe, state, uri, payload, {:subscription, token, from})}
  end

  @impl true
  def handle_info({:socket_connect, pid}, %State{socket: pid} = state) do
    Socket.Main.register(state.socket, "reg0", handshake_payload(state.client_key))
    {:noreply, [], state}
  end

  @impl true
  def handle_info({:socket_disconnect, pid}, %State{socket: pid} = state) do
    {:noreply, [], %State{state | ready: false}}
  end

  @impl true
  def handle_info({:socket_receive, pid, type, id, payload}, %State{socket: pid} = state) do
    handle_receive(type, id, payload, state)
  end

  @impl true
  def handle_info(:send_pending_commands, state) do
    state =
      state.pending_commands
      |> :queue.to_list()
      |> Enum.reduce(%State{state | pending_commands: :queue.new()}, fn
        {mode, uri, payload, reply_to}, st ->
          send_command(mode, st, uri, payload, reply_to)
      end)

    {:noreply, [], state}
  end

  @impl true
  def handle_demand(_demand, state) do
    {:noreply, [], state}
  end

  # Send a request to the main socket.
  # This generates and registers a new command ID, then sends it.
  defp send_command(mode, %State{ready: true} = state, uri, payload, reply_to) do
    {command_id, state} = next_command_id(state)

    case mode do
      :request -> Socket.Main.request(state.socket, command_id, uri, payload)
      :subscribe -> Socket.Main.subscribe(state.socket, command_id, uri, payload)
    end

    register_reply(state, command_id, reply_to)
  end

  # Buffers a command to send once connected.
  defp send_command(mode, %State{ready: false} = state, uri, payload, reply_to) do
    cmd = {mode, uri, payload, reply_to}
    %State{state | pending_commands: :queue.in(cmd, state.pending_commands)}
  end

  # Pick the next command ID, then increment it.
  defp next_command_id(state) do
    id = state.command_id
    state = %State{state | command_id: id + 1}
    {id, state}
  end

  # Stick the reply_to into state.pending_replies.
  defp register_reply(state, command_id, reply_to) do
    %State{state | pending_replies: Map.put(state.pending_replies, command_id, reply_to)}
  end

  # Dispatch an internal command, with a callback to process the result.
  defp internal_command(state, uri, payload, callback) do
    send_command(:request, state, uri, payload, {:internal, callback})
  end

  # Handle various types of messages received over the socket.
  #
  # The initial registration event, once pairing is complete:
  defp handle_receive("registered", _id, %{"client-key" => client_key}, state) do
    if client_key == state.client_key do
      Logger.info("Connected to LGTV.")
    else
      KeyStore.put(state.uri, client_key)
      Logger.info("Successfully paired with LGTV.")
    end

    send(self(), :send_pending_commands)
    {:noreply, [], %State{state | ready: true, client_key: client_key}}
  end

  # A response to our "reg0" event, indicating that confirmation is required:
  defp handle_receive("response", "reg0", %{"pairingType" => "PROMPT"}, state) do
    Logger.warn("Pairing required.  Please accept the pairing request on your LGTV.")
    {:noreply, [], state}
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
  #   It should return a `{:noreply, [event], state}` return value directly.
  #
  # {:reply, from} ->
  #   A standard `call`-style command.
  #   We use `GenStage.reply` to reply to `from`.
  #
  # {:subscription, token, from} ->
  #   An ongoing subscription.  Send `{token, payload}` as an event.
  #   If `from` is not nil, do a `GenStage.reply` to forward the initial response,
  #   then set `from` to nil in the corresponding `pending_replies` entry.
  #
  defp dispatch_response(command_id, response, state) do
    {reply_to, pending} = Map.pop!(state.pending_replies, command_id)
    debug({:response, command_id, reply_to})

    case reply_to do
      {:internal, callback} ->
        # Internal command: Run the callback, leave state.pending unchanged.
        callback.(response, state)

      {:reply, from} ->
        # External command: Reply, and drop from state.pending.
        GenStage.reply(from, response)
        {:noreply, [], %State{state | pending_replies: pending}}

      {:subscription, token, from} ->
        # Subscription: Forward as an event, and possibly reply as well.
        handle_subscription(command_id, from, token, response, state)
    end
  end

  defp handle_subscription(_, nil, token, {:ok, payload}, state) do
    {:noreply, [{token, payload}], state}
  end

  defp handle_subscription(_, nil, _token, {:error, _}, state) do
    {:noreply, [], state}
  end

  defp handle_subscription(command_id, from, token, response, state) do
    GenStage.reply(from, response)
    pending = Map.put(state.pending_replies, command_id, {:subscription, token, nil})
    state = %State{state | pending_replies: pending}
    handle_subscription(command_id, nil, token, response, state)
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
  defp handshake_payload(client_key) when is_binary(client_key) do
    handshake_payload(nil)
    |> Map.put(:"client-key", client_key)
  end

  defp debug(data) do
    inspect(data) |> Logger.debug()
  end

  def parse_uri(uri) do
    uri
    |> URI.parse()
    |> fix_ws_port()
  end

  defp fix_ws_port(%URI{scheme: "ws"} = uri) do
    if uri.port == URI.default_port("ws") do
      # This avoids having to globally set `URI.default_port("ws", @default_port)`.
      %URI{uri | port: @default_port}
    else
      uri
    end
  end

  defp fix_ws_port(%URI{} = uri), do: uri
end
