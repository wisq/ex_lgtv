defmodule ExLgtv do
  use Application

  alias ExLgtv.KeyStore

  def start(_type, _args) do
    children = [key_store()]
    Supervisor.start_link(children, strategy: :one_for_one, name: LgtvSaver.Supervisor)
  end

  defp key_store do
    mode = Application.get_env(:ex_lgtv, :key_store, KeyStore.default_mode())
    {KeyStore, mode: mode}
  end
end
