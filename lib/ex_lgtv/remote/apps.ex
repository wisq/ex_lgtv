defmodule ExLgtv.Remote.Apps do
  alias ExLgtv.Client

  def list(client) do
    Client.call_command(client, "ssap://com.webos.applicationManager/listApps", %{})
  end

  def launch(client, id) do
    Client.call_command(client, "ssap://system.launcher/launch", %{id: id})
  end
end
