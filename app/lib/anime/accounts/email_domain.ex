defmodule Anime.Accounts.EmailDomain do
  @moduledoc false

  # The function argument is an internal test seam, never supplied by a request.
  def valid?(email, lookup \\ &:inet_res.getbyname/3) do
    task =
      Task.Supervisor.async_nolink(
        Anime.Tasks,
        Anime.LogContext.wrap(fn ->
          domain = email |> String.split("@") |> List.last() |> String.to_charlist()

          case lookup.(domain, :mx, 3000) do
            {:ok, _} -> true
            {:error, :nxdomain} -> false
            _ -> true
          end
        end)
      )

    case Task.yield(task, 3100) || Task.shutdown(task, :brutal_kill) do
      {:ok, result} -> result
      _ -> true
    end
  end
end
