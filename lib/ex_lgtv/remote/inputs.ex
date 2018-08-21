defmodule ExLgtv.Remote.Inputs do
  alias ExLgtv.Client

  def list(client) do
    Client.call_command(client, "ssap://tv/getExternalInputList", %{})
  end

  def subscribe(client, token) do
    Client.subscribe(client, token, "ssap://tv/getExternalInputList", %{})
  end

  def select(client, id) do
    Client.call_command(client, "ssap://tv/switchInput", %{inputId: id})
  end
end
