defmodule Anime.Workers.UnblockUsers do
  use Anime.Worker, queue: :maintenance, max_attempts: 3
  import Ecto.Query
  alias Anime.{Repo, Accounts.User, Accounts.Administration}
  @impl true
  def perform(_), do: batches(0, DateTime.utc_now())

  defp batches(after_id, cutoff) do
    ids =
      Repo.all(
        from u in User,
          where: u.id > ^after_id and u.status == :blocked and u.blocked_until <= ^cutoff,
          order_by: u.id,
          limit: 200,
          select: u.id
      )

    Enum.each(ids, fn id ->
      case Administration.unblock_expired(id) do
        {:ok, _} -> :ok
        {:error, :not_due} -> :ok
      end
    end)

    if length(ids) == 200, do: batches(List.last(ids), cutoff), else: :ok
  end
end
