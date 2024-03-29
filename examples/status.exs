#
# This example script will move the cursor to bring up the "current input" bar,
# then click on it to show extended status (e.g. video resolution, audio encoding).
#
# It will then jiggle the pointer to keep that status bar visible as long as
# possible, until it receives a newline on standard input, at which point it
# will press the "back" button to dismiss the status bar.
#

defmodule LgtvStatus do
  alias ExLgtv.{Client, Pointer}

  # Minimum delay between events, such as movements.
  # 50ms (20/sec) seems like a safe value.
  @delay 50
  # These are the series of movements needed to reach the status bar
  # in various configurations on my TV (LG OLED 4k 48").
  # It seems like the maximum movement per action is between 16 and 20.
  @positions %{
    top_left: [
      {10, {-20, -20}},
      :click,
      {1, {20, -20}}
    ],
    top_right: [
      {10, {20, -20}},
      :click,
      {1, {-20, -20}}
    ],
    bottom_left: [
      {10, {-20, 5}},
      :click,
      {1, {-20, -20}}
    ],
    bottom_right: [
      {10, {20, 5}},
      :click,
      {1, {-20, -20}}
    ]
  }

  def main(args) do
    {ip, actions} = parse_args(args)

    {:ok, client} = Client.start_link(host: ip)
    {:ok, pointer} = Pointer.start_link(client: client)
    Pointer.wait_for_ready(pointer)
    Pointer.click(pointer)

    Enum.each(actions, &do_action(pointer, &1))
    IO.puts("Status display activated.\nPress enter to close ...")

    # Receive a :done event when we get a newline from standard input.
    stdin_wait()
    # Repeatedly move the cursor to prevent the status screen from timing out.
    # Finish when we get the :done event.
    idle_loop(pointer)

    IO.puts("Status display dismissed.")
    Pointer.button(pointer, :BACK)
    # Allow enough time for pointer socket to send last message.
    Process.sleep(100)
  end

  def parse_args(args) do
    positions = Map.keys(@positions)
    parse_opts = Enum.map(positions, fn p -> {p, :boolean} end)
    {options, rest} = OptionParser.parse!(args, strict: parse_opts)

    pos =
      positions
      |> Enum.filter(fn p -> Keyword.get(options, p, false) end)
      |> select_position()

    case rest do
      [ip] -> {ip, pos}
      _ -> usage()
    end
  end

  defp select_position([]), do: select_position([:top_left])
  defp select_position([p]), do: Map.fetch!(@positions, p)

  defp select_position([_p | _rest] = sel) do
    stderr("Too many positions selected: #{inspect(sel)}")
    usage()
  end

  defp stderr(msg) do
    IO.puts(:stderr, msg)
  end

  defp usage() do
    stderr("""

    Usage:

      status.exs [options] <ip>

    where <ip> is the IP address of your LG television.

    Available options:

      --top-left:     Status bar is in the top left.  (Default.)
      --top-right:    Status bar is in the top right.
      --bottom-left:  Status bar is in the bottom left.
      --bottom-right: Status bar is in the bottom right.

    Only one option can be specified.
    """)

    exit({:shutdown, 1})
  end

  defp do_action(pid, :click) do
    Process.sleep(@delay)
    Pointer.click(pid)
  end

  defp do_action(pid, {1, {dx, dy}}) do
    Process.sleep(@delay)
    Pointer.move(pid, dx, dy)
  end

  defp do_action(pid, {count, {dx, dy}}) do
    Process.sleep(@delay)
    Pointer.move(pid, dx, dy)
    do_action(pid, {count - 1, {dx, dy}})
  end

  defp stdin_wait do
    pid = self()

    spawn_link(fn ->
      IO.read(:stdio, :line)
      send(pid, :done)
    end)
  end

  defp idle_loop(pid, positive \\ true) do
    receive do
      :done -> :ok
    after
      100 ->
        d = if positive, do: 1, else: -1
        Pointer.move(pid, d, d)
        idle_loop(pid, !positive)
    end
  end
end

System.argv() |> LgtvStatus.main()
