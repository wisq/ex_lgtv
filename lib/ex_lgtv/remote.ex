defmodule ExLgtv.Remote do
  alias ExLgtv.Client

  def turn_off(client) do
    Client.call_command(client, "ssap://system/turnOff", %{})
  end
end
