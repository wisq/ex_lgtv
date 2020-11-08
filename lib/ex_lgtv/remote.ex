defmodule ExLgtv.Remote do
  alias ExLgtv.Client

  def turn_off(client) do
    Client.command(client, "ssap://system/turnOff", %{})
  end
end
