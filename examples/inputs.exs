#
# This example script will retrieve the currently selected input, then monitor
# all changes to the current input as they happen, until it receives a newline
# on standard input.
#

defmodule LgtvInputs do
  alias ExLgtv.Client, as: Client

  defmodule Consumer do
    use GenStage

    def start_link(opts) do
      {client, opts} = Keyword.pop!(opts, :client)
      {inputs, opts} = Keyword.pop!(opts, :inputs)
      GenStage.start_link(__MODULE__, {client, inputs}, opts)
    end

    def init({client, inputs}) do
      GenStage.async_subscribe(self(), to: client)
      {:consumer, inputs}
    end

    def handle_events(events, _from, inputs) do
      events
      |> Enum.each(fn
        {:input_changed, %{"appId" => app_id}} ->
          IO.puts("Input changed: #{LgtvInputs.describe_input(app_id, inputs)}")

        event ->
          IO.puts("Unknown event: #{inspect(event)})")
      end)

      {:noreply, [], inputs}
    end
  end

  def main([ip]) do
    {:ok, client} = Client.start_link(host: ip)

    {:ok, inputs_response} = Client.command(client, "ssap://tv/getExternalInputList", %{})

    input_map =
      inputs_response
      |> Map.fetch!("devices")
      |> Map.new(fn %{"id" => id, "appId" => app_id, "label" => label} ->
        {app_id, {id, label}}
      end)

    {:ok, _} = Consumer.start_link(client: client, inputs: input_map)

    {:ok, %{"appId" => current_app_id}} =
      Client.subscribe(
        client,
        :input_changed,
        "ssap://com.webos.applicationManager/getForegroundAppInfo",
        %{}
      )

    IO.puts("Current input: #{describe_input(current_app_id, input_map)}")
    IO.puts("Waiting for events, press enter to exit ...")
    IO.read(:stdio, :line)
  end

  def describe_input(app_id, map) do
    {id, label} = Map.fetch!(map, app_id)
    "#{label} (#{id})"
  end
end

System.argv() |> LgtvInputs.main()
