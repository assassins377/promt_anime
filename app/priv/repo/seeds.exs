case Anime.Seeds.owner!() do
  {:ok, status} -> IO.puts("Owner seed: #{status}")
  {:error, _} -> raise "Owner creation failed"
end
