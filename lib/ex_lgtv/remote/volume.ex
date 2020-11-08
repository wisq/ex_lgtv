defmodule ExLgtv.Remote.Volume do
  alias ExLgtv.Client

  def get(client) do
    Client.command(client, "ssap://audio/getVolume", %{})
  end

  def subscribe(client, token) do
    Client.subscribe(client, token, "ssap://audio/getVolume", %{})
  end

  def set(client, volume) do
    Client.command(client, "ssap://audio/setVolume", %{volume: volume})
  end

  def up(client) do
    Client.command(client, "ssap://audio/volumeUp", %{})
  end

  def down(client) do
    Client.command(client, "ssap://audio/volumeDown", %{})
  end
end
