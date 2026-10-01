defmodule Anime.Passwords do
  use GenServer
  @source Path.expand("../../priv/passwords/top10000.txt", __DIR__)
  @external_resource @source
  @entries @source |> File.read!() |> String.split("\n", trim: true)
  def start_link(_), do: GenServer.start_link(__MODULE__, nil, name: __MODULE__)

  def init(_) do
    entries = MapSet.new(@entries)
    if MapSet.size(entries) < 9000, do: raise("Password dictionary is incomplete")
    :persistent_term.put({__MODULE__, :common}, entries)
    {:ok, nil}
  end

  def common?(p),
    do: MapSet.member?(:persistent_term.get({__MODULE__, :common}), String.downcase(p))
end
