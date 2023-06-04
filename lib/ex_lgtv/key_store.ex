defmodule ExLgtv.KeyStore do
  require Logger

  def get(uri) do
    path = path(uri)

    case File.read(path) do
      {:ok, key} ->
        Logger.debug("Read #{String.length(key)}-byte key from #{inspect(path)}.")
        :string.chomp(key)

      {:error, err} ->
        Logger.debug("Error #{inspect(err)} reading #{inspect(path)}.")
        nil
    end
  end

  def put(uri, key) do
    path = path(uri)
    parent = Path.dirname(path)
    File.mkdir_p!(parent)
    File.write!(path, key)
    Logger.debug("Wrote #{String.length(key)}-byte key to #{inspect(path)}.")
  end

  defp path(uri) do
    Path.join([
      System.user_home!(),
      ".config",
      "ex_lgtv",
      "keys",
      "#{sanitise(uri.host)}:#{uri.port}"
    ])
  end

  defp sanitise(file), do: String.replace(file, "/", "_")
end
