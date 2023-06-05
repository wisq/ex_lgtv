defmodule ExLgtv.KeyStore do
  use GenServer
  require Logger

  def default_mode, do: {:file, default_file_path()}

  def start_link(opts) do
    {mode, opts} = Keyword.pop(opts, :mode, default_mode())
    opts = Keyword.put_new(opts, :name, __MODULE__)
    GenServer.start_link(__MODULE__, mode, opts)
  end

  def get(%URI{} = uri) do
    GenServer.call(__MODULE__, {:get, uri})
  end

  def put(%URI{} = uri, key) do
    GenServer.cast(__MODULE__, {:put, uri, key})
  end

  defmodule State do
    @enforce_keys [:mode]
    defstruct(
      mode: nil,
      store: nil
    )
  end

  @impl true
  def init({:file, dir} = mode) do
    File.mkdir_p!(dir)
    {:ok, %State{mode: mode}}
  end

  @impl true
  def init(:memory) do
    {:ok, %State{mode: :memory, store: %{}}}
  end

  @impl true
  def handle_call({:get, uri}, _from, state) do
    get_key(state.mode, uri, state)
  end

  @impl true
  def handle_cast({:put, uri, key}, state) do
    put_key(state.mode, uri, key, state)
  end

  defp get_key(:memory, uri, state) do
    {:reply, Map.get(state.store, {uri.host, uri.port}), state}
  end

  defp get_key({:file, dir}, uri, state) do
    path = file_key_path(dir, uri)

    case File.read(path) do
      {:ok, key} ->
        Logger.debug("Read #{String.length(key)}-byte key from #{inspect(path)}.")
        {:reply, :string.chomp(key), state}

      {:error, err} ->
        Logger.debug("Error #{inspect(err)} reading #{inspect(path)}.")
        {:reply, nil, state}
    end
  end

  defp put_key(:memory, uri, key, state) do
    {:noreply, %State{state | store: Map.put(state.store, {uri.host, uri.port}, key)}}
  end

  defp put_key({:file, dir}, uri, key, state) do
    path = file_key_path(dir, uri)
    File.write!(path, key)
    Logger.debug("Wrote #{String.length(key)}-byte key to #{inspect(path)}.")
    {:noreply, state}
  end

  defp default_file_path do
    Path.join([
      System.user_home!(),
      ".config",
      "ex_lgtv",
      "keys"
    ])
  end

  defp file_key_path(dir, %URI{host: host, port: port}) do
    Path.join(dir, "#{sanitise(host)}:#{port}")
  end

  defp sanitise(file), do: String.replace(file, "/", "_")
end
